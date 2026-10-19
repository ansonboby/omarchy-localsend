#!/usr/bin/env bash
# Open the full LocalSend app, or focus its window if it is already running.
# Guards against double-launch: LocalSend binds a fixed port (53317), so a
# second instance reports "address already in use" (OS error 98) and shows
# itself offline. A just-launched app has no mapped window yet, so the
# window-class check must be paired with a process check.

if pgrep -x localsend >/dev/null 2>&1; then
  # Already starting or running: wait for its window to map, then focus it.
  for _ in 1 2 3 4 5 6 7 8; do
    if hyprctl -j clients 2>/dev/null | grep -q localsend; then break; fi
    sleep 0.5
  done
  omarchy hyprland focus app localsend >/dev/null 2>&1 &
elif hyprctl -j clients 2>/dev/null | grep -q '"class": *"org.localsend.localsend_app"'; then
  omarchy hyprland focus app localsend >/dev/null 2>&1 &
else
  nohup localsend >/dev/null 2>&1 &
fi
