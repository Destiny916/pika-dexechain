#!/bin/bash
# ============================================================================
# run_pika.sh —— Pika Sense 数据采集封装脚本(替代松灵 run_pika.sh)
# ----------------------------------------------------------------------------
# 在【容器内】运行。自动完成:
#   ① 删除残缺 episode(采到一半崩了、pose 帧数为 0 的死目录)
#   ② 选出下一个 episode 号(在现有数据后面 append)
#   ③ 启动 ROS 采集(空格开始/结束录制)
#   ④ 采集结束后体检,提示这条是否完整
#
# 用法:
#   bash run_pika.sh                 # 采下一条(用默认参数)
#   bash run_pika.sh "pick up cup"   # 顺带带一条语言标注(可选,实验性)
#
# 可用环境变量覆盖默认值:
#   DATASET_DIR  数据根目录   (默认来自 pika_runtime.env 的 DATA_DIR)
#   DATA_TYPE    data_tools 配置类型；默认按 HEAD_CAMERA_DRIVER 自动选择
#   TIMEOUT      掉频容忍秒数 (默认 100):某话题实际帧率持续 <= 期望 hz(默认20)超过这么多秒,
#                节点会判定 fail 并【中断本次采集】(useService 模式直接 shutdown)。
#                注意:这【不是】采集总时长,采集靠再次按空格结束。
#                松灵节点默认仅 2 秒(很严,易把正常采集掐断);这里用你验证过的 100(放宽)。
#                想让"传感器掉线就尽快报错"可调小,但代价是偶发掉帧也会中断采集。
#   MIN_POSE     pose 帧数 < 该值视为残缺会被删 (默认 1,即只删 0 帧的死目录)
# ============================================================================
# 注意:不能用 set -u —— ROS 的 setup.bash 内部会引用未绑定变量,set -u 下 source 会直接中断脚本
set -o pipefail

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
PIKA_ROOT=$(readlink -f "$SCRIPT_DIR/../..")
RUNTIME_ENV="${PIKA_RUNTIME_ENV:-$PIKA_ROOT/pika_runtime.env}"
[ -f "$RUNTIME_ENV" ] && source "$RUNTIME_ENV"

PIKA_DIR="${PIKA_DIR:-$PIKA_ROOT}"
DATASET_DIR="${DATASET_DIR:-${DATA_DIR:-/home/kw/agilex/data}}"
TIMEOUT="${TIMEOUT:-100}"   # 掉频容忍秒数(非采集时长!);你验证过的成功值。fail 会中断采集,故放宽
MIN_POSE="${MIN_POSE:-1}"
HEAD_CAMERA_DRIVER="${HEAD_CAMERA_DRIVER:-orbbec}"
if [ -z "${DATA_TYPE:-}" ]; then
  case "$HEAD_CAMERA_DRIVER" in
    kfcv2) DATA_TYPE="multi_pika_kfcv2" ;;
    *) DATA_TYPE="multi_pika" ;;
  esac
fi
CAPTURE_TRIGGER_MODE="${CAPTURE_TRIGGER_MODE:-space}"
case "$CAPTURE_TRIGGER_MODE" in
  space|gripper) ;;
  *) echo "[run_pika] ❌ CAPTURE_TRIGGER_MODE 只能是 space 或 gripper，当前为 $CAPTURE_TRIGGER_MODE" >&2; exit 1 ;;
esac
if [ -z "${CAPTURE_HZ:-}" ]; then
  case "$HEAD_CAMERA_DRIVER" in
    kfcv2) CAPTURE_HZ=10 ;;
    *) CAPTURE_HZ=20 ;;
  esac
