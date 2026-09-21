#!/bin/bash
# =============================================================================
# start_collect.sh —— Pika 日常采集「一条龙」(在【宿主机】跑)
# -----------------------------------------------------------------------------
# 一条命令从开机到进采集循环，退出自动清理。把这些样板合成一步：
#   ① 起容器 + xhost   ② 校准自动判定(漂不漂，没挪基站就跳过)
#   ③ 后台起设备栈      ④ 健康自检(软链 + pose 在发，代替每天挥手核对)
#   ⑤ run_pika 采集循环(只管双击夹爪)；trap 退出时自动停设备栈、放 dongle
#
# 用法：
#   bash start_collect.sh         # 一条龙：起设备 → 进采集循环
#   bash start_collect.sh stop    # 只停掉后台设备栈(极少用)
#
# 说明：设备栈后台跑、日志在容器 /tmp/multi_sensor.log；实时帧率看 run_pika 弹的 xterm。
#       左右核对不在这里(那是换设备/重插后的一次性事，走 setup_hardware.sh ③)。
# =============================================================================
set -uo pipefail

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
PIKA_ROOT=$(readlink -f "$SCRIPT_DIR/../..")
RUNTIME_ENV="${PIKA_RUNTIME_ENV:-$PIKA_ROOT/pika_runtime.env}"
[ -f "$RUNTIME_ENV" ] || { echo "缺少 $RUNTIME_ENV；先运行 migrate_software.sh。" >&2; exit 1; }
source "$RUNTIME_ENV"
HARDWARE_ENV="${PIKA_HARDWARE_ENV:-$PIKA_ROOT/pika_hardware.env}"
[ -f "$HARDWARE_ENV" ] || { echo "缺少 $HARDWARE_ENV；先运行 setup_hardware.sh。" >&2; exit 1; }
source "$HARDWARE_ENV"

CONTAINER="${CONTAINER_NAME:-pika}"
PIKA_DIR="${PIKA_DIR:-$PIKA_ROOT}"
APP_DIR="${APP_DIR:-$(dirname "$PIKA_DIR")}"
PIKA_MIGRATE_DIR="${PIKA_MIGRATE_DIR:-$APP_DIR/pika-migrate}"
[ -f "$PIKA_MIGRATE_DIR/lib/kfcv2_usb.sh" ] || { echo "缺少 KFCv2 USB 检测库；请重新运行 migrate_software.sh。" >&2; exit 1; }
source "$PIKA_MIGRATE_DIR/lib/kfcv2_usb.sh"
SCRIPTS="$PIKA_DIR/pika_ros/scripts"
LIBSURVIVE="$PIKA_DIR/pika_ros/install/libsurvive"
SENSOR_LOG="/tmp/multi_sensor.log"           # 容器内设备栈日志
DATA_ROOT="${DATA_DIR:-/home/kw/agilex/data}" # 宿主机数据总根。按任务分子目录:DATA_ROOT/<任务>/episodeN
SCREEN_PY="${SCREEN_PY:-$PIKA_MIGRATE_DIR/screen_episodes.py}" # 采集后自动质检脚本(可覆盖)
BUNDLED_SCREEN_PY="$SCRIPTS/screen_episodes.py"                # 项目内置兜底版本
TASK=""                                       # 本次采集的任务名(choose_task 设)
TASK_DATA_DIR=""                              # = DATA_ROOT/$TASK,本次数据落盘目录(choose_task 设)
HEAD_CAMERA_DRIVER="${HEAD_CAMERA_DRIVER:-kfcv2}"
HEAD_CAMERA_DEVICE="${HEAD_CAMERA_DEVICE:-/dev/kfcv2-camera}"
HEAD_CAMERA_WIDTH="${HEAD_CAMERA_WIDTH:-3840}"
HEAD_CAMERA_HEIGHT="${HEAD_CAMERA_HEIGHT:-1080}"
HEAD_CAMERA_FPS="${HEAD_CAMERA_FPS:-30}"
HEAD_CAMERA_MIN_FPS="${HEAD_CAMERA_MIN_FPS:-25}"
CAPTURE_HZ="${CAPTURE_HZ:-}"
CALIB_ACC_ERR_MAX="${CALIB_ACC_ERR_MAX:-0.005}"

