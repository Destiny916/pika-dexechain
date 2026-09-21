#!/usr/bin/env bash
set -o pipefail

source /opt/ros/humble/setup.bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
export ROS_DOMAIN_ID=20
export CYCLONEDDS_URI='<CycloneDDS><Domain><General><NetworkInterfaceAddress>192.168.20.21</NetworkInterfaceAddress><AllowMulticast>spdp</AllowMulticast></General></Domain></CycloneDDS>'

DEFAULT_LEFT_DEVICE="/dev/v4l/by-path/platform-3610000.usb-usb-0:2.1.1:1.0-video-index0"
DEFAULT_RIGHT_DEVICE="/dev/v4l/by-path/platform-3610000.usb-usb-0:2.2.1:1.0-video-index0"
FISHEYE_CAMERA_CONFIG="${FISHEYE_CAMERA_CONFIG:-$HOME/.config/dexforce/pika_fisheye_camera.conf}"

# 命令行环境变量优先于本机配置文件和默认设备路径。
ENV_LEFT_DEVICE="${LEFT_DEVICE:-}"
ENV_RIGHT_DEVICE="${RIGHT_DEVICE:-}"
unset LEFT_DEVICE RIGHT_DEVICE
if [[ -f "$FISHEYE_CAMERA_CONFIG" ]]; then
    source "$FISHEYE_CAMERA_CONFIG"
    echo "已加载鱼眼相机配置：$FISHEYE_CAMERA_CONFIG"
fi
CONFIG_LEFT_DEVICE="${LEFT_DEVICE:-}"
CONFIG_RIGHT_DEVICE="${RIGHT_DEVICE:-}"
LEFT_DEVICE="${ENV_LEFT_DEVICE:-${CONFIG_LEFT_DEVICE:-$DEFAULT_LEFT_DEVICE}}"
RIGHT_DEVICE="${ENV_RIGHT_DEVICE:-${CONFIG_RIGHT_DEVICE:-$DEFAULT_RIGHT_DEVICE}}"
CAM_NODE="${CAM_NODE:-$SCRIPT_DIR/usb_camera.py}"

PIDS=()
CLEANED_UP=false

ensure_compressed_image_transport() {
    local apt_package="ros-${ROS_DISTRO}-compressed-image-transport"

    if ros2 pkg prefix compressed_image_transport >/dev/null 2>&1; then
        return
    fi

    echo "未检测到 compressed_image_transport，准备安装 $apt_package"
    if ! command -v apt-get >/dev/null 2>&1; then
        echo "错误：系统没有 apt-get，无法自动安装 $apt_package" >&2
        return 1
    fi

    if ((EUID == 0)); then
        apt-get install -y "$apt_package" || return 1
    elif ! command -v sudo >/dev/null 2>&1; then
        echo "错误：当前用户不是 root 且系统没有 sudo，请手动安装 $apt_package" >&2
        return 1
    elif [[ -t 0 ]]; then
        sudo apt-get install -y "$apt_package" || return 1
    elif sudo -n true 2>/dev/null; then
        sudo -n apt-get install -y "$apt_package" || return 1
    else
        echo "错误：非交互启动时 sudo 需要密码，无法自动安装 $apt_package" >&2
        echo "请先执行：sudo apt-get install -y $apt_package" >&2
        return 1
    fi

    # 重新加载 ROS 环境并校验插件。
    source "/opt/ros/${ROS_DISTRO}/setup.bash"
    if ! ros2 pkg prefix compressed_image_transport >/dev/null 2>&1; then
        echo "错误：$apt_package 安装后仍无法找到 compressed_image_transport" >&2
        return 1
    fi
    echo "compressed_image_transport 安装完成"
}

resolve_video_port() {
    local device="$1"
    local resolved

    if [[ ! -e "$device" ]]; then
        echo "错误：找不到相机设备 $device" >&2
        return 1
    fi

    resolved="$(readlink -f "$device")"
    if [[ ! "$resolved" =~ ^/dev/video([0-9]+)$ ]]; then
        echo "错误：无法解析相机设备 $device -> $resolved" >&2
        return 1
    fi

    echo "${BASH_REMATCH[1]}"
}