fi
ENABLE_HDF5_CONVERT="${ENABLE_HDF5_CONVERT:-false}"
HDF5_CONVERT_SCRIPT="${HDF5_CONVERT_SCRIPT:-}"
KFC_SPLIT_AFTER_CAPTURE="${KFC_SPLIT_AFTER_CAPTURE:-false}"
KFC_SPLIT_SIZE="${KFC_SPLIT_SIZE:-640x360}"
KFC_SPLIT_OVERWRITE="${KFC_SPLIT_OVERWRITE:-false}"
# 采集成功后自动让 UniVis 重新扫描数据源(浏览器刷新即见新数据)。设 UNIVIS_URL="" 可关闭。
UNIVIS_URL="${UNIVIS_URL:-http://127.0.0.1:8010}"
UNIVIS_WORKSPACE="${UNIVIS_WORKSPACE:-raw}"
# 按任务分目录后,让 UniVis 只扫本任务子目录(相对其 raw 根的路径)。默认空=扫根(旧行为)。
# 前提:UniVis 启动时 raw 根需指向数据总根(本套 = /home/kw/agilex/data),否则此相对路径无意义。
UNIVIS_RELPATH="${UNIVIS_RELPATH:-}"
# 采集统计:记录每条 episode 的真实录制时长/间隔/会话累计
STATS_FILE="${STATS_FILE:-$DATASET_DIR/.run_pika_stats.tsv}"
SESSION_GAP="${SESSION_GAP:-1800}"   # 与上一条间隔 > 该秒数(默认30分钟)视为新一轮会话
INSTRUCTION="${1:-}"

# --- 确保 ROS 环境就绪(脚本独立运行时 .bashrc 可能没被 source) ---
source /opt/ros/humble/setup.bash >/dev/null 2>&1
source "$PIKA_DIR/pika_ros/install/setup.bash" >/dev/null 2>&1

# 容器内进程是 root,写出的数据宿主侧属主就是 root → 宿主用户(dex)删不动/改不动(被"锁")。
# 采完把新数据 chown 回宿主用户。自动推断属主:取数据根(或其最近的已存在上级)的属主——
# 它由宿主用户建,即宿主 uid:gid;不写死,换用户/换路径都自适应。可用 DATA_OWNER=uid:gid 覆盖。
# 必须在下面 mkdir -p 之前算:否则新机首跑时 root 建出 DATASET_DIR,参照会被污染成 root。
if [ -z "${DATA_OWNER:-}" ]; then
  ref="$DATASET_DIR"
  while [ ! -e "$ref" ] && [ "$ref" != "/" ]; do ref=$(dirname "$ref"); done
  DATA_OWNER=$(stat -c '%u:%g' "$ref" 2>/dev/null)
fi

mkdir -p "$DATASET_DIR"

# --- 工具:数某条 episode 的 pose 帧数(取左右手中较小值,任一手缺即残缺) ---
pose_count() {
  local d="$1" l r
  # 只数 .json 位姿帧(排除 run_data_sync 生成的 sync.txt 等非帧文件)
  l=$(find "$d/localization/pose/pika_l" -type f -name '*.json' 2>/dev/null | wc -l)
  r=$(find "$d/localization/pose/pika_r" -type f -name '*.json' 2>/dev/null | wc -l)
  echo $(( l < r ? l : r ))
}

# --- 工具:返回当前最大 episode 序号(无数据时返回 -1) ---
highest_episode() {
  local d idx max=-1
  for d in "$DATASET_DIR"/episode*; do
    [ -d "$d" ] || continue
    idx="${d##*/episode}"
    [[ "$idx" =~ ^[0-9]+$ ]] || continue
    (( idx > max )) && max=$idx
  done
  echo "$max"
}

# --- 工具:把秒数格式化成「X时X分X秒」 ---
fmt_dur() {
  awk -v s="$1" 'BEGIN{
    if (s<0){print "—"; exit}
    s=int(s+0.5); h=int(s/3600); m=int((s%3600)/60); sec=s%60;
    if(h>0) printf "%d时%02d分%02d秒",h,m,sec;
    else if(m>0) printf "%d分%02d秒",m,sec;
    else printf "%d秒",sec
  }'
}

