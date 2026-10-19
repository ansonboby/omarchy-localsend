#!/usr/bin/env bash
# Wrap omarchy file select (xdg portal chooser) into a JSON payload the
# localsend panel can parse. Why a script: the chooser answers over D-Bus
# after QML already handed off to a Process, and URIs need decoding anyway.
#
# Usage: pick.sh [--multiple] [--directory] [--title "Sent by LocalSend"]
# Prints: {"ok":true,"cancel":false,"paths":["...","..."]} on success
#         {"ok":true,"cancel":true,"paths":[]}                   on user cancel
#         {"ok":false,"cancel":true,"paths":[]}                  on chooser failure

title="Send with LocalSend"
dir=0
multi=0
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --title) title="$2"; shift 2 ;;
    --directory) dir=1; shift ;;
    --multiple) multi=1; shift ;;
    *) args+=("$1"); shift ;;
  esac
done

cmd=(omarchy file select --title "$title")
[ "$multi" = 1 ] && cmd+=(--multiple)
[ "$dir" = 1 ] && cmd+=(--directory)

out=$("${cmd[@]}" 2>/dev/null)
code=$?

py() {
  python3 - "$1" "$multi" <<'EOF'
import json, sys, urllib.parse
raw, multi = sys.argv[1], sys.argv[2] == "1"
paths = []
for line in raw.splitlines():
    line = line.strip()
    if not line:
        continue
    if line.startswith("file://"):
        line = urllib.parse.unquote(line[7:])
    paths.append(line)
print(json.dumps({"ok": True, "cancel": len(paths) == 0, "paths": paths}))
EOF
}

case $code in
  0) py "$out" ;;
  1) echo '{"ok":true,"cancel":true,"paths":[]}' ;;
  *) echo '{"ok":false,"cancel":true,"paths":[]}' ;;
esac
