#!/usr/bin/env bash
# Open the full LocalSend app, or focus its window if it is already running.

if hyprctl -j clients 2>/dev/null | grep -q '"class": *"org.localsend.localsend_app"'; then
  omarchy hyprland focus app localsend >/dev/null 2>&1
else
  nohup localsend >/dev/null 2>&1 &
fi