# --- 工具:从 pose_l 的 .json 文件名(epoch.微秒)取首末时间戳 → echo "首 末" ---
pose_span() {
  local dir="$1/localization/pose/pika_l"
  ls "$dir" 2>/dev/null | grep '\.json$' | sed 's/\.json$//' \
    | sort -n | awk 'NR==1{f=$0} {l=$0} END{if(f!="") print f, l}'
}

# --- 工具:打印本轮会话汇总(基于 STATS_FILE;尾部连续、间隔<SESSION_GAP 的算同一会话) ---
# 记账(每条 episode 写一行)统一由 rebuild_stats 按目录补全,这里只负责"读 STATS → 报告"。
# 这样一次 launch 录多条(松灵节点每双击一轮自增 episode)也能全部记全、统计正确。
report_session() {
  [ -s "$STATS_FILE" ] || return 0
  awk -F'\t' -v gap="$SESSION_GAP" '
    { rs[NR]=$1; re[NR]=$2; du[NR]=$4; n=NR }
    END{
      if(n==0) exit
      ss=1; for(i=n;i>1;i--){ if(rs[i]-re[i-1] > gap){ ss=i; break } }
      cnt=n-ss+1; td=0; for(i=ss;i<=n;i++) td+=du[i]; span=re[n]-rs[ss];
      printf "%d\t%.3f\t%.3f\n", cnt, td, span
    }' "$STATS_FILE" | { IFS=$'\t' read -r cnt totaldur span
      echo "[run_pika] ───────── 采集统计 ─────────"
      echo "[run_pika]  本轮会话累计: $cnt 条 | 录制总时长 $(fmt_dur "$totaldur") | 会话总跨度 $(fmt_dur "$span")"
      echo "[run_pika] ──────────────────────────"
    }
}

# --- 工具:按现有 episode 目录【全量重建】STATS(对账;不依赖采集是否正常收尾)---
# 直接以"现存目录"为准:清空后逐目录从 pose 时间戳重算。这样同号重录(残缺删→重采同号、
# 新时间戳)、整目录删除留孤儿行 都不会残留错误旧行。数据全部来自目录,清空不丢任何东西。
rebuild_stats() {
  local d name pose span first last dur
  : > "$STATS_FILE"
  for d in "$DATASET_DIR"/episode*; do
    [ -d "$d" ] || continue
    name=$(basename "$d")
    pose=$(pose_count "$d"); [ "$pose" -lt "$MIN_POSE" ] && continue   # 残缺的不记
    span=$(pose_span "$d"); first=$(echo "$span" | awk '{print $1}'); last=$(echo "$span" | awk '{print $2}')
    [ -z "$first" ] && continue
    dur=$(awk -v a="$first" -v b="$last" 'BEGIN{printf "%.3f", b-a}')
    printf "%s\t%s\t%s\t%s\t%s\n" "$first" "$last" "$name" "$dur" "$pose" >> "$STATS_FILE"
  done
  # 按首帧时间戳排序(会话分段 awk 依赖 STATS 行按时间顺序)
  [ -s "$STATS_FILE" ] && sort -t$'\t' -k1,1n -o "$STATS_FILE" "$STATS_FILE" 2>/dev/null
}

# --- 工具:让 UniVis 重新扫描数据源(best-effort,UniVis 没开就跳过) ---
# 说明:UniVis 用自己的同步直接读原始带时间戳文件,不需要 run_data_sync;这里只是刷新源
refresh_univis() {
  [ -z "$UNIVIS_URL" ] && return 0
  command -v curl >/dev/null 2>&1 || return 0
  # 先探测 UniVis 是否在线(2 秒超时)
  if ! curl -s -o /dev/null -m 2 "$UNIVIS_URL" 2>/dev/null; then
    echo "[run_pika] (UniVis 未在线,跳过刷新;开了就在浏览器手动刷新)"
    return 0
  fi
  curl -s -o /dev/null -m 20 -X POST "$UNIVIS_URL/api/workspaces/source" \
       -H "Content-Type: application/json" \
       -d "{\"workspace\":\"$UNIVIS_WORKSPACE\",\"input_adapter\":\"PikaRawEpisodeAdapter\",\"relative_path\":\"$UNIVIS_RELPATH\"}" 2>/dev/null
  local cnt
  cnt=$(curl -s -m 10 "$UNIVIS_URL/api/episodes" 2>/dev/null | grep -o '"episode_id"' | wc -l)
  echo "[run_pika] 已通知 UniVis 重新扫描,当前可见 $cnt 条 episode。浏览器刷新 $UNIVIS_URL 查看。"
}

