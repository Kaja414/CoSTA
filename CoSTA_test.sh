#!/bin/bash

#  CoSTA_test.sh
#
#  Author: Kaja Reinhardt
#  Last Edit: 10/01/2026
#  Test the parts of CoSTA one at a time (service mode: CoSTA.service disabled, Pi stays on)
#
#  ./CoSTA_test.sh led          LED on for 3 s
#  ./CoSTA_test.sh relay        chain relay on for 5 s (listen for the click)
#  ./CoSTA_test.sh usb          USB stick: mount, write + read a test file, free space
#  ./CoSTA_test.sh all          everything above
#
#  Full cycle with all nodes: bash CoSTA.sh (by hand = no schedule, no shutdown)

# ------------------------------------------------------------
# Setup Environment
# ------------------------------------------------------------

. /home/kaja/CoSTA/config/CoSTA.conf

if [ "$RELAY_ACTIVE" = "low" ]; then RELAY_ON="dl"; RELAY_OFF="dh"; else RELAY_ON="dh"; RELAY_OFF="dl"; fi

trap 'sudo pinctrl set $RELAY_GPIO op $RELAY_OFF; echo ""; echo "Test stopped, chain off"; exit 1' INT TERM

# ------------------------------------------------------------
# Functions
# ------------------------------------------------------------

RESULTS=""
result() {                                            # $1 = PASS/FAIL, $2 = what
  echo "$1  $2"
  RESULTS+="$1  $2"$'\n'
}

yes_no() {                                            # 0 if the answer is y
  local answer
  read -r -p "$1 [y/n] " answer
  [ "$answer" = "y" ] || [ "$answer" = "Y" ]
}

# ------------------------------------------------------------
# Tests
# ------------------------------------------------------------

test_led() {
  echo ""
  echo "--- LED (GPIO $LED_GPIO)"
  sudo pinctrl set $LED_GPIO op dl
  sleep 1
  sudo pinctrl set $LED_GPIO op dh
  echo "LED on for 3 s..."
  sleep 3
  sudo pinctrl set $LED_GPIO op dl
  if yes_no "Was the LED on for 3 s?"; then result PASS "LED"; else result FAIL "LED"; fi
}

test_relay() {
  echo ""
  echo "--- Chain relay (GPIO $RELAY_GPIO, active $RELAY_ACTIVE)"
  sudo pinctrl set $RELAY_GPIO op $RELAY_ON
  echo "Chain on for 5 s..." $(pinctrl get $RELAY_GPIO)
  sleep 5
  sudo pinctrl set $RELAY_GPIO op $RELAY_OFF
  echo "Chain off" $(pinctrl get $RELAY_GPIO)
  if yes_no "Did the relay click on and off (and the nodes power up)?"; then result PASS "relay"; else result FAIL "relay"; fi
}

test_usb() {
  echo ""
  echo "--- USB stick ($USBID -> $DATA_DIR)"
  mountpoint -q $DATA_DIR || sudo mount /dev/$USBID $DATA_DIR -o uid=$COSTA_USER,gid=$COSTA_USER
  if ! mountpoint -q $DATA_DIR; then
    result FAIL "USB: not mounted"
    return
  fi
  local file="$DATA_DIR/CoSTA_test_usb.txt" word="CoSTA $(date +%s)"
  echo "$word" > "$file" && sync
  if [ "$(cat "$file" 2>/dev/null)" = "$word" ]; then result PASS "USB: write + read"; else result FAIL "USB: write + read"; fi
  rm -f "$file"
  df -h $DATA_DIR | tail -n 1 | awk '{ print "  free space: " $4 " of " $2 }'
}

# ------------------------------------------------------------
# Run
# ------------------------------------------------------------

case "$1" in
  led)   test_led ;;
  relay) test_relay ;;
  usb)   test_usb ;;
  all)
    test_led
    test_relay
    test_usb
    ;;
  *)
    sed -n '3,14p' "$0"                        # show the usage from the header
    exit 1
    ;;
esac

# ------------------------------------------------------------
# Results
# ------------------------------------------------------------

echo ""
echo "Results:"
printf '%s' "$RESULTS"
case "$RESULTS" in *FAIL*) exit 1 ;; esac
exit 0