c_g='\033[32m'; c_r='\033[31m'; c_y='\033[33m'; c_b='\033[36m'; c_0='\033[0m'
info(){ echo -e "${c_b}▸${c_0} $*"; }
ok(){   echo -e "${c_g}✅ $*${c_0}"; }
warn(){ echo -e "${c_y}⚠️  $*${c_0}"; }
err(){  echo -e "${c_r}❌ $*${c_0}" >&2; }

# ros2 launch 起的子节点(占着 dongle/相机)：locator 才是 dongle 持有者，必须一并清，
# 否则只杀 launch 外壳会留下孤儿 → 下次 LIBUSB_BUSY 抢不到 dongle。
CHILD_PATTERN='open_multi_sensor|pika_double_locator|realsense2_camera|usb_camera|kfcv2_usb_publisher.py|rviz2|serial_gripper_imu'

# ---- 容器内是否已有设备栈在跑(看 launch 外壳或 locator 都算) ----
stack_running(){ [ -n "$(docker exec "$CONTAINER" pgrep -f 'open_multi_sensor|pika_double_locator' 2>/dev/null)" ]; }

# ---- 停设备栈(谁起谁收；stop 子命令、trap、启动前清孤儿都用它) ----
stop_stack(){
  # 先给 ros2 launch SIGINT：它会优雅关掉自己启动的全部子节点
  docker exec "$CONTAINER" pkill -INT -f open_multi_sensor 2>/dev/null
  sleep 3
  # 兜底：launch 没接住 / 子节点已成孤儿时，按节点名强杀
  docker exec "$CONTAINER" pkill -9 -f "$CHILD_PATTERN" 2>/dev/null
  sleep 1
}

# ---- 起设备栈 ----
# start_multi_sensor.bash 会从 pika_hardware.env 读取 D405 和 LHR 左右绑定。
start_stack(){
  docker exec -d \
    -e PIKA_RUNTIME_ENV="$PIKA_DIR/pika_runtime.env" \
    -e PIKA_HARDWARE_ENV="$PIKA_DIR/pika_hardware.env" \
    -e HEAD_CAMERA_DRIVER="$HEAD_CAMERA_DRIVER" \
    -e HEAD_CAMERA_DEVICE="$HEAD_CAMERA_DEVICE" \
    -e HEAD_CAMERA_WIDTH="$HEAD_CAMERA_WIDTH" \
    -e HEAD_CAMERA_HEIGHT="$HEAD_CAMERA_HEIGHT" \
    -e HEAD_CAMERA_FPS="$HEAD_CAMERA_FPS" \
    -e CAPTURE_HZ="$CAPTURE_HZ" \
    "$CONTAINER" \
    bash -c "cd '$SCRIPTS' && bash start_multi_sensor.bash > '$SENSOR_LOG' 2>&1"
}

kfcv2_topic_health(){
  local output rc publishers rate
  output=$(docker exec \
    -e PIKA_DIR="$PIKA_DIR" \
    -e HEAD_CAMERA_MIN_FPS="$HEAD_CAMERA_MIN_FPS" \
    "$CONTAINER" bash -c '
      source /opt/ros/humble/setup.bash 2>/dev/null
      source "$PIKA_DIR/pika_ros/install/setup.bash" 2>/dev/null
      topic=/camera/kfc_compressed
      publishers=$(ros2 topic info "$topic" 2>/dev/null | sed -n "s/.*Publisher count: //p")
      echo "publishers=${publishers:-0}"
      [ "$publishers" = 1 ] || exit 21
      timeout 12 ros2 topic echo --once "$topic" sensor_msgs/msg/CompressedImage >/dev/null || exit 22
      rate_output=$(timeout 8 stdbuf -oL ros2 topic hz --window 30 "$topic" 2>&1 || true)
      rate=$(printf "%s\n" "$rate_output" | sed -n "s/.*average rate: \([0-9.]*\).*/\1/p" | tail -1)
      echo "rate=${rate:-missing} minimum=$HEAD_CAMERA_MIN_FPS"
      awk -v actual="$rate" -v minimum="$HEAD_CAMERA_MIN_FPS" \
        "BEGIN { exit !(actual != \"\" && actual + 0 >= minimum + 0) }" || exit 23
    ' 2>&1)
  rc=$?
  publishers=$(printf '%s\n' "$output" | sed -n 's/^publishers=//p' | tail -1)
  rate=$(printf '%s\n' "$output" | sed -n 's/^rate=\([^ ]*\).*/\1/p' | tail -1)
  case "$rc" in
    0)
      ok "KFCv2 ROS 健康检查通过：publisher=${publishers:-1}，rate=${rate} FPS"
      ;;
    21)
      err "KFCv2 publisher 数量必须为 1，实际 ${publishers:-0}；检查重复设备栈和 ROS_DOMAIN_ID。"
      return 1
      ;;
    22)
      err "KFCv2 publisher 已注册，但 12 秒内没有收到真实 JPEG 消息。"
      return 1
      ;;
    23)
      err "KFCv2 帧率不足：实际 ${rate:-未测得} FPS，最低要求 $HEAD_CAMERA_MIN_FPS FPS。"
      return 1
      ;;
    *)
      err "KFCv2 ROS 健康检查执行失败（exit=$rc）：$output"
      return 1
      ;;
  esac
}

