#!/bin/bash

#  CoSTA.sh
#
#  Author: Kaja Reinhardt
#  Last Edit: 10/01/2026
#  Script to schedule wittyPi and run autonomous monitoring
#  Started by CoSTA.service (deployment): schedules the next start-up and shuts down at the end
#  Started by hand (bash CoSTA.sh, testing / calibration): no schedule, no shutdown

# ------------------------------------------------------------
# Setup Environment
# ------------------------------------------------------------

echo ""
echo "Welcome to CoSTA"
echo "Current Time:" $(date)

# --- Configurations (NODE_IDS, PORT, BAUD, LED_GPIO, RELAY_GPIO, POLL_TIMES, etc.)
. /home/kaja/CoSTA/config/CoSTA.conf

# --- Deployment run = started by CoSTA.service (sets COSTA_SERVICE=1), otherwise by hand
DEPLOY=${COSTA_SERVICE:-0}

# --- Ctrl+C or stop: chain off before exiting
trap 'sudo pinctrl set $RELAY_GPIO op dl; sudo pinctrl set $RELAY2_GPIO op dl; echo "CoSTA.sh stopped"; exit 1' INT TERM

# --- LED on = CoSTA is running
sudo pinctrl set $LED_GPIO op dh

# --- Node Chain on: the XIAOs boot while the Pi schedules and mounts the USB
sudo pinctrl set $RELAY_GPIO op dh           # chain A on
sleep 1                                      # chain B 1 s later = smaller current spike
sudo pinctrl set $RELAY2_GPIO op dh          # chain B on

# ------------------------------------------------------------
# Schedule Next Start-Up
# ------------------------------------------------------------

echo "Schedule Next Start-Up:"

if [ "$DEPLOY" = 1 ]; then                   # only when started by CoSTA.service
  sudo cp $WITTYPI_DIR/schedules/$SCHEDULE $WITTYPI_DIR/schedule.wpi
  cd $WITTYPI_DIR && sudo ./runScript.sh
fi

# ------------------------------------------------------------
# USB Mount
# ------------------------------------------------------------

cd $COSTA_DIR

sudo mount /dev/$USBID $DATA_DIR -o uid=$COSTA_USER,gid=$COSTA_USER

# ------------------------------------------------------------
# Open .log file
# ------------------------------------------------------------

# date + time before every line
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$DATA_DIR/${RUNFILE}"; }   
cd $DATA_DIR && log "Start of CoSTA.sh" 

log "Open .log"
log "Deployment run: $DEPLOY (1 = scheduled, 0 = manual)"

# ------------------------------------------------------------
# Open data files
# ------------------------------------------------------------

# --- Raw: as sent by the XIAOs
RAW_HEADER="DateTime,NodeID,T_run,EC_run"
for i in $(seq -w 1 $T_SAMPLES);  do RAW_HEADER="$RAW_HEADER,T_V_$i"; done
for i in $(seq -w 1 $EC_SAMPLES); do RAW_HEADER="$RAW_HEADER,EC_$i"; done

# --- Calc: written by CoSTA_calc.py
CALC_HEADER="DateTime,NodeID,T_run,T_N,T_C_mean,T_C_SD,T_C_SE,EC_run,EC_N,EC_mean,EC_SD,EC_SE,SP"

[ -f "$RAWFILE" ]  || echo "$RAW_HEADER" > "$RAWFILE"
[ -f "$CALCFILE" ] || echo "$CALC_HEADER" > "$CALCFILE"

log "Data files opened..."

# ------------------------------------------------------------
# Functions
# ------------------------------------------------------------

# --- Request Node Data --------------------------------------
ask_node() {                                          # Ask one node for its data
  DATA=""
  while read -r -t 0.1 -u 3 junk; do :; done          # clear anything old
  echo "$1,S" >&3
  while read -r -t $POLL_TIMEOUT -u 3 line; do        # gives up after POLL_TIMEOUT 
    line=${line%$'\r'}
    if [ -n "$line" ]; then DATA="$line"; break; fi   # first answer, checked by check_data
  done
}

