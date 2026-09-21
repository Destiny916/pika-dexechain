#!/bin/bash
# =============================================================================
# Pika 迁移 · 硬件轨引导式配置
# -----------------------------------------------------------------------------
# 作用：把「换机器一定会变」的物理相关配置，用引导式 + 插拔自动识别做掉：
#   ① 静态规则/头相机依赖（81-vive + KFCv2 USB udev/帧验证）
#   ② 按手柄绑定/LHR      —— 一次插一只手柄配夹爪 udev + D405；探测 LHR 并写入硬件配置
#   ③ 引导基站校准        —— survive-cli 交互式，先建立有效定位坐标再启动定位节点
#   ④ 左右手核对          —— 鱼眼图像定物理左右，pose 同步性纠 LHR，反了一键对调
#
# 用法：  bash setup_hardware.sh        （菜单式，每项可单独跑 / 跳过）
# 注意：  udev 操作需要 sudo，脚本会在需要时提示输入密码。
# =============================================================================
set -uo pipefail

# ---- 可调参数 --------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/pika_migrate.conf}"
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

PIKA_USER="${PIKA_USER:-${SUDO_USER:-${USER:-$(id -un)}}}"
HOST_HOME="${HOST_HOME:-/home/${PIKA_USER}}"
APP_DIR="${APP_DIR:-$HOST_HOME/app}"
PIKA_DIR="${PIKA_DIR:-$APP_DIR/pika}"
CONTAINER_NAME="${CONTAINER_NAME:-pika}"
TRACKER_MODE="${TRACKER_MODE:-auto}"            # auto | wired | wireless
BIND_RULES="$PIKA_DIR/pika-sensor-bind.rules"
VIVE_RULES="$PIKA_DIR/pika_ros/scripts/81-vive.rules"
HARDWARE_ENV="${PIKA_HARDWARE_ENV:-$PIKA_DIR/pika_hardware.env}"
KFCV2_RULES="$SCRIPT_DIR/99-kfcv2-head.rules"
KFCV2_HELPERS="$SCRIPT_DIR/lib/kfcv2_usb.sh"
HEAD_CAMERA_DEVICE="${HEAD_CAMERA_DEVICE:-/dev/kfcv2-camera}"
HEAD_CAMERA_WIDTH="${HEAD_CAMERA_WIDTH:-3840}"
HEAD_CAMERA_HEIGHT="${HEAD_CAMERA_HEIGHT:-1080}"
HEAD_CAMERA_FPS="${HEAD_CAMERA_FPS:-30}"
POSE_PROBE="$SCRIPT_DIR/pose_motion_probe.py"
# 鱼眼绑定用的偶数 video 捕获节点匹配（来源：源机 pika-sensor-bind.rules 的原始写法）
VIDEO_EVEN='video[0,2,4,6,8,10,12,14,16,18,20,22,24,26,28,30,32,34,36,38,40,42,44,46,48]*'

[ -f "$KFCV2_HELPERS" ] || { echo "找不到 $KFCV2_HELPERS" >&2; exit 1; }
source "$KFCV2_HELPERS"
[ ! -f "$HARDWARE_ENV" ] || source "$HARDWARE_ENV"

# ---- 输出小工具 ------------------------------------------------------------
c_g='\033[32m'; c_r='\033[31m'; c_y='\033[33m'; c_b='\033[36m'; c_0='\033[0m'
info(){ echo -e "${c_b}▸${c_0} $*"; }
ok(){   echo -e "${c_g}✅ $*${c_0}"; }
warn(){ echo -e "${c_y}⚠️  $*${c_0}"; }
err(){  echo -e "${c_r}❌ $*${c_0}" >&2; }
title(){ echo; echo -e "${c_b}━━ $* ━━${c_0}"; }
pause(){ read -rp "$(echo -e "${c_y}↩  $*${c_0}")" _; }

