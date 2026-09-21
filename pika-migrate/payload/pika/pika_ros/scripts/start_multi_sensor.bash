#!/bin/bash
set -o pipefail

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
PIKA_ROOT=$(readlink -f "$SCRIPT_DIR/../..")
RUNTIME_ENV="${PIKA_RUNTIME_ENV:-$PIKA_ROOT/pika_runtime.env}"
HARDWARE_ENV="${PIKA_HARDWARE_ENV:-$PIKA_ROOT/pika_hardware.env}"
head_camera_driver_override="${HEAD_CAMERA_DRIVER:-}"
[ -f "$RUNTIME_ENV" ] || { echo "[start_multi_sensor] missing runtime config: $RUNTIME_ENV" >&2; exit 1; }
[ -f "$HARDWARE_ENV" ] || { echo "[start_multi_sensor] missing hardware config: $HARDWARE_ENV; run setup_hardware.sh" >&2; exit 1; }
source "$RUNTIME_ENV"
source "$HARDWARE_ENV"

for required in L_DEPTH_CAMERA_NO R_DEPTH_CAMERA_NO PIKA_L_CODE PIKA_R_CODE; do
    [ -n "${!required:-}" ] || { echo "[start_multi_sensor] missing $required in $HARDWARE_ENV" >&2; exit 1; }
done
export pika_L_code="$PIKA_L_CODE"
export pika_R_code="$PIKA_R_CODE"

camera_fps="${CAMERA_FPS:-30}"
camera_width="${CAMERA_WIDTH:-640}"
camera_height="${CAMERA_HEIGHT:-480}"
l_depth_camera_no="${L_DEPTH_CAMERA_NO#_}"
r_depth_camera_no="${R_DEPTH_CAMERA_NO#_}"

l_serial_port="${L_SERIAL_PORT:-/dev/ttyUSB50}"
r_serial_port="${R_SERIAL_PORT:-/dev/ttyUSB51}"
l_fisheye_port="${L_FISHEYE_PORT:-50}"
r_fisheye_port="${R_FISHEYE_PORT:-51}"
head_camera_driver="${head_camera_driver_override:-${HEAD_CAMERA_DRIVER:-kfcv2}}"
head_camera_device="${HEAD_CAMERA_DEVICE:-/dev/kfcv2-camera}"
head_camera_width="${HEAD_CAMERA_WIDTH:-3840}"
head_camera_height="${HEAD_CAMERA_HEIGHT:-1080}"
head_camera_fps="${HEAD_CAMERA_FPS:-30}"

sudo chmod a+rw /dev/ttyUSB* 2>/dev/null || true
sudo chmod a+rw /dev/video* 2>/dev/null || true

source /opt/ros/humble/setup.bash
source "$SCRIPT_DIR/../install/setup.bash"

usb_camera="$SCRIPT_DIR/../install/sensor_tools/share/sensor_tools/scripts/usb_camera.py"
[ -f "$usb_camera" ] && chmod 777 "$usb_camera" 2>/dev/null || true

LAUNCH_ARGS=(
    l_depth_camera_no:=_"$l_depth_camera_no"
    r_depth_camera_no:=_"$r_depth_camera_no"
    l_serial_port:="$l_serial_port"
    r_serial_port:="$r_serial_port"
    l_fisheye_port:="$l_fisheye_port"
    r_fisheye_port:="$r_fisheye_port"
    head_camera_driver:="$head_camera_driver"
    head_camera_device:="$head_camera_device"
    head_camera_width:="$head_camera_width"
    head_camera_height:="$head_camera_height"
    head_camera_fps:="$head_camera_fps"
    camera_fps:="$camera_fps"
    camera_width:="$camera_width"
    camera_height:="$camera_height"
    camera_profile:="$camera_width,$camera_height,$camera_fps"
)

if [ -n "${1:-}" ]; then
    LAUNCH_ARGS+=(name:="$1" name_index:="$1"_)
fi

ros2 launch sensor_tools open_multi_sensor.launch.py "${LAUNCH_ARGS[@]}"
