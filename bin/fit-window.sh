#!/bin/sh
# Fit the floating scrcpy window to the phone's orientation under Hyprland.
#
# Wayland clients cannot resize themselves, so when the phone rotates scrcpy
# just letterboxes inside the old portrait window. The plugin calls this with
# "landscape" or "portrait"; it swaps the window's width and height when they
# disagree with the orientation and re-centers it on its monitor. A manual
# resize is respected: only the two dimensions are swapped, never replaced.
set -eu

want=${1:-portrait}
sel='.[] | select(.class=="scrcpy" and .title=="Android Mirror")'

client=$(hyprctl -j clients | jq -r "$sel | \"\(.size[0]) \(.size[1]) \(.monitor) \(.floating)\"" | head -n1)
[ -n "$client" ] || exit 0
set -- $client
w=$1; h=$2; mon=$3; floating=$4
[ "$floating" = "true" ] || exit 0

case "$want" in
  landscape) [ "$w" -lt "$h" ] || exit 0 ;;
  portrait)  [ "$w" -gt "$h" ] || exit 0 ;;
  *) exit 2 ;;
esac

nw=$h; nh=$w
geom=$(hyprctl -j monitors | jq -r ".[] | select(.id==$mon) | \"\(.x) \(.y) \(.width) \(.height) \(.scale)\"")
set -- $geom
mx=$1; my=$2; mw=$3; mh=$4; scale=$5
lw=$(awk "BEGIN{printf \"%d\", $mw/$scale}")
lh=$(awk "BEGIN{printf \"%d\", $mh/$scale}")
x=$(( mx + (lw - nw) / 2 ))
y=$(( my + (lh - nh) / 2 ))

# Hyprland's hyprctl here speaks Lua; the classic "dispatch resizewindowpixel"
# form is rejected, so issue the dispatchers through the repl.
sel='window = "class:^(scrcpy)$"'
hyprctl repl "hl.dispatch(hl.dsp.window.resize({ x = $nw, y = $nh, exact = true, $sel })); hl.dispatch(hl.dsp.window.move({ x = $x, y = $y, exact = true, $sel }))" >/dev/null