# ---- 探测工具（集中放这里，被各 stage 调用）-------------------------------
# 取设备所属 USB interface 的 KERNELS 名，如 /dev/ttyUSB0 -> 1-1.4.4.4:1.0
iface_of(){ udevadm info -q path -n "$1" 2>/dev/null | grep -oE '[0-9]+-[0-9.]+:[0-9]+\.[0-9]+' | tail -1; }
# 某 video 节点是否鱼眼（只认厂商 1bcf=DECXIN；RealSense 8086 因不匹配自然排除）
is_fisheye(){ [ "$(udevadm info -q property -n "$1" 2>/dev/null | sed -n 's/^ID_VENDOR_ID=//p')" = "1bcf" ]; }
# 当前所有 ttyUSB / 鱼眼 video 真实节点（每行一个，已排序）
# snap_fish 排除软链（video50/51 是我们建的 SYMLINK，glob 会命中，必须剔除否则污染 diff）
snap_tty(){ for t in /dev/ttyUSB*; do [ -e "$t" ] && [ ! -L "$t" ] && echo "$t"; done | sort; }
snap_fish(){ for v in /dev/video*; do [ -e "$v" ] && [ ! -L "$v" ] && is_fisheye "$v" && echo "$v"; done | sort; }
snap_wired_lhr(){ list_wired_trackers | grep -oE 'LHR-[0-9A-Fa-f]{8}' | sort -u; }
# 容器内枚举 D405 序列号（12 位，加词边界避免误抓 firmware/path 里的数字）
enum_d405(){ docker exec "$CONTAINER_NAME" rs-enumerate-devices -s 2>/dev/null | grep -oE '\b[0-9]{12}\b' | sort -u; }
# 列出在线接收器 dongle（本套 Sense 走 watchman dongle，USB serial 永远是裸的、不会是 LHR）
list_dongle(){
  for s in /sys/bus/usb/devices/*/product; do
    case "$(cat "$s" 2>/dev/null)" in
      *Watchman*|*LHR*) echo "$(basename "$(dirname "$s")"):$(cat "$(dirname "$s")/serial" 2>/dev/null)";;
    esac
  done | sort -u
}
is_wired_tracker_pid(){
  case "$1" in
    2012|2022|2300) return 0 ;; # 81-vive.rules: Watchman wired / Tracker wired / Tracker 2018 wired
    *) return 1 ;;
  esac
}
list_wired_trackers(){
  local d vid pid serial product
  for d in /sys/bus/usb/devices/*; do
    [ -f "$d/idVendor" ] || continue
    vid=$(cat "$d/idVendor" 2>/dev/null)
    pid=$(cat "$d/idProduct" 2>/dev/null)
    [ "$vid" = "28de" ] || continue
    is_wired_tracker_pid "$pid" || continue
    serial=$(cat "$d/serial" 2>/dev/null)
    product=$(cat "$d/product" 2>/dev/null)
    echo "$(basename "$d"):$serial pid=$pid product=${product:-?}"
  done | sort -u
}
detect_tracker_mode(){
  local wired_count mode="$TRACKER_MODE"
  wired_count=$(list_wired_trackers | grep -c 'LHR-[0-9A-Fa-f]\{8\}' || true)
  case "$mode" in
    auto)
      if [ "$wired_count" -gt 0 ]; then
        echo "wired"
      else
        echo "wireless"
      fi
      ;;
    wired|wireless) echo "$mode" ;;
    *)
      warn "非法 TRACKER_MODE=$TRACKER_MODE，按 auto 处理。"
      TRACKER_MODE=auto detect_tracker_mode
      ;;
  esac
}
print_tracker_mode_status(){
  local mode="$1" wired online
  wired=$(list_wired_trackers)
  online=$(list_dongle)
  case "$mode" in
    wired)
      info "定位连接模式：wired（检测定位标签通过短 USB 线接入 Pika 主体，主机应看到 2 个 28de wired LHR）"
      if [ -n "$wired" ]; then
        echo "$wired" | sed 's/^/  wired: /'
      else
        warn "未检测到 wired LHR。检查大头短 USB 线、Pika 主体接口、主 USB-C 连接。"
      fi
      ;;
    wireless)
      info "定位连接模式：wireless（定位标签通过独立 Watchman dongle 通信，需提前 Steam 绑定）"
      if [ -n "$online" ]; then
        echo "$online" | sed 's/^/  receiver: /'
      else
        warn "未检测到 Watchman dongle。检查接收器是否插好。"
      fi
      ;;
  esac
}
warn_existing_sensor_topics(){
  warn "检测到已有 camera_fisheye topic。可能原因："
  warn "  1) 本容器里已经启动过 start_multi_sensor.bash；"
  warn "  2) ROS_DOMAIN_ID 与局域网内另一套正在数采/运行的 PIKA 冲突，收到了对方 topic。"
  warn "处理建议："
  warn "  1) 若只是本容器残留，执行：docker restart $CONTAINER_NAME"
  warn "  2) 若局域网内有另一套 PIKA，请给本机换一个 ROS_DOMAIN_ID。"
  warn "     修改 $CONFIG_FILE，例如：ROS_DOMAIN_ID=\"\${ROS_DOMAIN_ID:-43}\""
  warn "     然后重建容器让环境变量生效：docker rm -f $CONTAINER_NAME && bash $SCRIPT_DIR/migrate_software.sh"
}
# 集合差：在 $2(after) 但不在 $1(before) 的行（两侧须已排序，snap_*/enum_* 已保证）
added(){ comm -13 <(printf '%s\n' "$1") <(printf '%s\n' "$2"); }

# 读在线大头的 LHR 序列号（容器内编译+跑 lhr_probe，每行一个 LHR-xxxx，已排序去重）
# 用 survive_simple_serial_number，config 一到就有，不需解算/校准；独占 dongle，勿与 start_multi_sensor 同跑。
LHR_SRC="$PIKA_DIR/pika_ros/scripts/lhr_probe.c"
detect_lhr_codes(){
  docker exec -e PIKA_DIR="$PIKA_DIR" "$CONTAINER_NAME" bash -c '
    set -e
    D="$PIKA_DIR/pika_ros/install/libsurvive"
    SRC="$PIKA_DIR/pika_ros/scripts/lhr_probe.c"
    BIN=/tmp/lhr_probe
    [ -f "$SRC" ] || { echo "NOSRC" >&2; exit 2; }
    if [ ! -x "$BIN" ] || [ "$SRC" -nt "$BIN" ]; then
      gcc "$SRC" -o "$BIN" -I"$D/include" -I"$D/include/libsurvive" \
        -I"$D/include/libsurvive/redist" -I"$D/include/cnkalman" -I"$D/include/cnmatrix" \
        -L"$D/lib" -lsurvive >/tmp/lhr_cc.log 2>&1 || { echo "CCFAIL" >&2; cat /tmp/lhr_cc.log >&2; exit 3; }
    fi
    export LD_LIBRARY_PATH="$D/lib:$LD_LIBRARY_PATH"
    timeout 30 "$BIN" 2>/dev/null | grep -oE "LHR-[0-9A-Fa-f]{8}"
  ' 2>/dev/null | sort -u
}
detect_wired_lhr_codes(){
  list_wired_trackers | grep -oE 'LHR-[0-9A-Fa-f]{8}' | sort -u
}
configure_wireless_lhr_codes(){
  local cur_L cur_R d1 d2
  local codes=()

  if sensor_topics_present; then
    err "已有设备栈占用 Watchman dongle，无法在②探测 wireless LHR。"
    err "请先执行 docker restart $CONTAINER_NAME，再重跑②。"
    return 1
  fi

  info "wireless 模式探测在线大头 LHR（约 10~30s，期间独占 dongle）…"
  mapfile -t codes < <(detect_lhr_codes)
  case "${#codes[@]}" in
    0)
      err "没读到 LHR。请确认两只定位标签已开机、绿灯常亮，且两个 Watchman dongle 已连接。"
      return 1
      ;;
    1)
      err "只读到一个 LHR（${codes[0]}）。请排查另一只定位标签/dongle 后重跑②。"
      return 1
      ;;
    2)
      d1="${codes[0]}"
      d2="${codes[1]}"
      ;;
    *)
      err "读到 ${#codes[@]} 个 LHR，无法确定本套设备是哪两个：${codes[*]}"
      err "请断开其他定位标签/接收器后重跑②。"
      return 1
      ;;
  esac

  cur_L="${PIKA_L_CODE:-}"
  cur_R="${PIKA_R_CODE:-}"
  if { [ "$d1" = "$cur_L" ] && [ "$d2" = "$cur_R" ]; } ||
     { [ "$d1" = "$cur_R" ] && [ "$d2" = "$cur_L" ]; }; then
    PIKA_L_CODE="$cur_L"
    PIKA_R_CODE="$cur_R"
    ok "wireless LHR 与现有左右配置一致：左 $cur_L / 右 $cur_R"
  else
    warn "wireless 模式只能先识别设备集合，暂不能自动确定物理左右。"
    PIKA_L_CODE="$d1"
    PIKA_R_CODE="$d2"
    ok "wireless LHR 已写入：左(暂定) $d1 / 右(暂定) $d2"
    warn "完成③基站校准后，④会通过挥左手检查 pose，并可一键对调。"
  fi
  export PIKA_L_CODE PIKA_R_CODE
}
sensor_topics_present(){
  docker exec "$CONTAINER_NAME" bash -c 'export PS1=pika; source /root/.bashrc 2>/dev/null; ros2 topic list 2>/dev/null | grep -q camera_fisheye'
}
sensor_stack_present(){
  docker exec "$CONTAINER_NAME" bash -c '
    pgrep -f "[o]pen_multi_sensor|[p]ika_double_locator_node|[c]amera_fisheye_[lr]" >/dev/null
  ' 2>/dev/null
}
start_sensor_stack(){
  docker exec -e PIKA_DIR="$PIKA_DIR" -e HEAD_CAMERA_DRIVER=none "$CONTAINER_NAME" bash -c '
    mkdir -p /tmp/pika_lr_check
    export PS1=pika
    cd "$PIKA_DIR/pika_ros/scripts"
    echo "[setup_hardware] temporary stack: HEAD_CAMERA_DRIVER=none" >/tmp/pika_lr_check/start_multi_sensor.log
    setsid bash start_multi_sensor.bash >>/tmp/pika_lr_check/start_multi_sensor.log 2>&1 </dev/null &
    echo $! >/tmp/pika_lr_check/start_multi_sensor.pid
  ' >/dev/null
}
stop_sensor_stack(){
  docker exec "$CONTAINER_NAME" bash -c '
    patterns="ros2 launch sensor_tools open_multi_sensor.launch.py|pika_double_locator_node|rviz2|realsense2_camera_node|usb_camera.py|kfcv2_usb_publisher.py|serial_gripper_imu"
    matching_pids(){
      ps -eo pid=,args= |
        awk -v self="$$" -v pat="$patterns" \
          "\$1 != self && \$0 ~ pat && \$0 !~ /awk -v self/ {print \$1}"
    }

    # Only signal ros2 launch first. It owns the children and will shut them
    # down without triggering the double-SIGINT/double-rclpy.shutdown race.
    launch_pid=$(ps -eo pid=,args= |
      awk -v self="$$" \
        "\$1 != self && \$0 ~ /ros2 launch sensor_tools open_multi_sensor.launch.py/ &&
         \$0 !~ /awk -v self/ {print \$1; exit}")
    if [ -n "$launch_pid" ]; then
      kill -INT "$launch_pid" 2>/dev/null || true
    else
      # Orphaned nodes have no launch parent left; ask each one to exit cleanly.
      pids=$(matching_pids)
      [ -z "$pids" ] || printf "%s\n" "$pids" | xargs -r kill -INT 2>/dev/null || true
    fi

    # Camera drivers can take several seconds to release USB devices.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      pids=$(matching_pids)
      [ -z "$pids" ] && break
      sleep 1
    done

    # Escalate only processes that survived graceful launch shutdown.
    pids=$(matching_pids)
    if [ -n "$pids" ]; then
      printf "%s\n" "$pids" | xargs -r kill -TERM 2>/dev/null || true
      sleep 2
    fi
    pids=$(matching_pids)
    [ -z "$pids" ] || printf "%s\n" "$pids" | xargs -r kill -KILL 2>/dev/null || true

    if [ -f /tmp/pika_lr_check/start_multi_sensor.pid ]; then
      rm -f /tmp/pika_lr_check/start_multi_sensor.pid
    fi
    pkill -f "/tmp/[p]ika_pose_motion_probe.py" 2>/dev/null || true
  ' >/dev/null 2>&1 || true
}
start_rqt_image_view(){
  docker exec "$CONTAINER_NAME" bash -c '
    mkdir -p /tmp/pika_lr_check
    source /opt/ros/humble/setup.bash 2>/dev/null
    setsid ros2 run rqt_image_view rqt_image_view \
      >/tmp/pika_lr_check/rqt_image_view.log 2>&1 </dev/null &
    echo $! >/tmp/pika_lr_check/rqt_image_view.pid
  ' >/dev/null 2>&1
}
stop_rqt_image_view(){
  docker exec "$CONTAINER_NAME" bash -c '
    rqt_pids(){
      ps -eo pid=,args= |
        awk -v self="$$" \
          "\$1 != self && \$0 ~ /rqt_image_view|rqt_gui/ &&
           \$0 !~ /awk -v self/ {print \$1}"
    }
    if [ -f /tmp/pika_lr_check/rqt_image_view.pid ]; then
      pid=$(cat /tmp/pika_lr_check/rqt_image_view.pid 2>/dev/null)
      [ -z "$pid" ] || kill -INT -- "-$pid" 2>/dev/null || true
      for _ in 1 2 3; do
        pids=$(rqt_pids)
        [ -z "$pids" ] && break
        sleep 1
      done
      pids=$(rqt_pids)
      if [ -n "$pids" ]; then
        [ -z "$pid" ] || kill -TERM -- "-$pid" 2>/dev/null || true
        printf "%s\n" "$pids" | xargs -r kill -TERM 2>/dev/null || true
        sleep 2
      fi
      pids=$(rqt_pids)
      if [ -n "$pids" ]; then
        [ -z "$pid" ] || kill -KILL -- "-$pid" 2>/dev/null || true
        printf "%s\n" "$pids" | xargs -r kill -KILL 2>/dev/null || true
      fi
      rm -f /tmp/pika_lr_check/rqt_image_view.pid
    else
      pids=$(rqt_pids)
      [ -z "$pids" ] || printf "%s\n" "$pids" | xargs -r kill -TERM 2>/dev/null || true
      sleep 1
      pids=$(rqt_pids)
      [ -z "$pids" ] || printf "%s\n" "$pids" | xargs -r kill -KILL 2>/dev/null || true
    fi
  ' >/dev/null 2>&1 || true
}
wait_for_lr_ready(){
  local timeout="${1:-60}" elapsed=0
  while [ "$elapsed" -lt "$timeout" ]; do
    if docker exec -e PIKA_DIR="$PIKA_DIR" "$CONTAINER_NAME" bash -c '
        source /opt/ros/humble/setup.bash 2>/dev/null
        source "$PIKA_DIR/pika_ros/install/setup.bash" 2>/dev/null
        pgrep -f "pika_double_locator_node" >/dev/null || exit 1
        topics=$(ros2 topic list 2>/dev/null)
        for topic in \
          /camera_fisheye_l/color/image_raw \
          /camera_fisheye_r/color/image_raw \
          /pika_pose_l \
          /pika_pose_r; do
          printf "%s\n" "$topics" | grep -qx "$topic" || exit 1
        done
        for topic in /pika_pose_l /pika_pose_r; do
          publishers=$(ros2 topic info "$topic" 2>/dev/null | sed -n "s/.*Publisher count: //p")
          [ "${publishers:-0}" -ge 1 ] || exit 1
        done
        grep -aq "acc err" /tmp/pika_lr_check/start_multi_sensor.log 2>/dev/null
      ' >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  return 1
}
sample_pose_motion(){
  local label="$1" duration="${2:-4}" output result rc
  [ -f "$POSE_PROBE" ] || { err "找不到 Pose 运动采样器：$POSE_PROBE"; return 1; }
  docker cp "$POSE_PROBE" "$CONTAINER_NAME:/tmp/pika_pose_motion_probe.py" >/dev/null ||
    { err "复制 Pose 运动采样器到容器失败"; return 1; }
  output=$(docker exec -e PIKA_DIR="$PIKA_DIR" "$CONTAINER_NAME" bash -c '
      source /opt/ros/humble/setup.bash 2>/dev/null
      source "$PIKA_DIR/pika_ros/install/setup.bash" 2>/dev/null
      python3 /tmp/pika_pose_motion_probe.py --duration "$1"
    ' bash "$duration" 2>&1)
  rc=$?
  printf '%s\n' "$output" | sed "s/^/  [$label] /"
  [ "$rc" -eq 0 ] || { err "$label Pose 采样失败（exit=$rc）"; return 1; }
  result=$(printf '%s\n' "$output" | sed -n 's/^RESULT //p' | tail -1)
  [ -n "$result" ] || { err "$label Pose 采样没有 RESULT"; return 1; }
  read -r RET_POSE_L_SCORE RET_POSE_R_SCORE RET_POSE_L_COUNT RET_POSE_R_COUNT <<<"$result"
}
classify_pose_mapping(){
  local base_l="$1" base_r="$2" left_l="$3" left_r="$4" right_l="$5" right_r="$6"
  awk -v bl="$base_l" -v br="$base_r" \
      -v ll="$left_l" -v lr="$left_r" -v rl="$right_l" -v rr="$right_r" '
    BEGIN {
      # Remove twice the observed stationary noise. A deliberate movement must
      # still exceed 3 cm-equivalent and dominate the opposite stream by 2x.
      left_l = ll - 2 * bl; if (left_l < 0) left_l = 0
      left_r = lr - 2 * br; if (left_r < 0) left_r = 0
      right_l = rl - 2 * bl; if (right_l < 0) right_l = 0
      right_r = rr - 2 * br; if (right_r < 0) right_r = 0
      min_score = 0.03
      ratio = 2.0
      printf "adjusted left-phase: L=%.4f R=%.4f; right-phase: L=%.4f R=%.4f\n",
             left_l, left_r, right_l, right_r > "/dev/stderr"
      correct = left_l >= min_score && left_l >= left_r * ratio &&
                right_r >= min_score && right_r >= right_l * ratio
      swapped = left_r >= min_score && left_r >= left_l * ratio &&
                right_l >= min_score && right_l >= right_r * ratio
      if (correct) print "correct"
      else if (swapped) print "swapped"
      else print "ambiguous"
    }'
}
diagnose_locator_after_zero_pose(){
  docker exec "$CONTAINER_NAME" bash -lc '
    export PS1=pika
    source /root/.bashrc 2>/dev/null
    if ! ros2 topic list 2>/dev/null | grep -q "^/pika_pose_"; then
      echo "NO_POSE_TOPIC"
    fi
    if ! pgrep -f "pika_double_locator_node" >/dev/null; then
      echo "LOCATOR_NOT_RUNNING"
    fi
    if grep -aq "mp_qrsolv: Assertion.*isfinite" /tmp/pika_lr_check/start_multi_sensor.log 2>/dev/null; then
      echo "MPFIT_ASSERT"
    fi
    if grep -aq "Adding tracked object" /tmp/pika_lr_check/start_multi_sensor.log 2>/dev/null; then
      echo "TRACKERS_SEEN"
    fi
    if grep -aq "LightcapMode .* -> 2" /tmp/pika_lr_check/start_multi_sensor.log 2>/dev/null; then
      echo "LIGHTCAP_OK"
    fi
  ' 2>/dev/null | sort -u
}
ask_yes_no(){
  local prompt="$1" ans
  read -rp "$prompt [y/N] " ans || ans=n
  case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

require_container(){
  [ -n "$(docker ps -q -f "name=^${CONTAINER_NAME}$")" ] && return 0
  warn "容器 $CONTAINER_NAME 没在运行。先：docker start $CONTAINER_NAME"
  return 1
}

# =============================================================================
# ① 静态规则/头相机依赖
# =============================================================================
stage_vive(){
  title "① 安装静态规则 / 验证 KFCv2 USB（81-vive + KFCv2）"
  [ -f "$VIVE_RULES" ] || { err "找不到 $VIVE_RULES"; return 1; }
  [ -f "$KFCV2_RULES" ] || { err "找不到 $KFCV2_RULES"; return 1; }
  command -v gst-launch-1.0 >/dev/null 2>&1 || { err "缺少 gst-launch-1.0，无法验证 MJPEG。"; return 1; }

  sudo install -m 0644 "$VIVE_RULES" /etc/udev/rules.d/81-vive.rules || { err "81-vive 安装失败"; return 1; }
  sudo install -m 0644 "$KFCV2_RULES" /etc/udev/rules.d/99-kfcv2-head.rules || { err "KFCv2 udev 规则安装失败"; return 1; }
  sudo udevadm control --reload-rules || { err "udev 规则重载失败"; return 1; }
  sudo udevadm trigger --subsystem-match=video4linux --action=add || { err "video4linux udev 触发失败"; return 1; }
  udevadm settle 2>/dev/null || true

  require_single_kfcv2_capture || return 1
  validate_kfcv2_symlink "$HEAD_CAMERA_DEVICE" || return 1
  require_kfcv2_not_busy "$HEAD_CAMERA_DEVICE" || return 1
  info "读取 3 帧 MJPEG：${HEAD_CAMERA_WIDTH}x${HEAD_CAMERA_HEIGHT}@${HEAD_CAMERA_FPS}"
  smoke_kfcv2_mjpeg "$HEAD_CAMERA_DEVICE" "$HEAD_CAMERA_WIDTH" "$HEAD_CAMERA_HEIGHT" "$HEAD_CAMERA_FPS" 3 || {
    err "KFCv2 MJPEG 验证失败：设备不支持目标规格、USB 带宽不足或 12 秒内没有帧。"
    return 1
  }

  export HEAD_CAMERA_DEVICE
  write_pika_hardware_env "$HARDWARE_ENV" "$PIKA_USER:$PIKA_USER" || {
    err "写入 $HARDWARE_ENV 失败"
    return 1
  }
  ok "$HEAD_CAMERA_DEVICE → $(readlink -f "$HEAD_CAMERA_DEVICE")，连续 3 帧验证通过"
  local usb_speed
  if usb_speed=$(kfcv2_usb_speed_mbps "$HEAD_CAMERA_DEVICE"); then
    if [ "$usb_speed" -ge 5000 ] 2>/dev/null; then
      ok "KFCv2 USB 链路：${usb_speed} Mbps（USB 3.x）"
    else
      warn "KFCv2 当前 USB 链路仅 ${usb_speed} Mbps（USB 2.0，带宽不足）；请切换到 USB 3.x 接口/控制器。"
    fi
  else
    warn "无法读取 KFCv2 USB 链路速度；请确认已连接 USB 3.x 接口，并避免与两只 D405 共用带宽不足的 hub。"
  fi
}

# =============================================================================
# ② 按手柄绑定（夹爪 USB + D405 序列号；无线 LHR 在本步骤写入）
# =============================================================================
# 引导插入一只手柄，回填全局 RET_TTY / RET_FISH（USB interface 路径）/ RET_SN（D405 序列号）/ RET_LHR（wired 大头）
detect_one_hand(){
  local label="$1"
  local b_tty b_fish b_sn b_lhr a_tty a_fish a_sn a_lhr n_tty n_fish n_sn n_lhr
  # 空白基线：两只都拔掉再快照。否则上一只拔掉后、这一只可能抢占它刚释放的同一个
  # /dev/videoN（设备号复用），按节点比的集合差会漏检鱼眼 → video 规则 KERNELS 写空。
  pause "请【拔掉所有手柄】（两只都拔干净），拔好后按回车建立空白基线..."
  udevadm settle 2>/dev/null; sleep 1
  b_tty="$(snap_tty)"; b_fish="$(snap_fish)"; b_sn="$(enum_d405)"; b_lhr="$(snap_wired_lhr)"
  pause "现在【只插入 $label 手柄】（整根 USB3 线），插好后按回车..."
  udevadm settle 2>/dev/null; sleep 4     # D405(USB3) / wired LHR 枚举较慢，给足时间
  a_tty="$(snap_tty)"; a_fish="$(snap_fish)"; a_sn="$(enum_d405)"; a_lhr="$(snap_wired_lhr)"
  n_tty="$(added "$b_tty" "$a_tty")"; n_fish="$(added "$b_fish" "$a_fish")"; n_sn="$(added "$b_sn" "$a_sn")"; n_lhr="$(added "$b_lhr" "$a_lhr")"

  [ -n "$n_tty" ] || { err "没检测到新增夹爪串口（ch341）。$label 手柄真插上了吗？"; return 1; }
  [ -n "$n_sn" ]  || { err "没检测到新增 D405（两台挤带宽可能只认一台 → 换到不同 USB3 控制器）"; return 1; }
  local cnt_tty; cnt_tty=$(printf '%s' "$n_tty" | grep -c .)
  [ "$cnt_tty" -gt 1 ] && warn "新增了多个串口——确保此刻只插了 $label 这一只手柄。"

  RET_TTY="$(iface_of "$(printf '%s\n' "$n_tty" | head -1)")"
  RET_FISH="$(iface_of "$(printf '%s\n' "$n_fish" | head -1)")"
  RET_SN="$(printf '%s\n' "$n_sn" | head -1)"
  RET_LHR="$(printf '%s\n' "$n_lhr" | head -1)"
  [ -n "$RET_TTY" ] || { err "$label 串口端口路径解析失败"; return 1; }
  [ -n "$RET_FISH" ] || warn "$label 鱼眼端口未解析到（可能未插鱼眼或厂商号异常）"
  ok "$label：串口 $RET_TTY  鱼眼 ${RET_FISH:-未识别}  D405 $RET_SN  wired-LHR ${RET_LHR:-未识别}"
}

stage_bind(){
  title "② 按手柄绑定（夹爪 USB + D405 序列号 + LHR）"
  require_container || return 1                      # D405 序列号要靠容器内 rs-enumerate
  echo "一只手柄一根 USB3 线 = D405(USB3)+鱼眼/串口(USB2)。wired 版本还会带出大头 LHR。"
  echo "一次插拔同时配好绑定+序列号，并保证 D405/鱼眼/夹爪左右一致；wired LHR 也随手柄确定左右。"
  echo "wireless LHR 会在两只手柄插回后统一探测，先写入暂定顺序，校准后再挥手核对。"
  echo "约定 50=左 / 51=右。TRACKER_MODE=$TRACKER_MODE"
  echo "流程：拔光→插左手→拔光→插右手→最后两只都插上验证。按提示来即可。"

  detect_one_hand "左手" || return 1
  local L_TTY="$RET_TTY" L_FISH="$RET_FISH" L_SN="$RET_SN" L_LHR="$RET_LHR"
  detect_one_hand "右手" || return 1
  local R_TTY="$RET_TTY" R_FISH="$RET_FISH" R_SN="$RET_SN" R_LHR="$RET_LHR"

  if [ "$L_TTY" = "$R_TTY" ]; then
    err "左右识别到同一端口（$L_TTY）——可能两次插的是同一只或没拔干净，请重来。"; return 1
  fi
  if [ "$L_SN" = "$R_SN" ]; then
    err "左右识别到同一 D405 序列号（$L_SN）——请重来。"; return 1
  fi
  if [ -z "$L_FISH" ] || [ -z "$R_FISH" ]; then
    err "鱼眼端口没解析全（左:${L_FISH:-空} 右:${R_FISH:-空}）——不写半截规则，请重跑本项。"; return 1
  fi
  if [ "$L_FISH" = "$R_FISH" ]; then
    err "左右识别到同一鱼眼端口（$L_FISH）——可能没拔干净/插的同一只，请重来。"; return 1
  fi

  local bind_tracker_mode="$TRACKER_MODE"
  if [ "$bind_tracker_mode" = "auto" ]; then
    if [ -n "$L_LHR" ] && [ -n "$R_LHR" ]; then
      bind_tracker_mode="wired"
    elif [ -z "$L_LHR" ] && [ -z "$R_LHR" ]; then
      bind_tracker_mode="wireless"
    else
      err "auto 模式只识别到单侧 wired LHR（左:${L_LHR:-无} 右:${R_LHR:-无}）。"
      err "若要 wired 模式，请检查未识别侧的大头短 USB 线/主体接口；若要 wireless 模式，请拔掉 wired 短线或设置 TRACKER_MODE=wireless。"
      return 1
    fi
  fi
  case "$bind_tracker_mode" in
    wired)
      [ -n "$L_LHR" ] && [ -n "$R_LHR" ] || { err "TRACKER_MODE=wired 要求左右都识别到 wired LHR（左:${L_LHR:-无} 右:${R_LHR:-无}）。"; return 1; }
      [ "$L_LHR" != "$R_LHR" ] || { err "左右识别到同一 LHR（$L_LHR）——可能没拔干净/插的是同一只，请重来。"; return 1; }
      ok "定位连接模式判定：wired（左 $L_LHR / 右 $R_LHR）"
      ;;
    wireless)
      ok "定位连接模式判定：wireless（② 将通过 dongle 探测 LHR 并写入硬件配置）"
      ;;
    *)
      err "非法 TRACKER_MODE=$TRACKER_MODE，只允许 auto/wired/wireless"; return 1 ;;
  esac

  info "① 写夹爪 udev 规则 → $BIND_RULES"
  cat > "$BIND_RULES" <<EOF
# Pika 双夹爪 USB 绑定 —— setup_hardware.sh 自动生成
# 约定：50=左手, 51=右手。一只夹爪的鱼眼(.1)与串口(.4)共用同一 hub。
# 串口（夹爪角度编码器 ch341）
ACTION=="add", KERNELS=="$L_TTY", SUBSYSTEMS=="usb", MODE:="0777", SYMLINK+="ttyUSB50"
ACTION=="add", KERNELS=="$R_TTY", SUBSYSTEMS=="usb", MODE:="0777", SYMLINK+="ttyUSB51"
# 鱼眼相机（取偶数 video 捕获节点）
ACTION=="add", KERNEL=="$VIDEO_EVEN", KERNELS=="$L_FISH", SUBSYSTEMS=="usb", MODE:="0777", SYMLINK+="video50"
ACTION=="add", KERNEL=="$VIDEO_EVEN", KERNELS=="$R_FISH", SUBSYSTEMS=="usb", MODE:="0777", SYMLINK+="video51"
EOF

  sudo cp "$BIND_RULES" /etc/udev/rules.d/ && \
  sudo udevadm control --reload-rules || { err "udev 安装/重载失败"; return 1; }

  # 检测是一只一只插的，验证 4 个软链需要两只都在 → 先让用户把两只都插上再验
  pause "规则已装。现在【把两只手柄都插上】（各自插回刚检测的同一个 USB3 口），插好后按回车验证..."
  sudo udevadm trigger --action=add 2>/dev/null
  udevadm settle 2>/dev/null; sleep 2

  echo "验证符号链接："
  local missing=0 s
  for s in ttyUSB50 ttyUSB51 video50 video51; do
    if [ -e "/dev/$s" ]; then ok "/dev/$s → $(iface_of /dev/$s)"; else err "/dev/$s 缺失"; missing=1; fi
  done
  [ "$missing" -eq 0 ] && ok "夹爪四个软链全部生成" || warn "有缺失：检查对应手柄是否插好、端口是否变化"

  if [ "$bind_tracker_mode" = "wired" ]; then
    PIKA_L_CODE="$L_LHR"
    PIKA_R_CODE="$R_LHR"
    ok "wired LHR：左 $L_LHR / 右 $R_LHR"
  else
    info "探测 wireless LHR"
    configure_wireless_lhr_codes || return 1
  fi

  L_DEPTH_CAMERA_NO="$L_SN"
  R_DEPTH_CAMERA_NO="$R_SN"
  HEAD_CAMERA_DEVICE="${HEAD_CAMERA_DEVICE:-/dev/kfcv2-camera}"
  export L_DEPTH_CAMERA_NO R_DEPTH_CAMERA_NO PIKA_L_CODE PIKA_R_CODE HEAD_CAMERA_DEVICE
  write_pika_hardware_env "$HARDWARE_ENV" "$PIKA_USER:$PIKA_USER" || {
    err "硬件配置写入失败：$HARDWARE_ENV"
    return 1
  }
  ok "硬件配置已原子写入：D405 左 $L_SN / 右 $R_SN；LHR 左 $PIKA_L_CODE / 右 $PIKA_R_CODE"

  echo
  warn "下一步先跑③基站校准；校准成功后再跑④左右手核对。"
  warn "若鱼眼反了：重跑②，插的时候左右对调；若只有 LHR 反了：④ 可一键对调。"
}