list_fisheye_candidates() {
    local device
    local found=false
    local -a devices=()

    if ! command -v v4l2-ctl >/dev/null 2>&1; then
        echo "  无法扫描：系统未安装 v4l2-ctl" >&2
        return
    fi

    shopt -s nullglob
    devices=(/dev/v4l/by-path/*-video-index0)
    shopt -u nullglob

    for device in "${devices[@]}"; do
        if v4l2-ctl --info -d "$device" 2>/dev/null |
            grep -F "DECXIN" >/dev/null; then
            echo "  $device -> $(readlink -f "$device")"
            found=true
        fi
    done

    if [[ "$found" == false ]]; then
        echo "  未检测到 DECXIN CAMERA 的 video-index0 设备"
    fi
}

check_configured_devices() {
    if [[ -e "$LEFT_DEVICE" && -e "$RIGHT_DEVICE" ]]; then
        return
    fi

    [[ -e "$LEFT_DEVICE" ]] || echo "错误：配置的左鱼眼设备不存在：$LEFT_DEVICE" >&2
    [[ -e "$RIGHT_DEVICE" ]] || echo "错误：配置的右鱼眼设备不存在：$RIGHT_DEVICE" >&2
    echo >&2
    echo "检测到的 DECXIN CAMERA 候选设备：" >&2
    list_fisheye_candidates >&2
    echo >&2
    echo "请确认左右相机后更新配置文件：$FISHEYE_CAMERA_CONFIG" >&2
    echo "配置示例：" >&2
    echo "  LEFT_DEVICE=/dev/v4l/by-path/...-video-index0" >&2
    echo "  RIGHT_DEVICE=/dev/v4l/by-path/...-video-index0" >&2
    return 1
}

check_camera_port() {
    local side="$1"
    local device="$2"
    local port="$3"

    if [[ ! -e "/dev/video${port}" ]]; then
        echo "错误：/dev/video${port} 不存在" >&2
        return 1
    fi

    if ! v4l2-ctl --info -d "/dev/video${port}" 2>/dev/null |
        grep -F "DECXIN" >/dev/null; then
        echo "错误：${side}设备不是 DECXIN CAMERA：$device -> /dev/video${port}" >&2
        return 1
    fi

    # 检查相机节点支持的格式列表是否包含 MJPG。
    if ! v4l2-ctl --list-formats-ext -d "/dev/video${port}" 2>/dev/null |
        grep "'MJPG'" >/dev/null; then
        echo "错误：/dev/video${port} 不是支持 MJPG 的图像节点" >&2
        return 1
    fi
}

cleanup() {
    if [[ "$CLEANED_UP" == true ]]; then
        return
    fi
    CLEANED_UP=true
    trap - EXIT INT TERM

    if ((${#PIDS[@]} > 0)); then
        echo
        echo "正在停止鱼眼相机与压缩节点……"
        kill -SIGINT "${PIDS[@]}" 2>/dev/null || true
        wait "${PIDS[@]}" 2>/dev/null || true
        echo "鱼眼相机与压缩节点已停止"
    fi
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

ensure_compressed_image_transport || exit 1

if [[ ! -f "$CAM_NODE" ]]; then
    echo "错误：找不到 $CAM_NODE" >&2
    exit 1
fi

check_configured_devices || exit 1

LEFT_PORT="$(resolve_video_port "$LEFT_DEVICE")" || exit 1
RIGHT_PORT="$(resolve_video_port "$RIGHT_DEVICE")" || exit 1

if [[ "$LEFT_PORT" == "$RIGHT_PORT" ]]; then
    echo "错误：左右鱼眼配置指向同一个设备：/dev/video${LEFT_PORT}" >&2
    exit 1
fi

echo "左鱼眼设备：$LEFT_DEVICE -> /dev/video$LEFT_PORT"
echo "右鱼眼设备：$RIGHT_DEVICE -> /dev/video$RIGHT_PORT"

check_camera_port "左鱼眼" "$LEFT_DEVICE" "$LEFT_PORT" || exit 1
check_camera_port "右鱼眼" "$RIGHT_DEVICE" "$RIGHT_PORT" || exit 1

echo "启动左手鱼眼：/dev/video${LEFT_PORT}"
python3 "$CAM_NODE" \
    --ros-args \
    -r __node:=camera_fisheye_l \
    -p camera_port:="$LEFT_PORT" \
    -p camera_fps:=30 \
    -p camera_width:=640 \
    -p camera_height:=480 \
    -p camera_frame_id:=camera_fisheye_l_link \
    -r /camera_rgb/color/image_raw:=/camera_fisheye_l/color/image_raw_uncompressed \
    -r /camera_rgb/color/camera_info:=/camera_fisheye_l/color/camera_info &
PIDS+=("$!")

echo "启动右手鱼眼：/dev/video${RIGHT_PORT}"
python3 "$CAM_NODE" \
    --ros-args \
    -r __node:=camera_fisheye_r \
    -p camera_port:="$RIGHT_PORT" \
    -p camera_fps:=30 \
    -p camera_width:=640 \
    -p camera_height:=480 \
    -p camera_frame_id:=camera_fisheye_r_link \
    -r /camera_rgb/color/image_raw:=/camera_fisheye_r/color/image_raw_uncompressed \
    -r /camera_rgb/color/camera_info:=/camera_fisheye_r/color/camera_info &
PIDS+=("$!")

echo "启动左手鱼眼压缩节点"
ros2 run image_transport republish raw compressed --ros-args \
    -r __node:=pika_fisheye_left_compressor \
    -r in:=/camera_fisheye_l/color/image_raw_uncompressed \
    -r out/compressed:=/camera_fisheye_l/color/image_raw &
PIDS+=("$!")

echo "启动右手鱼眼压缩节点"
ros2 run image_transport republish raw compressed --ros-args \
    -r __node:=pika_fisheye_right_compressor \
    -r in:=/camera_fisheye_r/color/image_raw_uncompressed \
    -r out/compressed:=/camera_fisheye_r/color/image_raw &
PIDS+=("$!")

echo
echo "鱼眼相机与压缩传输已启动："
echo "  /camera_fisheye_l/color/image_raw (sensor_msgs/msg/CompressedImage)"
echo "  /camera_fisheye_r/color/image_raw (sensor_msgs/msg/CompressedImage)"
echo "按 Ctrl+C 同时停止"
echo

# 任意一个相机或压缩节点退出后，cleanup 会停止其余进程。
wait -n "${PIDS[@]}"
STATUS=$?
echo "检测到一个鱼眼相机或压缩节点退出，status=$STATUS"
exit "$STATUS"