run_kfc_split() {
  [ "$HEAD_CAMERA_DRIVER" = "kfcv2" ] || return 0
  case "$KFC_SPLIT_AFTER_CAPTURE" in
    1|true|TRUE|yes|YES|on|ON) ;;
    *) echo "[run_pika] KFC 左右目离线拆分已关闭(KFC_SPLIT_AFTER_CAPTURE=$KFC_SPLIT_AFTER_CAPTURE)。"; return 0 ;;
  esac
  local split_script="$SCRIPT_DIR/kfc/split_kfc_images.py"
  if [ ! -f "$split_script" ]; then
    echo "[run_pika] KFC 拆分脚本不存在：$split_script，跳过。"
    return 0
  fi
  local overwrite_arg=()
  case "$KFC_SPLIT_OVERWRITE" in
    1|true|TRUE|yes|YES|on|ON) overwrite_arg=(--overwrite) ;;
  esac
  for idx in $(seq "$NEXT" "$last"); do
    [ -d "$DATASET_DIR/episode$idx" ] || continue
    [ -d "$DATASET_DIR/episode$idx/camera/color/pikaHeadCamera" ] || continue
    echo "[run_pika] KFC 后处理: episode$idx 拆分左右目(size=$KFC_SPLIT_SIZE，保留原始 pikaHeadCamera)"
    python3 "$split_script" "$DATASET_DIR/episode$idx" --size "$KFC_SPLIT_SIZE" "${overwrite_arg[@]}" \
      || echo "[run_pika] KFC 左右目拆分失败: episode$idx，请人工复核。"
  done
}

run_hdf5_convert() {
  case "$ENABLE_HDF5_CONVERT" in
    1|true|TRUE|yes|YES|on|ON) ;;
    *) return 0 ;;
  esac
  if [ -z "$HDF5_CONVERT_SCRIPT" ]; then
    echo "[run_pika] ENABLE_HDF5_CONVERT 已开启，但未设置 HDF5_CONVERT_SCRIPT，跳过 HDF5 转换。"
    return 0
  fi
  if [ ! -f "$HDF5_CONVERT_SCRIPT" ]; then
    echo "[run_pika] HDF5 转换脚本不存在：$HDF5_CONVERT_SCRIPT，跳过。"
    return 0
  fi
  for idx in $(seq "$NEXT" "$last"); do
    [ -d "$DATASET_DIR/episode$idx" ] || continue
    echo "[run_pika] HDF5 后处理: episode$idx"
    bash "$HDF5_CONVERT_SCRIPT" "$DATASET_DIR/episode$idx" || echo "[run_pika] HDF5 转换失败: episode$idx，请人工复核。"
  done
}

# --- 1) 清理残缺 episode ---
echo "[run_pika] 扫描残缺目录(pose < $MIN_POSE 视为残缺)..."
for d in "$DATASET_DIR"/episode*; do
  [ -d "$d" ] || continue
  n=$(pose_count "$d")
  if [ "$n" -lt "$MIN_POSE" ]; then
    echo "[run_pika]   删除残缺: $(basename "$d")  (pose=$n)"
    rm -rf "$d"
  fi
done

# --- 1.5) 补全统计:把之前 Ctrl+C 漏记的 episode 按目录补回 STATS(幂等) ---
rebuild_stats

