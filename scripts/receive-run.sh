#!/usr/bin/env bash
# Receiver payload for the systemd unit. Reads shell-format settings the QML
# panel writes (dir="..."; pin="..."|unset) and execs lsend receive.
# Kept in a wrapper + systemd unit so the receiver survives shell reloads
# and continues transfers in flight.

set -euo pipefail

STATE="$HOME/.local/state/localsend-menu"
CFG="$STATE/receiver.conf"

mkdir -p "$STATE"

DIR="$HOME/Downloads"
EXTRA=()

strip() { printf '%s' "$2" | sed "s/^$1=//; s/^'//; s/'$//"; }

if [ -f "$CFG" ]; then
  # Only accept our strict conf grammar: dir='...', optional pin='...'
  # (values are Util.shellQuote()-escaped and must not contain quotes).
  while IFS= read -r line; do
    case "$line" in
      dir=*) DIR=$(strip dir "$line") ;;
      pin=*) pin=$(strip pin "$line"); [ -n "$pin" ] && EXTRA+=(--pin "$pin") ;;
    esac
  done < "$CFG"
fi

mkdir -p "$DIR"

exec ~/.local/bin/lsend receive --json --dir "$DIR" "${EXTRA[@]+"${EXTRA[@]}"}"
