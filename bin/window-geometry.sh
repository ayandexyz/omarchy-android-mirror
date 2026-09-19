#!/bin/sh
# Print "<width> <height> <x> <y>": the floating window that frames the phone
# screen exactly -- the largest area that keeps the phone's own aspect ratio
# inside the monitor's work area (bar reserved space included), centered on it.
#
# Nothing is hardcoded: the phone's resolution comes from adb, the work area,
# border size and gaps come from the running Hyprland, so a 1440x3120 phone on a
# 1080p screen and a 720p phone on a 4K screen both land on a fitted window.
#
# Usage: window-geometry.sh <serial> [portrait|landscape|auto] [monitor-id|auto] [adb-path]
set -eu

serial=${1:-}
want=${2:-auto}
monitor=${3:-auto}
adb=${4:-/usr/bin/adb}

# --- the phone's screen in device pixels (an override wins over the physical
# --- size, which is what the user actually sees; portrait frame)
size=""
if [ -n "$serial" ] && [ -x "$adb" ]; then
  size=$("$adb" -s "$serial" shell wm size 2>/dev/null | grep -oE '[0-9]+x[0-9]+' | tail -n1 || true)
fi
[ -n "$size" ] || size=1080x2340
pw=${size%%x*}
ph=${size##*x}

# --- which way round the phone currently is (odd orientation codes are 90/270)
if [ "$want" != portrait ] && [ "$want" != landscape ]; then
  o=$("$adb" -s "$serial" shell dumpsys display 2>/dev/null \
      | grep -m1 -oE 'mCurrentOrientation=[0-9]+' | cut -d= -f2 || true)
  case ${o:-0} in
    1|3) want=landscape ;;
    *)   want=portrait ;;
  esac
fi
if [ "$want" = landscape ]; then t=$pw; pw=$ph; ph=$t; fi

# --- the monitor this window belongs on: the focused one when not told
sel='.[] | select(.focused)'
case "$monitor" in
  ''|auto) ;;
  *) sel=".[] | select(.id==$monitor)" ;;
esac
mon=$(hyprctl -j monitors | jq -r "$sel | \"\(.x) \(.y) \(.width) \(.height) \(.scale) \((.reserved // [0,0,0,0]) | join(\" \"))\"" | head -n1)
[ -n "$mon" ] || exit 0
set -- $mon
mx=$1; my=$2; mw=$3; mh=$4; scale=$5; rl=$6; rt=$7; rr=$8; rb=$9

# --- decoration: Hyprland sizes the client area and draws the border outside it,
# --- so only the gaps eat into the space the window can use
gap=$(hyprctl getoption general:gaps_out 2>/dev/null \
      | awk '/css gap data/{for (i=1;i<=NF;i++) if ($i+0>m) m=$i+0} END{print m+0}')
case "$gap" in ''|*[!0-9]*) gap=0 ;; esac

# The size keeps the gaps free (it is the work area minus a gap on every side),
# but the window is centered on the *whole* work area, so the leftover space is
# split evenly instead of being dumped at the bottom: a full-height mirror would
# otherwise sit flush under the bar with the whole margin below it.
awk -v mx="$mx" -v my="$my" -v mw="$mw" -v mh="$mh" -v scale="$scale" \
    -v rl="$rl" -v rt="$rt" -v rr="$rr" -v rb="$rb" \
    -v gap="$gap" -v pw="$pw" -v ph="$ph" 'BEGIN{
  workw = mw/scale - rl - rr;
  workh = mh/scale - rt - rb;
  availw = workw - 2*gap;
  availh = workh - 2*gap;
  if (availw < 32 || availh < 32) exit 1;
  s = availw/pw; if (availh/ph < s) s = availh/ph;
  w = int(pw*s + 0.5); h = int(ph*s + 0.5);
  if (w < 16 || h < 16) exit 1;
  x = mx + rl + int((workw - w)/2);
  y = my + rt + int((workh - h)/2);
  printf "%d %d %d %d\n", w, h, x, y;
}'