# =============================================================================
# ④ 左右手核对（鱼眼图像定物理左右 → pose 同步性纠 LHR；反了一键对调）
# -----------------------------------------------------------------------------
# 经验：鱼眼图像是 ground truth（rqt_image_view 挥手看哪路画面动），比 rviz 看坐标系
#       动可靠。定位左右通过同步采样两路 PoseStamped 的实际运动量判断，不再使用 topic hz。
# =============================================================================
LR_STACK_OWNED=0
LR_RQT_OWNED=0
stage_lr_cleanup(){
  local rc=$?
  trap - EXIT INT TERM
  if [ "${LR_RQT_OWNED:-0}" -eq 1 ]; then
    info "清理④启动的 rqt_image_view..."
    stop_rqt_image_view
    LR_RQT_OWNED=0
  fi
  if [ "${LR_STACK_OWNED:-0}" -eq 1 ]; then
    info "清理④启动的设备栈..."
    stop_sensor_stack
    LR_STACK_OWNED=0
  fi
  docker exec "$CONTAINER_NAME" pkill -f "/tmp/[p]ika_pose_motion_probe.py" >/dev/null 2>&1 || true
  [ "$rc" -eq 0 ] || warn "④ 已中止（exit=$rc）；本步骤启动的节点已自动清理。"
  return "$rc"
}
start_lr_owned_stack(){
  info "正在容器内启动干净的 start_multi_sensor.bash..."
  LR_STACK_OWNED=1
  start_sensor_stack || { err "设备栈启动失败"; return 1; }
  if wait_for_lr_ready 60; then
    ok "左右鱼眼、定位节点和两路 Pose 均已就绪，日志已出现 acc err。"
    return 0
  fi
  err "等待定位链路就绪超时；不会进入左右判断。"
  local diag; diag=$(diagnose_locator_after_zero_pose)
  [ -n "$diag" ] && printf '%s\n' "$diag" | sed 's/^/  diagnose: /'
  warn "日志：docker exec $CONTAINER_NAME tail -120 /tmp/pika_lr_check/start_multi_sensor.log"
  return 1
}
stop_lr_owned_stack(){
  [ "${LR_STACK_OWNED:-0}" -eq 1 ] || return 0
  stop_sensor_stack
  LR_STACK_OWNED=0
}
run_pose_mapping_test(){
  local base_l base_r left_l left_r right_l right_r

  pause "Pose 基线：请把【两只手都放稳不动】，准备好后按回车；随后保持静止 3 秒..."
  sample_pose_motion "静止基线" 3 || return 1
  base_l="$RET_POSE_L_SCORE"; base_r="$RET_POSE_R_SCORE"

  pause "左手测试：请保持【右手完全不动】，按回车后连续、大幅移动或旋转【左手】5 秒..."
  sample_pose_motion "只动左手" 5 || return 1
  left_l="$RET_POSE_L_SCORE"; left_r="$RET_POSE_R_SCORE"

  pause "右手测试：请保持【左手完全不动】，按回车后连续、大幅移动或旋转【右手】5 秒..."
  sample_pose_motion "只动右手" 5 || return 1
  right_l="$RET_POSE_L_SCORE"; right_r="$RET_POSE_R_SCORE"

  RET_POSE_MAPPING=$(classify_pose_mapping \
    "$base_l" "$base_r" "$left_l" "$left_r" "$right_l" "$right_r")
  case "$RET_POSE_MAPPING" in
    correct)
      ok "Pose 运动对应关系：左手→/pika_pose_l，右手→/pika_pose_r。"
      ;;
    swapped)
      warn "Pose 运动对应关系反向：左手→/pika_pose_r，右手→/pika_pose_l。"
      ;;
    *)
      err "Pose 结果不明确：运动量不足、两手同时移动，或定位噪声/跳变过大。"
      err "没有修改 LHR；请保持非测试手静止并重跑④。"
      return 1
      ;;
  esac
}
stage_lr_impl(){
  title "④ 左右手核对（鱼眼定物理左右 → pose 同步性纠 LHR）"
  require_container || return 1

  local cur_L cur_R
  cur_L="${PIKA_L_CODE:-}"
  cur_R="${PIKA_R_CODE:-}"
  info "当前硬件配置 LHR：L=${cur_L:-未设}  R=${cur_R:-未设}"
  [ -n "$cur_L" ] && [ -n "$cur_R" ] ||
    { err "$HARDWARE_ENV 没有完整的 PIKA_L_CODE/PIKA_R_CODE，请先完成②。"; return 1; }
  [ "$cur_L" != "$cur_R" ] ||
    { err "左右 LHR 相同（$cur_L），配置无效，请重跑②。"; return 1; }

  local tracker_mode; tracker_mode=$(detect_tracker_mode)
  print_tracker_mode_status "$tracker_mode"

  if [ "$tracker_mode" = "wired" ]; then
    warn "wired 模式下 LHR 应在②单手插拔绑定时写入；④只做运行复核与必要对调。"
  else
    ok "wireless LHR 已由②写入；④只做运行复核与必要对调。"
  fi

  cat <<EOF

本步骤会自动启动设备栈并引导复核。请确保两只手柄、大头、基站都已接好/开机。
本步骤依赖③已经完成基站校准；未校准时定位节点可能无法启动。
本步骤退出时（包括 Ctrl+C / 报错）会自动关闭自己启动的设备栈、采样器和 rqt。
EOF

  if sensor_stack_present || sensor_topics_present; then
    warn_existing_sensor_topics
    info "④ 不复用旧设备栈，正在清理容器内残留节点..."
    stop_sensor_stack
    stop_rqt_image_view
    local gone=0 i
    for i in 1 2 3 4 5 6 7 8 9 10; do
      if ! sensor_stack_present && ! sensor_topics_present; then gone=1; break; fi
      sleep 1
    done
    [ "$gone" -eq 1 ] || {
      err "清理本容器后仍能看到鱼眼 topic，可能来自局域网内另一套 PIKA。"
      err "请更换 ROS_DOMAIN_ID 后重建容器，不能在混合 topic 环境中核对左右。"
      return 1
    }
  fi

  start_lr_owned_stack || return 1

  cat <<EOF

复核 1/2：鱼眼左右
  请观察画面并挥【左手】夹爪：
    /camera_fisheye_l/color/image_raw 应该动；
    如果 /camera_fisheye_r 在动，说明②里左右插反了，应回②重绑。
EOF

  if ask_yes_no "是否自动打开 rqt_image_view 图像窗口？"; then
    LR_RQT_OWNED=1
    start_rqt_image_view && { ok "已尝试打开 rqt_image_view。窗口中依次查看 /camera_fisheye_l/color/image_raw 和 /camera_fisheye_r/color/image_raw。"; } \
      || warn "rqt_image_view 启动失败。可查看：docker exec $CONTAINER_NAME tail -80 /tmp/pika_lr_check/rqt_image_view.log"
  fi

  if ask_yes_no "挥左手时，/camera_fisheye_l 是否在动？"; then
    ok "鱼眼左右通过。"
  else
    err "鱼眼左右未通过，物理左右基准不可信。请回②重跑绑定。"
    return 1
  fi

  cat <<EOF

复核 2/2：定位左右
  脚本会同时采样 /pika_pose_l 和 /pika_pose_r 的实际平移/旋转变化。
  将依次测量：两手静止基线 → 只动左手 → 只动右手。
EOF
  run_pose_mapping_test || return 1
  if [ "$RET_POSE_MAPPING" = "correct" ]; then
    ok "左右手核对通过，无需修改 LHR。"
    return 0
  fi

  ask_yes_no "检测结果明确反向，是否对调左右 LHR 并自动复测？" ||
    { err "未执行对调，左右配置仍是反的。"; return 1; }
  PIKA_L_CODE="$cur_R"
  PIKA_R_CODE="$cur_L"
  export PIKA_L_CODE PIKA_R_CODE
  write_pika_hardware_env "$HARDWARE_ENV" "$PIKA_USER:$PIKA_USER" ||
    { err "LHR 对调写入失败"; return 1; }
  cur_L="$PIKA_L_CODE"
  cur_R="$PIKA_R_CODE"
  ok "已对调硬件配置：左 $cur_L / 右 $cur_R"

  info "停止旧定位节点，并用对调后的 LHR 重新启动..."
  stop_lr_owned_stack
  start_lr_owned_stack || return 1
  warn "开始对调后的复测；请再次按提示保持非测试手静止。"
  run_pose_mapping_test || return 1
  [ "$RET_POSE_MAPPING" = "correct" ] ||
    { err "对调后复测仍未通过；保留当前配置，请检查动作、定位跳变和 LHR 设备对应关系。"; return 1; }
  ok "LHR 对调后的左右手复测通过。"
}
stage_lr(){
  (
    LR_STACK_OWNED=0
    LR_RQT_OWNED=0
    trap stage_lr_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    stage_lr_impl
  )
}

