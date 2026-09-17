#!/bin/sh
# Register the floating window rule for the scrcpy window at runtime, so users
# need not touch their Hyprland config. Safe to run before every mirror start:
# Hyprland's Lua API just adds the rule again, and identical rules coalesce
# into the same result. Silently a no-op outside Hyprland.
command -v hyprctl >/dev/null 2>&1 || exit 0
[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] || exit 0
exec hyprctl repl 'hl.window_rule({
  match = { class = "^scrcpy$", title = "^Android Mirror$" },
  float = true, pin = true, center = true,
  size = { "(monitor_h*2/5)", "(monitor_h*8/9)" },
  tag = "-default-opacity", opacity = "1 1", no_dim = true,
}); return "ok"' >/dev/null 2>&1