# --- Check the Data -----------------------------------------
# --- DATA,TS,ID,T_run,T_bad,EC_run,EC_bad,T_V x T_SAMPLES,EC x EC_SAMPLES
# --- Returns 0 only if all 5 checks pass, otherwise WHY says what failed
check_data() {
  local f i
  IFS=',' read -r -a f <<< "$DATA"

  # --- 1. Does it start with DATA? 
  if [ -z "$DATA" ];            then WHY="no answer"; return 1; fi
  if [ "${f[0]}" != "DATA" ];   then WHY="does not start with DATA: ${DATA:0:30}"; return 1; fi

  # --- 2. Includes this cycles time stamp?
  if [ "${f[1]}" != "$TS" ];    then WHY="wrong time stamp ${f[1]}"; return 1; fi

  # --- 3. Correct node number?
  if [ "${f[2]}" != "$1" ];     then WHY="wrong node ${f[2]}"; return 1; fi

  # --- 4. Exactly T_SAMPLES + EC_SAMPLES = 40 readings?
  if [ $(( ${#f[@]} - 7 )) -ne $(( T_SAMPLES + EC_SAMPLES )) ]; then
    WHY="$(( ${#f[@]} - 7 )) readings instead of $(( T_SAMPLES + EC_SAMPLES ))"
    return 1
  fi

  # --- 5. Every reading is a number?
  for (( i = 7; i < ${#f[@]}; i++ )); do
    if [[ ! "${f[$i]}" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then 
      WHY="reading ${f[$i]} is not a number" 
      return 1 
    fi
  done
}

# --- Raw row for a failed node: 999999 everywhere ----------
fail_row() {
  local row="$TS,$1" i
  for (( i = 0; i < 2 + T_SAMPLES + EC_SAMPLES; i++ )); do row="$row,$FAIL"; done
  echo "$row" >> "$RAWFILE"
}

# ------------------------------------------------------------
# Broadcast: all nodes take a reading
# ------------------------------------------------------------

sleep $BOOT_MIN                              # full boot time

exec 3<>$PORT                                # file descriptor 3 = the RS485 bus
stty -F $PORT $BAUD cs8 -cstopb -parenb raw -echo

TS=$(date '+%Y-%m-%d %H:%M:%S')
log "Broadcast: all nodes take reading"

echo "0,M,$TS" >&3
SECONDS=0                                    # clock for POLL_TIMES

# ------------------------------------------------------------
# Receive Data: One node at a time, at POLL_TIMES
# ------------------------------------------------------------
# --- Each time, only the nodes that haven't answered yet are asked
# --- Silent node = still measuring -> asked again at the next poll time
# --- Wrong data -> one resend -> still wrong = FAILED

MISSING="$NODE_IDS"                          # nodes without an answer yet
FAILED=""

for t in $POLL_TIMES
do
  [ -z "$MISSING" ] && break                 # all nodes answered
  [ $(( t - SECONDS )) -gt 0 ] && sleep $(( t - SECONDS ))   # wait for the poll time

  STILL_MISSING=""
  for id in $MISSING
  do
    ask_node $id

    if [ -z "$DATA" ]; then                  # no answer yet, ask at the next poll time
      STILL_MISSING="$STILL_MISSING $id"
      log "Node $id: no answer yet (${SECONDS} s)"
      continue
    fi

    if check_data $id; then
      STATUS="OK"
    else
      # --- One resend: ask again for the same data
      log "Node $id: wrong data ($WHY), asking again"
      ask_node $id
      if check_data $id; then STATUS="OK resend"; else STATUS="FAILED ($WHY)"; fi
    fi

    if [[ "$STATUS" == OK* ]]; then
     echo "$DATA" | cut -d, -f2-4,6,8- >> "$RAWFILE"      # raw row 
     IFS=',' read -r _ _ _ T_RUN _ EC_RUN _ <<< "$DATA"   # run flags: DATA,TS,ID,T_run,T_bad,EC_run,...
     STATUS="$STATUS, T run $T_RUN, EC run $EC_RUN"       # added to the log line below
    else
      FAILED="$FAILED $id"
      fail_row $id
    fi

    log "Node $id: $STATUS (${SECONDS} s)"
  done
  MISSING=$STILL_MISSING
done

# --- Still no answer after the last poll time = no data this cycle
for id in $MISSING
do
  FAILED="$FAILED $id"
  fail_row $id
  log "Node $id: FAILED, no answer"
done

sudo pinctrl set $RELAY_GPIO op dl           # chain off
sudo pinctrl set $RELAY2_GPIO op dl          # chain B off

exec 3>&-                                    # close the bus

log "Nodes failed:${FAILED:- none}"
log "Chain off"

# ------------------------------------------------------------
# Calculations: N, mean, SD, SEM, T in C, salinity
# ------------------------------------------------------------

log "Calc file running"
python3 $CALC_SCRIPT "$TS"      

# ------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------

echo ""
echo "Cleaning up..."

log "End of CoSTA.sh"  
log ""                                 

sync                                         # make sure everything is written to the USB
sudo pinctrl set $LED_GPIO op dl             # LED off

# ------------------------------------------------------------
# Exit
# ------------------------------------------------------------

echo "Exit CoSTA.sh"
echo ""

if [ "$DEPLOY" = 1 ]; then                   # by hand: Pi stays on
  sudo shutdown -h now
fi
exit 0
