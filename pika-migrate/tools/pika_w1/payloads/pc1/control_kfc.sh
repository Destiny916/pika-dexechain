#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/deployment.env"
PID_FILE="$ROOT/run/kfc.pid"
LOG_FILE="$ROOT/logs/kfc.log"
DOMAIN_ID="${PC1_ROS_DOMAIN_ID:-20}"
KFC_IP="${PC1_KFC_IP:-192.168.20.30}"
KFC_TOPIC="${PC1_KFC_TOPIC:-/camera/kfc_compressed_external}"

die(){ echo "❌ $*" >&2; exit 1; }
running(){ [ -s "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; }

case "$ACTION" in
  start)
    running && { echo "KFCv2 已在运行(pid=$(cat "$PID_FILE"))"; exit 0; }
    mkdir -p "$ROOT/run" "$ROOT/logs"
    rm -f "$PID_FILE"
    source /opt/ros/humble/setup.bash
    export ROS_DOMAIN_ID="$DOMAIN_ID" ROS_LOCALHOST_ONLY=0 RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
    nohup "$KFCV2_PREFIX/lib/kfcv2/kfcv2_publisher" --ros-args \
      -r __node:=camera_head_kfcv2_external \
      -r /camera/kfc_compressed:="$KFC_TOPIC" \
      -p video_index:="$KFC_IP" -p use_resize:=false -p use_compressed:=true \
      -p interval_compressed:=33 >>"$LOG_FILE" 2>&1 &
    echo $! > "$PID_FILE"
    sleep 1
    running || die "KFCv2 启动失败，请查看 $LOG_FILE"
    echo "✅ KFCv2 已启动(pid=$(cat "$PID_FILE"), domain=$DOMAIN_ID, topic=$KFC_TOPIC)"
    ;;
  stop)
    if ! running; then rm -f "$PID_FILE"; echo "KFCv2 未运行"; exit 0; fi
    pid=$(cat "$PID_FILE")
    kill -INT "$pid" 2>/dev/null || true
    for _ in 1 2 3 4 5; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    kill -TERM "$pid" 2>/dev/null || true
    rm -f "$PID_FILE"
    echo "✅ KFCv2 已停止"
    ;;
  status)
    if running; then echo "running pid=$(cat "$PID_FILE") domain=$DOMAIN_ID topic=$KFC_TOPIC"; else echo "stopped"; fi
    ;;
  *) echo "用法: $0 {start|stop|status}" >&2; exit 2 ;;
esac
