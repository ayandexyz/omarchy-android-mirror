#!/bin/sh
# Register the floating window rule for the scrcpy window at runtime, so users
# need not touch their Hyprland config. Safe to run before every mirror start:
# Hyprland's Lua API just adds the rule again, and identical rules coalesce
# into the same result. Silently a no-op outside Hyprland.
#
# The size is the fitted one from bin/window-geometry.sh (the phone's own aspect
# ratio, as large as the monitor allows), so the window opens already framed
# around the mirrored screen instead of letterboxing inside a wrong-shaped one.
# bin/fit-window.sh re-fits the live window anyway, at start and on rotation.
#
# Usage: hypr-window-rule.sh [serial] [adb-path]
set -u

command -v hyprctl >/dev/null 2>&1 || exit 0
[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] || exit 0

serial=${1:-}
adb=${2:-/usr/bin/adb}
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# Fallback for when adb or the geometry helper is unavailable: the old
# monitor-relative guess.
size='{ "(monitor_h*2/5)", "(monitor_h*8/9)" }'
geom=$("$here/window-geometry.sh" "$serial" auto auto "$adb" 2>/dev/null || true)
if [ -n "$geom" ]; then
  set -- $geom
  size="{ \"$1\", \"$2\" }"
fi

hyprctl repl "hl.window_rule({
  match = { class = \"^scrcpy\$\", title = \"^Android Mirror\$\" },
  float = true, pin = true, center = true,
  size = $size,
  tag = \"-default-opacity\", opacity = \"1 1\", no_dim = true,
}); return \"ok\"" >/dev/null 2>&1