# ---- 健康自检:软链 + 定位【真解算】(读日志等 acc err) + pose/相机 topic;首启与掉线重启都调用 ----
# 只查"有没有解算/发布者",不查 pose 数据流(静止不更新+QoS 特殊,echo/hz 会误报)。
health_check(){
  info "等设备栈起来并自检…"
  sleep 8
  info "等定位解算(读设备栈日志找 acc err，最多 ~20s)…"
  local solved="" i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    docker exec "$CONTAINER" grep -q 'acc err' "$SENSOR_LOG" 2>/dev/null && { solved=1; break; }
    sleep 2
  done
  local problems
  problems=$(docker exec "$CONTAINER" bash -c '
    source /opt/ros/humble/setup.bash 2>/dev/null
    source '"$PIKA_DIR"'/pika_ros/install/setup.bash 2>/dev/null
    for n in ttyUSB50 ttyUSB51 video50 video51; do [ -e /dev/$n ] || echo "缺软链 /dev/$n"; done
    tl=$(ros2 topic list 2>/dev/null)
    for t in /pika_pose_l /pika_pose_r; do
      printf "%s\n" "$tl" | grep -qx "$t" || { echo "缺 topic $t"; continue; }
      pc=$(ros2 topic info "$t" 2>/dev/null | sed -n "s/.*Publisher count: //p")
      [ "${pc:-0}" -ge 1 ] || echo "$t 没有发布者(定位节点没起来?)"
    done
    cam=$(printf "%s\n" "$tl" | grep -cE "camera|fisheye")
    [ "${cam:-0}" -ge 4 ] || echo "相机 topic 偏少(${cam:-0})—确认两台 D405/鱼眼都起来了"
  ')
  [ -z "$solved" ] && problems="${problems}${problems:+$'\n'}定位还没解算出来(日志无 acc err)——大头是否被追踪/基站视野遮挡? 此时采集会得到 pose=0 残缺"
  if [ -n "$problems" ]; then
    warn "健康自检发现问题："
    printf '%s\n' "$problems" | sed 's/^/    • /'
    warn "排查：docker exec $CONTAINER tail $SENSOR_LOG；软链缺→setup_hardware.sh ②；定位不解算→大头绿灯/基站视野,或 setup_hardware.sh ④ 重标。"
    local go; read -rp "仍要继续进采集吗？[y/N] " go || go=n
    case "$go" in y|Y) return 0 ;; *) exit 1 ;; esac
  fi
  case "$HEAD_CAMERA_DRIVER" in
    kfcv2)
      kfcv2_topic_health || return 1
      ;;
    none)
      info "HEAD_CAMERA_DRIVER=none，跳过头相机检查。"
      ;;
    *)
      err "不支持 HEAD_CAMERA_DRIVER=$HEAD_CAMERA_DRIVER，只允许 kfcv2 或 none。"
      return 1
      ;;
  esac
  ok "健康自检通过：四软链在位、定位已解算(acc err)、pose/相机 topic 就位。"
  warn "开始采集前请在 RViz 里移动左右夹爪，确认左右定位都能丝滑连续移动；若跳变/卡顿/不动，请先重标或检查基站视野。"
}