# --- 2) 计算下一个 episode 号(现有最大值 + 1;无则 0) ---
max=-1
for d in "$DATASET_DIR"/episode*; do
  [ -d "$d" ] || continue
  idx="${d##*/episode}"
  [[ "$idx" =~ ^[0-9]+$ ]] || continue
  (( idx > max )) && max=$idx
done
NEXT=$(( max + 1 ))

echo "[run_pika] 本次采集 → episode$NEXT  (目录: $DATASET_DIR/episode$NEXT)"
echo "[run_pika] 采集配置: type=$DATA_TYPE  head_camera=$HEAD_CAMERA_DRIVER  hz=$CAPTURE_HZ  trigger=$CAPTURE_TRIGGER_MODE"
[ -n "$INSTRUCTION" ] && echo "[run_pika] 语言标注: $INSTRUCTION"
if [ "$CAPTURE_TRIGGER_MODE" = "space" ]; then
  echo "[run_pika] >>> 按空格或踩踏板开始录制,再次按下结束;q 或 Ctrl+C 收尾并退出。"
else
  echo "[run_pika] >>> 双击任一夹爪开始/结束录制;Ctrl+C 收尾并退出。"
fi
echo

# --- 3) 启动采集节点：空格模式由终端客户端调用服务；夹爪模式由夹爪节点调用服务 ---
TASK_NAME="${UNIVIS_RELPATH:-$(basename "$DATASET_DIR")}"
INSTRUCTION_PARAM='[null]'
[ -n "$INSTRUCTION" ] && INSTRUCTION_PARAM="[\"$INSTRUCTION\"]"
LAUNCH_INSTRUCTION_PARAM='\[null\]'
[ -n "$INSTRUCTION" ] && LAUNCH_INSTRUCTION_PARAM="\\[\\\"$INSTRUCTION\\\"\\]"

if [ "$CAPTURE_TRIGGER_MODE" = "gripper" ]; then
  ros2 launch data_tools run_data_capture.launch.py \
    type:="$DATA_TYPE" \
    useService:=true \
    datasetDir:="$DATASET_DIR" \
    episodeIndex:="$NEXT" \
    instructions:="$LAUNCH_INSTRUCTION_PARAM" \
    hz:="$CAPTURE_HZ" \
    timeout:="$TIMEOUT"
  rc=$?
else
CAPTURE_BIN="$PIKA_DIR/pika_ros/install/data_tools/lib/data_tools/data_tools_dataCapture"
CAPTURE_CONFIG="$PIKA_DIR/pika_ros/install/data_tools/share/data_tools/config/${DATA_TYPE}_data_params.yaml"
CAPTURE_LOG="/tmp/run_pika_capture_$$.log"

STATE=IDLE
ACTIVE_EP=-1
CAPTURE_PID=
CLIENT_PID=
CLIENT_IN=
CLIENT_OUT=
CLEANED_UP=0
STOP_REQUESTED=0

capture_call() {
  local action=$1 episode=$2 response
  printf '%s\t%s\n' "$action" "$episode" >&"$CLIENT_IN"
  if ! IFS= read -r -t 70 response <&"$CLIENT_OUT"; then
    echo "[run_pika] ❌ 采集服务响应超时或客户端已退出。" >&2
    return 1
  fi
  if [[ "$response" != OK$'\t'* ]]; then
    echo "[run_pika] ❌ 采集服务返回: $response" >&2
    return 1
  fi
}

stop_pid() {
  local pid=$1 grace_steps=${2:-20}
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  for _ in $(seq 1 "$grace_steps"); do
    kill -0 "$pid" 2>/dev/null || { wait "$pid" 2>/dev/null || true; return 0; }
    sleep 0.1
  done
  kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 20); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

