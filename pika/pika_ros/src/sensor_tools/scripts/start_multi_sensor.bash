#!/bin/bash
set -o pipefail

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
PIKA_ROOT=$(readlink -f "$SCRIPT_DIR/../../../..")
RUNTIME_ENV="${PIKA_RUNTIME_ENV:-$PIKA_ROOT/pika_runtime.env}"
[ -f "$RUNTIME_ENV" ] && source "$RUNTIME_ENV"

camera_fps="${CAMERA_FPS:-30}"
camera_width="${CAMERA_WIDTH:-640}"
camera_height="${CAMERA_HEIGHT:-480}"
l_depth_camera_no="${L_DEPTH_CAMERA_NO:-230322273597}"
r_depth_camera_no="${R_DEPTH_CAMERA_NO:-230422273164}"

l_serial_port="${L_SERIAL_PORT:-/dev/ttyUSB50}"
r_serial_port="${R_SERIAL_PORT:-/dev/ttyUSB51}"
l_fisheye_port="${L_FISHEYE_PORT:-50}"
r_fisheye_port="${R_FISHEYE_PORT:-51}"
head_camera_driver="${HEAD_CAMERA_DRIVER:-orbbec}"
head_camera_port="${HEAD_CAMERA_PORT:-52}"
head_camera_ip="${HEAD_CAMERA_IP:-192.168.20.30}"

sudo chmod a+rw /dev/ttyUSB* 2>/dev/null || true
sudo chmod a+rw /dev/video* 2>/dev/null || true

source /opt/ros/humble/setup.bash
if [ "$head_camera_driver" = "kfcv2" ]; then
    if [ ! -f /opt/dexe_sensors/install/setup.bash ]; then
        echo "[start_multi_sensor] missing /opt/dexe_sensors/install/setup.bash for HEAD_CAMERA_DRIVER=kfcv2" >&2
        exit 1
    fi
    source /opt/dexe_sensors/install/setup.bash
fi
source "$PIKA_ROOT/pika_ros/install/setup.bash"

usb_camera="$PIKA_ROOT/pika_ros/install/sensor_tools/share/sensor_tools/scripts/usb_camera.py"
[ -f "$usb_camera" ] && chmod 777 "$usb_camera" 2>/dev/null || true

LAUNCH_ARGS=(
    l_depth_camera_no:=_"$l_depth_camera_no"
    r_depth_camera_no:=_"$r_depth_camera_no"
    l_serial_port:="$l_serial_port"
    r_serial_port:="$r_serial_port"
    l_fisheye_port:="$l_fisheye_port"
    r_fisheye_port:="$r_fisheye_port"
    head_camera_driver:="$head_camera_driver"
    head_camera_port:="$head_camera_port"
    head_camera_ip:="$head_camera_ip"
    camera_fps:="$camera_fps"
    camera_width:="$camera_width"
    camera_height:="$camera_height"
    camera_profile:="$camera_width,$camera_height,$camera_fps"
)

if [ -n "${1:-}" ]; then
    LAUNCH_ARGS+=(name:="$1" name_index:="$1"_)
fi

ros2 launch sensor_tools open_multi_sensor.launch.py "${LAUNCH_ARGS[@]}"