# ---- stop 子命令 ----
if [ "${1:-}" = "stop" ]; then
  if stack_running; then stop_stack; ok "设备栈已停，dongle 释放。"; else info "设备栈本来就没在跑。"; fi
  exit 0
fi

# ---- 选/建任务：按任务类型分目录存数据，避免不同任务/配置的 episode 混在一起 ----
# 数据落到 DATA_ROOT/<任务>/episodeN，每任务独立编号(各自从 episode0 起)、独立统计与质检。
# 任务名限 英文/数字/_/- ：路径要经 ros2 launch datasetDir:= 传进容器给 C++ dataCapture，
# 中文/空格有编码与解析风险；优先从已有任务里选，避免同义异名把一个任务拆成多个目录。
choose_task(){
  local dirs=() d i reply name
  while IFS= read -r d; do dirs+=("$d"); done \
    < <(find "$DATA_ROOT" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '%f\n' 2>/dev/null | sort)
  echo; info "选择本次采集任务（数据存到 $DATA_ROOT/<任务>/）："
  if [ "${#dirs[@]}" -gt 0 ]; then
    for i in "${!dirs[@]}"; do printf "   %2d) %s\n" "$((i+1))" "${dirs[$i]}"; done
  else
    echo "   (暂无已有任务)"
  fi
  echo "    n) 新建任务"
  while :; do
    read -rp "$(echo -e "${c_y}选编号复用 / n 新建: ${c_0}")" reply || { echo; err "输入流结束，取消采集。"; exit 1; }
    if [ "$reply" = n ] || [ "$reply" = N ]; then
      while :; do   # 就地重问名字直到合法,非法不退回主菜单
        read -rp "新任务名(英文/数字/_/-，如 fold_clothes): " name || { echo; err "输入流结束，取消采集。"; exit 1; }
        [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] && { TASK="$name"; break 2; }
        warn "非法任务名，只允许 英文/数字/下划线/连字符。"
      done
    elif [[ "$reply" =~ ^[0-9]+$ ]] && [ "$reply" -ge 1 ] && [ "$reply" -le "${#dirs[@]}" ]; then
      TASK="${dirs[$((reply-1))]}"; break
    else
      warn "无效输入。"
    fi
  done
  TASK_DATA_DIR="$DATA_ROOT/$TASK"
  mkdir -p "$TASK_DATA_DIR"   # 宿主机以 dex 身份建,保证任务目录属主正确(留给容器内 root 建会上锁)
  ok "本次任务：$TASK  → $TASK_DATA_DIR"
}

# ---- 采集后自动质检：跑 screen_episodes.py(在宿主机以 dex 身份读 root 数据，目录 755 可列名) ----
# 五维筛查(死流/中段间隙/头截断/尾截断/时长)，检查 pose + 图像时间戳覆盖，输出 报废/存疑/轻微/干净 清单。
# 容错：脚本/解释器缺失只告警不致命，绝不因质检失败影响收尾放 dongle。
run_screening(){
  [ -n "$TASK_DATA_DIR" ] || return 0     # 还没选任务(早退/中断)就没数据可检
  local screen_py="$SCREEN_PY"
  [ -f "$screen_py" ] || screen_py="$BUNDLED_SCREEN_PY"
  [ -f "$screen_py" ] || { warn "找不到质检脚本 $SCREEN_PY 或 $BUNDLED_SCREEN_PY，跳过。"; return 0; }
  command -v python3 >/dev/null 2>&1 || { warn "无 python3，跳过数据质检。"; return 0; }
  echo; info "本轮采集质检（screen_episodes.py，扫描 $TASK_DATA_DIR）…"
  python3 "$screen_py" "$TASK_DATA_DIR" || warn "质检脚本返回非 0，请人工复核。"
}

# ---- 退出时自动清理(q 退出 / Ctrl+C 都触发) ----
# 先停设备栈放 dongle，再跑质检：设备先释放，质检慢点也不占着硬件。
cleanup(){ echo; info "收尾：停设备栈、放 dongle …"; stop_stack; ok "已清理。下次 bash start_collect.sh 再来。"; run_screening; }