# =============================================================================
# ③ 基站校准引导（survive-cli，交互式）
# =============================================================================
stage_calib(){
  title "③ 基站校准引导（survive-cli，交互式）"
  require_container || return 1
  local tracker_mode; tracker_mode=$(detect_tracker_mode)
  cat <<EOF
校准前确认（最容易漏的坑放第一条）：
  1) 长按【定位标签】（夹爪顶部那个大头，不是夹爪本身）到【绿灯常亮】
     —— 没开 → 定位链路收不到数据 → 卡在 clearing position。
  2) 两台基站【不同频道】（如 10 / 11），撕膜、对角架高 ~2m、俯视、无遮挡无阳光无反光面。
  3) 校准时 Sense 保持【完全静止】。

执行（在容器内）：
  docker exec -it $CONTAINER_NAME bash
  export LD_LIBRARY_PATH=$PIKA_DIR/pika_ros/install/libsurvive/lib:\$LD_LIBRARY_PATH
  cd $PIKA_DIR/pika_ros/install/libsurvive/bin
  ./survive-cli --force-calibrate         # 基站动过/坐标在飘用这个；没动过用 ./survive-cli 确认不漂即可

合格判据：
  · 出现两行 "Got OOTX packet <频道> <基站ID>"，两台频道不同；
  · 每台 acc err < 0.005；达标后 Ctrl+C 结束（自动写入 libsurvive_config 持久化）。
  · 校准后启动设备栈，在 RViz 中移动左右夹爪，确认定位轨迹丝滑连续、不跳变不卡顿。
  · 校准完到采集结束【别再碰基站】。
