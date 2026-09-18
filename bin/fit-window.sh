#!/bin/sh
# Fit the floating scrcpy window exactly around the phone's screen.
#
# Wayland clients cannot resize themselves, so scrcpy just letterboxes inside
# whatever window the compositor gives it: a 432x960 window around a 1440x3120
# phone leaves black bars, and any shape that is not the phone's own aspect
# ratio leaves bars on two sides. This computes the largest window that keeps
# the phone's aspect and centers it on the monitor the window lives on, so the
# mirrored screen fills the window edge to edge.
#
# Waits for the window to appear (the plugin calls this right after spawning
# scrcpy), and re-fits on every rotation. A manual resize survives: it is only
# undone when the phone's orientation actually changes.
#
# Usage: fit-window.sh [serial] [portrait|landscape|auto] [adb-path]
set -eu

serial=${1:-}
want=${2:-auto}
adb=${3:-/usr/bin/adb}
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

command -v hyprctl >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0
sel='.[] | select(.class=="scrcpy" and .title=="Android Mirror")'

# --- wait up to ~6s for the mirror window to be mapped
client=""
i=0
while [ "$i" -lt 30 ]; do
  client=$(hyprctl -j clients | jq -r "$sel | \"\(.monitor) \(.floating) \(.size[0]) \(.size[1]) \(.at[0]) \(.at[1])\"" | head -n1)
  [ -n "$client" ] && break
  sleep 0.2
  i=$((i + 1))
done
[ -n "$client" ] || exit 0

set -- $client
mon=$1; floating=$2; cw=$3; ch=$4; cx=$5; cy=$6
[ "$floating" = "true" ] || exit 0

geom=$("$here/window-geometry.sh" "$serial" "$want" "$mon" "$adb") || exit 0
[ -n "$geom" ] || exit 0
set -- $geom
w=$1; h=$2; x=$3; y=$4

# Nothing to do when the window is already the fitted size and place: this keeps
# a manual resize the user just made, and makes the call cheap to repeat.
[ "$cw" = "$w" ] && [ "$ch" = "$h" ] && [ "$cx" = "$x" ] && [ "$cy" = "$y" ] && exit 0

# Hyprland's hyprctl here speaks Lua; the classic "dispatch resizewindowpixel"
# form is rejected, so issue the dispatchers through the repl.
win='window = "class:^(scrcpy)$"'
hyprctl repl "hl.dispatch(hl.dsp.window.resize({ x = $w, y = $h, exact = true, $win })); hl.dispatch(hl.dsp.window.move({ x = $x, y = $y, exact = true, $win }))" >/dev/null