# =============================================================================
# ① 容器 + X11
# =============================================================================
[ -n "$(docker ps -q -f "name=^${CONTAINER}$")" ] || {
  info "容器没在跑，docker start $CONTAINER …"
  docker start "$CONTAINER" >/dev/null || { err "起容器失败"; exit 1; }
  sleep 2
}
xhost +local:root >/dev/null 2>&1 || warn "xhost 失败(GUI 可能弹不出来，非致命)"

# 硬件配置是 D405/LHR 左右绑定的唯一持久来源。
LCODE="${PIKA_L_CODE:-}"
RCODE="${PIKA_R_CODE:-}"
[ -n "$LCODE" ] && [ -n "$RCODE" ] || {
  err "$HARDWARE_ENV 里没有完整的 PIKA_L_CODE/PIKA_R_CODE。"
  err "先运行 setup_hardware.sh 并选择 2 完成左右手绑定。"
  exit 1
}
info "左右手 LHR：L=$LCODE  R=$RCODE"

# 选/建本次任务(决定数据落到哪个子目录)——趁还没起设备栈/挂 trap，此处中断无副作用
choose_task

# =============================================================================
# 总是重启设备栈(不复用)——复用可能拿到"没带 code 的旧栈"→ 采到 pose 丢失。
# 每次都先清掉已有/残留(含孤儿)，再用当前 LCODE/RCODE 重新起，最稳。
# =============================================================================
if docker exec "$CONTAINER" pgrep -f "$CHILD_PATTERN" >/dev/null 2>&1; then
  info "清理已有/残留设备节点(总是重启，不复用)…"; stop_stack
fi

if [ "$HEAD_CAMERA_DRIVER" = "kfcv2" ]; then
  require_single_kfcv2_capture || exit 1
  validate_kfcv2_symlink "$HEAD_CAMERA_DEVICE" || exit 1
  require_kfcv2_not_busy "$HEAD_CAMERA_DEVICE" || exit 1
  ok "KFCv2 USB 预检通过：$HEAD_CAMERA_DEVICE → $(readlink -f "$HEAD_CAMERA_DEVICE")"
fi

# ② 校准：循环【探测→不达标则引导校准→校完再复检】，直到每台基站 acc err<CALIB_ACC_ERR_MAX 或你明确跳过。
#    (survive-cli 占 dongle，必须在起设备栈之前;之前的 bug 是校完不复检就直接进采集。)
info "校准自动判定：每台基站 acc err 需 <${CALIB_ACC_ERR_MAX}（不达标会引导重标并复检）…"
while :; do
  # 注意 timeout 必须带 -k：survive-cli 接住 SIGTERM 会拖着不退，需补 SIGKILL 兜底
  cal=$(docker exec "$CONTAINER" bash -c '
    export LD_LIBRARY_PATH='"$LIBSURVIVE"'/lib:$LD_LIBRARY_PATH
    cd '"$LIBSURVIVE"'/bin && timeout -k 5 20 ./survive-cli 2>&1')
  if printf '%s\n' "$cal" | grep -q LIBUSB_ERROR_BUSY; then
    err "dongle 被占用(LIBUSB_BUSY)——先 docker exec $CONTAINER pkill -9 -f '$CHILD_PATTERN' 再重跑。"; exit 1
  fi
  ch=$(printf '%s\n' "$cal" | grep -oE 'Got OOTX packet [0-9]+' | awk '{print $4}' | sort -u | wc -l)
  # 取【最差那台】基站的 acc err：每台都 < 阈值才算好。只看最小值会被好的那台蒙混过关
  # (实测只看某一台的好值会漏掉另一台的坏值，临界校准可能让 locator 不发有效 pose → 采到 pose=0)。
  amax=$(printf '%s\n' "$cal" | grep -oE 'acc err [0-9.]+' | awk '{print $3}' | sort -rn | head -1)
  if [ -n "$amax" ] && awk -v a="$amax" -v lim="$CALIB_ACC_ERR_MAX" 'BEGIN{exit !(a<lim)}'; then
    ok "定位达标(最差基站 acc err ${amax} < ${CALIB_ACC_ERR_MAX})。"; break
  fi
  warn "定位未达标(最差 acc err=${amax:-无}，OOTX ${ch} 台)。每台需 <${CALIB_ACC_ERR_MAX},否则 pose 可能不稳/丢。"
  read -rp "校准一次吗? [Y=校准 / s=跳过继续 / q=退出]: " a || a=q
  case "$a" in
    s|S) warn "跳过校准 —— pose 可能不准,后果自负。"; break ;;
    q|Q) exit 1 ;;
    *) info "进入 survive-cli --force-calibrate：保持大头静止,等【两台都】 acc err<${CALIB_ACC_ERR_MAX} 再 Ctrl+C 退出…"
       docker exec -it "$CONTAINER" bash -c '
         export LD_LIBRARY_PATH='"$LIBSURVIVE"'/lib:$LD_LIBRARY_PATH
         cd '"$LIBSURVIVE"'/bin && ./survive-cli --force-calibrate'
       echo; info "校准退出,复检中…" ;;   # 回到 while 顶部重新探测确认
  esac