EOF
  echo
  print_tracker_mode_status "$tracker_mode"
  if [ "$tracker_mode" = "wired" ]; then
    local wired_count; wired_count=$(detect_wired_lhr_codes | grep -c . || true)
    if [ "$wired_count" -lt 2 ]; then
      warn "wired 模式当前只检测到 ${wired_count} 个 LHR；双手定位通常需要 2 个。少一个时先查短 USB 线/大头/主体接口。"
    fi
    warn "wired LHR 出现在 USB 上 = 主机已枚举到定位标签；是否能解算还要看 survive 输出。"
  else
    warn "wireless dongle 在 = 接收器就绪；大头是否真连上要看 survive 输出。"
  fi
  warn "survive 输出重点：Preamble found(基站) / LightcapMode→2(大头收光) / 有解算 acc err。"

  echo
  # 定位设备互斥：survive-cli 不能和 start_multi_sensor 同跑（都抢 libsurvive 设备）
  if docker exec "$CONTAINER_NAME" bash -c 'export PS1=pika; source /root/.bashrc 2>/dev/null; ros2 topic list 2>/dev/null | grep -q camera_fisheye'; then
    warn_existing_sensor_topics
    warn "校准前请先处理上述情况，否则可能出现 LIBUSB_BUSY 或校准到错误的 ROS 环境。"
  fi
  local a; read -rp "现在直接开始校准(survive-cli --force-calibrate)吗？[y/N] " a || a=n
  case "$a" in
    y|Y)
      info "启动 survive-cli —— 看到每台 acc err < 0.005 后按 Ctrl+C 结束（自动持久化到 libsurvive_config）"
      docker exec -it -e PIKA_DIR="$PIKA_DIR" "$CONTAINER_NAME" bash -c '
        source /opt/ros/humble/setup.bash 2>/dev/null
        export LD_LIBRARY_PATH="$PIKA_DIR/pika_ros/install/libsurvive/lib:$LD_LIBRARY_PATH"
        cd "$PIKA_DIR/pika_ros/install/libsurvive/bin" && ./survive-cli --force-calibrate'
      echo; ok "已退出 survive-cli。若达标，校准已写入 libsurvive_config/config.json。"
      ;;
    *) info "好，需要时手动跑上面那条命令即可。" ;;
  esac
}