start_episode() {
  local next
  next=$(( $(highest_episode) + 1 ))
  if capture_call START "$next"; then
    ACTIVE_EP=$next
    STATE=RECORDING
    echo
    echo "[run_pika] 🔴 录制中: $DATASET_DIR/episode$ACTIVE_EP"
  else
    echo "[run_pika] 开始失败,状态保持 IDLE。" >&2
    return 1
  fi
}

end_episode() {
  if capture_call END "$ACTIVE_EP"; then
    echo
    echo "[run_pika] ✅ 已保存: $DATASET_DIR/episode$ACTIVE_EP"
    ACTIVE_EP=-1
    STATE=IDLE
  else
    echo "[run_pika] 结束失败,状态仍为 RECORDING。" >&2
    return 1
  fi
}

capture_cleanup() {
  [ "$CLEANED_UP" = 1 ] && return 0
  CLEANED_UP=1
  trap - EXIT INT TERM
  if [ "$STATE" = RECORDING ]; then
    echo
    echo "[run_pika] 正在收尾当前 episode..."
    end_episode || true
  fi
  if [ -n "$CLIENT_IN" ]; then
    printf 'QUIT\n' >&"$CLIENT_IN" 2>/dev/null || true
  fi
  [ -n "$CLIENT_PID" ] && stop_pid "$CLIENT_PID" 20
  [ -n "$CAPTURE_PID" ] && stop_pid "$CAPTURE_PID" 20
}

on_capture_signal() {
  STOP_REQUESTED=1
  echo
  echo "[run_pika] 收到退出信号,正在安全收尾..."
}

[ -x "$CAPTURE_BIN" ] || { echo "[run_pika] ❌ 采集程序不存在: $CAPTURE_BIN" >&2; exit 1; }
[ -f "$CAPTURE_CONFIG" ] || { echo "[run_pika] ❌ 采集配置不存在: $CAPTURE_CONFIG" >&2; exit 1; }

setsid "$CAPTURE_BIN" --ros-args \
  --params-file "$CAPTURE_CONFIG" \
  -p useService:=true \
  -p datasetDir:="$DATASET_DIR" \
  -p episodeIndex:="$NEXT" \
  -p "instructions:='$INSTRUCTION_PARAM'" \
  -p hz:="$CAPTURE_HZ" \
  -p timeout:="$TIMEOUT" \
  >"$CAPTURE_LOG" 2>&1 < /dev/null &
CAPTURE_PID=$!
trap capture_cleanup EXIT

for _ in $(seq 1 25); do
  ros2 service list 2>/dev/null | grep -qx /data_tools_dataCapture/capture_service && break
  kill -0 "$CAPTURE_PID" 2>/dev/null || break
  sleep 1
done
if ! ros2 service list 2>/dev/null | grep -qx /data_tools_dataCapture/capture_service; then
  echo "[run_pika] ❌ 采集服务未就绪,日志: $CAPTURE_LOG" >&2
  tail -80 "$CAPTURE_LOG" >&2
  exit 1
fi

read -r -d '' CAPTURE_CLIENT_CODE <<'PY' || true
import sys

import rclpy
from data_msgs.srv import CaptureService

task_name, dataset_dir, instructions = sys.argv[1:4]
rclpy.init()
node = rclpy.create_node("spacebar_capture_client")
client = node.create_client(CaptureService, "/data_tools_dataCapture/capture_service")
while not client.wait_for_service(timeout_sec=1.0):
    pass
print("READY", flush=True)

for line in sys.stdin:
    fields = line.rstrip("\n").split("\t")
    if fields[0] == "QUIT":
        break
    action, episode_text = fields
    req = CaptureService.Request()
    req.start = action == "START"
    req.end = action == "END"
    req.episode_index = int(episode_text)
    req.dataset_dir = dataset_dir
    req.instructions = instructions
    req.task_name = task_name
    req.task_descriptions = task_name
    req.task_id = task_name
    try:
        future = client.call_async(req)
        rclpy.spin_until_future_complete(node, future, timeout_sec=60.0)
        if not future.done():
            print("ERROR\tservice response timed out", flush=True)
            continue
        result = future.result()
        status = "OK" if result.success else "ERROR"
        message = result.message.replace("\n", " ").replace("\t", " ")
        print(f"{status}\t{message}", flush=True)
    except BaseException as exc:
        print(f"ERROR\t{exc}", flush=True)