done

# ③ 后台起设备栈
info "后台启动设备栈(日志 → 容器 $SENSOR_LOG)…"
start_stack

trap cleanup EXIT     # 起栈后才挂清理

# ④ 健康自检(代替每天挥手核对)
health_check || exit 1

# =============================================================================
# ⑤ 采集循环
# =============================================================================
# Ctrl+C 与 q 同效:都退出并触发 cleanup(自动停设备栈)。本 trap 只在采集阶段生效——
# 校准阶段(上面)的 Ctrl+C 仍是"结束 force-calibrate 并继续",不受影响。
trap 'echo; exit 130' INT TERM
echo
ok "设备就绪。回车开始采集 → 双击夹爪录制(一轮可连录多条) → 采完 Ctrl+C 或 q 结束(都会自动清理)。"
while true; do
  echo
  printf "%b" "${c_y}↩  [回车]开始采集 | 输入文字+回车=带语言标注 | q 退出: ${c_0}"
  IFS= read -r ans || { ans=q; echo; }
  [ "$ans" = "q" ] && break
  stack_running || { warn "设备栈掉了，重启并自检…"; start_stack; health_check || continue; }
  # >>> pika-migrate: KFCv2 alignment >>>
  if [ "$HEAD_CAMERA_DRIVER" = "kfcv2" ]; then
    KFC_ALIGN_TOPIC="${HEAD_CAMERA_INPUT_TOPIC:-/camera/kfc_compressed}" bash "$PIKA_MIGRATE_DIR/tools/kfc_alignment/align_before_capture.sh" || {
        warn "KFCv2 画面对齐未完成，取消本次采集。"
        continue
      }
  fi
  # <<< pika-migrate: KFCv2 alignment <<<
  # ans 作为位置参数传入(不拼进命令串)——避免含引号/空格/杂散字符时破坏引号配对
  # -e 把本次任务目录传进容器:数据落到 DATA_ROOT/<任务>/,UNIVIS_RELPATH 让 UniVis 只扫该任务
  docker exec -it \
    -e DATASET_DIR="$TASK_DATA_DIR" \
    -e UNIVIS_RELPATH="$TASK" \
    -e PIKA_RUNTIME_ENV="$PIKA_DIR/pika_runtime.env" \
    -e PIKA_HARDWARE_ENV="$PIKA_DIR/pika_hardware.env" \
    -e HEAD_CAMERA_DRIVER="$HEAD_CAMERA_DRIVER" \
    -e HEAD_CAMERA_DEVICE="$HEAD_CAMERA_DEVICE" \
    -e HEAD_CAMERA_WIDTH="$HEAD_CAMERA_WIDTH" \
    -e HEAD_CAMERA_HEIGHT="$HEAD_CAMERA_HEIGHT" \
    -e HEAD_CAMERA_FPS="$HEAD_CAMERA_FPS" \
    -e CAPTURE_HZ="$CAPTURE_HZ" \
    -e ENABLE_HDF5_CONVERT="${ENABLE_HDF5_CONVERT:-false}" \
    -e HDF5_CONVERT_SCRIPT="${HDF5_CONVERT_SCRIPT:-}" \
    "$CONTAINER" \
    bash -c 'cd "$1" && bash run_pika.sh "$2"' _ "$SCRIPTS" "$ans"
done
# 退出(q / Ctrl+C) → trap cleanup 自动停设备栈
