#!/bin/bash
# lldb_run_audit.sh - adjunta LLDB al proceso Fortnite activo y ejecuta el audit
PID=$(pgrep -x FortniteClient-IOS-Shipping 2>/dev/null || pgrep FortniteClient 2>/dev/null | head -1)
if [ -z "$PID" ]; then echo "ERROR: FortniteClient no esta corriendo"; exit 1; fi
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AUDIT_PY="$SCRIPT_DIR/lldb_audit.py"
echo "Adjuntando LLDB a PID $PID..."
lldb -p "$PID" \
    -o "command script import $AUDIT_PY" \
    -o "detach" \
    -o "quit"
