#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/deployment.env"
PID_FILE="$ROOT/run/fisheye.pid"
LOG_FILE="$ROOT/logs/fisheye.log"

die(){ echo "❌ $*" >&2; exit 1; }
running(){ [ -s "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; }

case "$ACTION" in
  start)
    running && { echo "鱼眼已在运行(pid=$(cat "$PID_FILE"))"; exit 0; }
    mkdir -p "$ROOT/run" "$ROOT/logs"
    rm -f "$PID_FILE"
    nohup setsid bash "$FISHEYE_START_SCRIPT" >>"$LOG_FILE" 2>&1 &
    echo $! > "$PID_FILE"
    sleep 2
    running || die "鱼眼启动失败，请查看 $LOG_FILE"
    echo "✅ 鱼眼已启动(pid=$(cat "$PID_FILE"))"
    ;;
  stop)
    if ! running; then rm -f "$PID_FILE"; echo "鱼眼未运行"; exit 0; fi
    pid=$(cat "$PID_FILE")
    kill -INT -- "-$pid" 2>/dev/null || kill -INT "$pid" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
    rm -f "$PID_FILE"
    echo "✅ 鱼眼已停止"
    ;;
  status)
    if running; then echo "running pid=$(cat "$PID_FILE")"; else echo "stopped"; fi
    ;;
  *) echo "用法: $0 {start|stop|status}" >&2; exit 2 ;;
esac