# =============================================================================
# 菜单
# =============================================================================
menu(){
  cat <<EOF

$(echo -e "${c_b}========= Pika 硬件配置（引导式）=========${c_0}")
  1) 装基站/KFCv2 USB udev 规则并验证头相机
  2) 按手柄绑定（夹爪 USB + D405 序列号 + LHR）
  3) 基站校准引导
  4) 左右手核对（鱼眼定左右 → pose 同步性纠 LHR）
  5) 依次跑 1→2→3→4（先校准，再核对）
  0) 退出
EOF
  read -rp "选择: " choice || { echo; exit 0; }
  case "$choice" in
    1) stage_vive ;;
    2) stage_bind ;;
    3) stage_calib ;;
    4) stage_lr ;;
    5) stage_vive && stage_bind && stage_calib && stage_lr ;;
    0) exit 0 ;;
    *) warn "无效选择" ;;
  esac
}

if [ "${SETUP_HARDWARE_LIB_ONLY:-false}" = "true" ]; then
  return 0 2>/dev/null || exit 0
fi

[ -d "$PIKA_DIR" ] || { err "找不到项目目录 $PIKA_DIR —— 先跑 migrate_software.sh"; exit 1; }
echo -e "${c_b}Pika 硬件轨配置${c_0}　项目：$PIKA_DIR　容器：$CONTAINER_NAME"
warn "udev 相关操作需要 sudo；插拔设备时一次只插一只/一台，按提示来。"
while true; do menu; done