node.destroy_node()
rclpy.shutdown()
PY

coproc CAPTURE_CLIENT {
  exec python3 -u -c "$CAPTURE_CLIENT_CODE" "$TASK_NAME" "$DATASET_DIR" "$INSTRUCTION_PARAM" \
    2>>"$CAPTURE_LOG"
}
CLIENT_PID=$CAPTURE_CLIENT_PID
CLIENT_OUT=${CAPTURE_CLIENT[0]}
CLIENT_IN=${CAPTURE_CLIENT[1]}
if ! IFS= read -r -t 20 client_status <&"$CLIENT_OUT" || [ "$client_status" != READY ]; then
  echo "[run_pika] ❌ 空格采集客户端未就绪,日志: $CAPTURE_LOG" >&2
  tail -80 "$CAPTURE_LOG" >&2
  exit 1
fi

echo "[run_pika] IDLE: 下一条 episode$(( $(highest_episode) + 1 ))"
echo "[run_pika] 控制: 空格=开始/结束 | q=安全收尾并退出"
trap on_capture_signal INT TERM
while [ "$STOP_REQUESTED" = 0 ]; do
  printf '[%s] > ' "$STATE"
  IFS= read -rsn1 key || break
  case "$key" in
    ' ')
      echo
      if [ "$STATE" = IDLE ]; then start_episode; else end_episode; fi
      ;;
    q|Q)
      echo
      echo "[run_pika] 请求退出。"
      break
      ;;
  esac
done
trap - INT TERM
capture_cleanup
rc=0
fi

# --- 4) 采集结束后体检 —— 一次 launch 可能录多条 ---
# 空格控制器每"开始→结束"一轮生成一个 episode;一次运行可连续录多条。
# 故体检【本次 launch 新建的所有 episode(序号 ≥ NEXT)】,而非只 episode$NEXT。
echo
last=$(for d in "$DATASET_DIR"/episode*; do idx="${d##*/episode}"; [[ "$idx" =~ ^[0-9]+$ ]] && echo "$idx"; done | sort -n | tail -1)
if [ -z "$last" ] || [ "$last" -lt "$NEXT" ]; then
  echo "[run_pika] (未生成 episode$NEXT 目录,可能没触发录制)"
else
  for idx in $(seq "$NEXT" "$last"); do
    DIR="$DATASET_DIR/episode$idx"; [ -d "$DIR" ] || continue
    n=$(pose_count "$DIR")
    if [ "$n" -lt "$MIN_POSE" ]; then
      echo "[run_pika] ⚠ episode$idx pose 帧=$n —— 残缺(下次重跑自动删,建议重录)。"
    else
      echo "[run_pika] ✓ episode$idx 采集完成,pose 帧=$n。"
    fi
  done
  rebuild_stats        # 把本次新建的所有好 episode 补进 STATS(残缺的跳过)
  report_session       # 基于全 STATS 打印本轮会话累计
  run_kfc_split        # KFCv2 离线拆左右目;必须在 chown 前,避免新文件被 root 锁住
  # 把本次新建的 episode + 统计文件 chown 回宿主用户,避免宿主侧被 root 锁住(删不动)
  if [ -n "$DATA_OWNER" ]; then
    for idx in $(seq "$NEXT" "$last"); do
      [ -d "$DATASET_DIR/episode$idx" ] && chown -R "$DATA_OWNER" "$DATASET_DIR/episode$idx" 2>/dev/null
    done
    [ -f "$STATS_FILE" ] && chown "$DATA_OWNER" "$STATS_FILE" 2>/dev/null
  fi
  run_hdf5_convert
  refresh_univis
fi

exit $rc
