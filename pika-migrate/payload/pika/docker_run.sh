#!/bin/bash
# 启动 pika 持久容器（X11 + USB + host 网络；GPU 按 USE_GPU 开关）
# 用法: bash docker_run.sh   然后用 docker exec -it pika bash 进入
set -e

IMAGE_NAME="pika:humble"
CONTAINER_NAME="pika"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_ENV="${PIKA_RUNTIME_ENV:-$SCRIPT_DIR/pika_runtime.env}"
[ -f "$RUNTIME_ENV" ] && source "$RUNTIME_ENV"
HARDWARE_ENV="${PIKA_HARDWARE_ENV:-$SCRIPT_DIR/pika_hardware.env}"
[ -f "$HARDWARE_ENV" ] && source "$HARDWARE_ENV"

IMAGE_NAME="${IMAGE_NAME:-pika:humble}"
CONTAINER_NAME="${CONTAINER_NAME:-pika}"
PIKA_DIR="${PIKA_DIR:-$SCRIPT_DIR}"
HOST_HOME="${HOST_HOME:-/home/kw}"
AGILEX_DIR="${AGILEX_DIR:-$HOST_HOME/agilex}"
ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-42}"
HEAD_CAMERA_DRIVER="${HEAD_CAMERA_DRIVER:-kfcv2}"
HEAD_CAMERA_DEVICE="${HEAD_CAMERA_DEVICE:-/dev/kfcv2-camera}"
HEAD_CAMERA_WIDTH="${HEAD_CAMERA_WIDTH:-3840}"
HEAD_CAMERA_HEIGHT="${HEAD_CAMERA_HEIGHT:-1080}"
HEAD_CAMERA_FPS="${HEAD_CAMERA_FPS:-30}"
HEAD_CAMERA_MIN_FPS="${HEAD_CAMERA_MIN_FPS:-25}"
USE_GPU="${USE_GPU:-false}"

GPU_ARGS=()
case "$USE_GPU" in
  1|true|TRUE|yes|YES|on|ON)
    GPU_ARGS=(--gpus all -e NVIDIA_DRIVER_CAPABILITIES=all -e NVIDIA_VISIBLE_DEVICES=all)
    ;;
  *)
    echo "USE_GPU=false，容器不请求 GPU"
    ;;
esac

# 允许容器内 GUI(rviz/rqt/realsense-viewer) 连接宿主 X server
xhost +local:root >/dev/null 2>&1 || true

# 若同名容器已存在则先删除
if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  echo "已存在容器 $CONTAINER_NAME，先删除..."
  docker rm -f "$CONTAINER_NAME" >/dev/null
fi

# ROS_DOMAIN_ID：与局域网其它 ROS2 机器隔离，防 topic 串扰污染采集
docker run -id --name "$CONTAINER_NAME" \
  --init \
  --privileged \
  -e ROS_DOMAIN_ID="$ROS_DOMAIN_ID" \
  -e PIKA_RUNTIME_ENV="$PIKA_DIR/pika_runtime.env" \
  -e PIKA_HARDWARE_ENV="$PIKA_DIR/pika_hardware.env" \
  -e HEAD_CAMERA_DRIVER="$HEAD_CAMERA_DRIVER" \
  -e HEAD_CAMERA_DEVICE="$HEAD_CAMERA_DEVICE" \
  -e HEAD_CAMERA_WIDTH="$HEAD_CAMERA_WIDTH" \
  -e HEAD_CAMERA_HEIGHT="$HEAD_CAMERA_HEIGHT" \
  -e HEAD_CAMERA_FPS="$HEAD_CAMERA_FPS" \
  -e HEAD_CAMERA_MIN_FPS="$HEAD_CAMERA_MIN_FPS" \
  "${GPU_ARGS[@]}" \
  --network=host \
  -e DISPLAY="$DISPLAY" -e QT_X11_NO_MITSHM=1 \
  -v /tmp/.X11-unix:/tmp/.X11-unix \
  -v /dev:/dev \
  --shm-size 8G -v /dev/shm:/dev/shm \
  -v "$PIKA_DIR:$PIKA_DIR" \
  -v "$AGILEX_DIR:$AGILEX_DIR" \
  "$IMAGE_NAME" sleep infinity

echo "容器 $CONTAINER_NAME 已启动。进入: docker exec -it $CONTAINER_NAME bash"
