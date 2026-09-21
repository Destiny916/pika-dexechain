#!/bin/bash
# KFCv2 pre-capture visual alignment. Called by start_collect.sh on the host.
set -uo pipefail

case "${HEAD_CAMERA_DRIVER:-}" in
  kfcv2) ;;
  *) exit 0 ;;
esac

case "${KFC_ALIGN_BEFORE_CAPTURE:-true}" in
  1|true|TRUE|yes|YES|on|ON) ;;
  *) exit 0 ;;
esac

CONTAINER_NAME="${CONTAINER_NAME:-pika}"
PIKA_DIR="${PIKA_DIR:-/home/${USER}/app/pika}"
HOST_HOME="${HOST_HOME:-/home/${PIKA_USER:-${USER}}}"
ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-42}"
KFC_ALIGN_TOPIC="${KFC_ALIGN_TOPIC:-${HEAD_CAMERA_INPUT_TOPIC:-/camera/kfc_compressed}}"
KFC_ALIGN_REFERENCE_DIR="${KFC_ALIGN_REFERENCE_DIR:-$HOST_HOME/agilex/kfc_reference}"
KFC_ALIGN_FPS="${KFC_ALIGN_FPS:-5}"
ALIGN_TOOL="$PIKA_DIR/pika_ros/scripts/kfc/align_kfc_camera.py"

fail(){ echo "❌ $*" >&2; exit 1; }

case "$KFC_ALIGN_REFERENCE_DIR" in
  "~") KFC_ALIGN_REFERENCE_DIR="$HOST_HOME" ;;
  "~/"*) KFC_ALIGN_REFERENCE_DIR="$HOST_HOME/${KFC_ALIGN_REFERENCE_DIR#\~/}" ;;
esac

[ -d "$KFC_ALIGN_REFERENCE_DIR" ] \
  || fail "KFCv2 参考图目录不存在：$KFC_ALIGN_REFERENCE_DIR"

KFC_ALIGN_REFERENCE=""
latest_created=-1
latest_mtime=-1
while IFS= read -r -d '' candidate; do
  created="$(stat -c '%W' "$candidate" 2>/dev/null || echo 0)"
  mtime="$(stat -c '%Y' "$candidate" 2>/dev/null || echo 0)"
  [ "$created" -gt 0 ] || created="$mtime"
  if [ "$created" -gt "$latest_created" ] \
     || { [ "$created" -eq "$latest_created" ] && [ "$mtime" -gt "$latest_mtime" ]; }; then
    KFC_ALIGN_REFERENCE="$candidate"
    latest_created="$created"
    latest_mtime="$mtime"
  fi
done < <(find "$KFC_ALIGN_REFERENCE_DIR" -maxdepth 1 -type f \
  \( -iname '*.jpg' -o -iname '*.jpeg' \) -print0)

[ -n "$KFC_ALIGN_REFERENCE" ] \
  || fail "KFCv2 参考图目录中没有 JPEG：$KFC_ALIGN_REFERENCE_DIR"

docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME" \
  || fail "容器 $CONTAINER_NAME 未运行，无法打开 KFCv2 对齐窗口。"
docker exec "$CONTAINER_NAME" test -r "$ALIGN_TOOL" \
  || fail "容器内缺少对齐脚本：$ALIGN_TOOL。请重新运行 migrate_software.sh。"
docker exec "$CONTAINER_NAME" test -r "$KFC_ALIGN_REFERENCE" \
  || fail "容器内找不到标准图：$KFC_ALIGN_REFERENCE"

echo
echo "▸ KFCv2 采集前画面对齐"
echo "  实时 topic：$KFC_ALIGN_TOPIC"
echo "  参考目录：  $KFC_ALIGN_REFERENCE_DIR"
echo "  最新标准图：$KFC_ALIGN_REFERENCE"
echo "  调整相机并核对；关闭窗口表示确认，随后才会启动本次采集。"

docker exec -it \
  -e DISPLAY="${DISPLAY:-:0}" \
  -e ROS_DOMAIN_ID="$ROS_DOMAIN_ID" \
  "$CONTAINER_NAME" bash -c '
    source /opt/ros/humble/setup.bash
    [ -f "$1/pika_ros/install/setup.bash" ] && source "$1/pika_ros/install/setup.bash"
    /usr/bin/python3 "$2" --topic "$3" --reference "$4" --fps "$5"
  ' _ "$PIKA_DIR" "$ALIGN_TOOL" "$KFC_ALIGN_TOPIC" "$KFC_ALIGN_REFERENCE" "$KFC_ALIGN_FPS"

status=$?
[ "$status" -eq 0 ] || fail "KFCv2 画面对齐未完成（退出码 $status），本次不启动采集。"
