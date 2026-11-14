#!/bin/bash

#  CoSTA_calibration.sh
#
#  Author: Kaja Reinhardt
#  Last Edit: 10/01/2026
#  Manual calibration in service mode (CoSTA.service disabled, no Witty Pi schedule, Pi stays on)
#
#  ./CoSTA_calibration.sh ezo     EZO-EC calibration: type commands, see + save the answers
#  ./CoSTA_calibration.sh runs    3x5x20 runs for one solution / temperature point
#
#  Everything is saved with the time in CALIBFILE on the USB stick (CoSTA_calibration.log)
#
#  --- ezo: Atlas dry / low / high calibration ---------------------------------
#  Chain on when it starts, chain off when you type q
#  Commands: 0 = all nodes, 1-8 = one node. CM = command to the EZO, CS = send its answer
#  (if not all probes fit in the bath: send CM to the node IDs in the bath, not 0)
#    > # note          not sent, only saved (e.g. # standard lot 1234, bath 25.0 C)
#    > 0,CM,Cal,clear  delete the old calibration (all nodes)
#    > 0,CM,Cal,dry    probes dry, in air
#    > 1,CS            answer of node 1 (repeat for every node): CAL,1,*OK
#    > 0,CM,R          one reading, then 1,CS ... to see if the readings are stable
#    > 0,CM,Cal,low,12880    probes in the low standard (value at the bath temperature)
#    > 0,CM,Cal,high,80000   rinse, probes in the high standard
#    > 0,CM,Cal,?      check: every node should answer CAL,ID,?CAL,2 *OK
#    > q               quit, chain off
#  *OK = done, *ER = EZO error, NOANSWER = EZO silent, NOCAL = node missed the CM command
#
#  --- runs: 3x5x20 for one point ------------------------------------------------
#  Asks for a label (e.g. SOL_1413 or T_25C), then for each of the CAL_INSERTIONS (3):
#    you put the probes in and press Enter -> CAL_CYCLES (5) CoSTA.sh cycles run by themselves
#    -> take the probes out and clean them
#  The data goes into the normal CoSTA_raw.csv / CoSTA_calc.csv, the run sheet
#  (label, insertion, cycle -> time stamp) into CoSTA_calibration.log

# ------------------------------------------------------------
# Setup Environment
# ------------------------------------------------------------

. /home/kaja/CoSTA/config/CoSTA.conf

if [ "$RELAY_ACTIVE" = "low" ]; then RELAY_ON="dl"; RELAY_OFF="dh"; else RELAY_ON="dh"; RELAY_OFF="dl"; fi

mountpoint -q $DATA_DIR || sudo mount /dev/$USBID $DATA_DIR -o uid=$COSTA_USER,gid=$COSTA_USER

# --- Print to screen & write to the calibration log (with time)
cal_log() { echo "$*"; echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$DATA_DIR/$CALIBFILE"; }

# ------------------------------------------------------------
# ezo: type commands, answers on screen + in the log
# ------------------------------------------------------------

ezo() {
  trap 'sudo pinctrl set $RELAY_GPIO op $RELAY_OFF; sudo pinctrl set $RELAY2_GPIO op $RELAY_OFF; echo ""; cal_log "Stopped, chain off"; exit 1' INT TERM

  sudo pinctrl set $RELAY_GPIO op $RELAY_ON        # chain on
  sleep 1                                          # chain B 1 s later
  sudo pinctrl set $RELAY2_GPIO op $RELAY_ON       # chain B on

  cal_log "EZO calibration: chain on, waiting ${BOOT_MIN} s for the nodes to boot"
  sleep $BOOT_MIN

  exec 3<>$PORT                                    # file descriptor 3 = the RS485 bus
  stty -F $PORT $BAUD cs8 -cstopb -parenb raw -echo

  while true
  do
    read -r -p "> " cmd
    case "$cmd" in
      q)  break ;;                                 # quit
      "") continue ;;
      \#*) cal_log "NOTE $cmd"; continue ;;        # note: saved, not sent
    esac

    while read -r -t 0.1 -u 3 junk; do :; done     # clear anything old
    echo "$cmd" >&3
    cal_log "SENT $cmd"

    case "$cmd" in
      *,CM,*) echo "  EZO working, wait ${CM_WAIT} s"; sleep $CM_WAIT ;;   # answer comes with CS
    esac

    while read -r -t $POLL_TIMEOUT -u 3 line; do    # show + save every answer
      line=${line%$'\r'}
      [ -n "$line" ] && cal_log "  ANSWER $line"
    done
  done

  exec 3>&-                                        # close the bus
  sudo pinctrl set $RELAY_GPIO op $RELAY_OFF       # chain A off
  sudo pinctrl set $RELAY2_GPIO op $RELAY_OFF      # chain B off
  cal_log "EZO calibration done, chain off"
}

# ------------------------------------------------------------
# runs: CAL_INSERTIONS x CAL_CYCLES x 20 reading bursts for one point
# ------------------------------------------------------------

runs() {
  trap 'echo ""; cal_log "RUNS $LABEL stopped"; exit 1' INT TERM

  read -r -p "Label for this point (e.g. SOL_1413 or T_25C): " LABEL
  cal_log "RUNS $LABEL: $CAL_INSERTIONS insertions x $CAL_CYCLES cycles, nodes $NODE_IDS"

  for (( ins = 1; ins <= CAL_INSERTIONS; ins++ ))
  do
    echo ""
    read -r -p "Insertion $ins/$CAL_INSERTIONS: probes in and stable. Reference at start: " REF   # reference reading
    cal_log "RUN $LABEL insertion $ins REF_START $REF"
    for (( c = 1; c <= CAL_CYCLES; c++ ))
    do
      bash $COSTA_DIR/CoSTA.sh                     # by hand = no schedule, no shutdown
      TS=$(tail -n 1 "$DATA_DIR/$RAWFILE" | cut -d',' -f1)
      cal_log "RUN $LABEL insertion $ins cycle $c TS $TS"
    done
    read -r -p "Reference at end: " REF                                                           # reference reading
    cal_log "RUN $LABEL insertion $ins REF_END $REF"
    echo ""
    echo "Insertion $ins/$CAL_INSERTIONS done: take the probes out and clean them"
  done

  cal_log "RUNS $LABEL done"
}

# ------------------------------------------------------------
# Run
# ------------------------------------------------------------

case "$1" in
  ezo)  ezo ;;
  runs) runs ;;
  *)
    sed -n '3,12p' "$0"                            # show the usage from the header
    exit 1
    ;;
esac
