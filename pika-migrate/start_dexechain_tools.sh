#!/bin/bash
# =============================================================================
# DexEChain HDF5/UniVis 处理容器一键启动
# -----------------------------------------------------------------------------
# 用法：
#   bash start_dexechain_tools.sh start
#   bash start_dexechain_tools.sh univis
#   bash start_dexechain_tools.sh workflow /path/to/umi_workflow.yaml
#   bash start_dexechain_tools.sh raw2hdf5 /path/to/raw_batch [output_dir]
#   bash start_dexechain_tools.sh shell
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/pika_migrate.conf}"
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

PIKA_USER="${PIKA_USER:-${SUDO_USER:-${USER:-$(id -un)}}}"
HOST_HOME="${HOST_HOME:-/home/${PIKA_USER}}"
AGILEX_DIR="${AGILEX_DIR:-$HOST_HOME/agilex}"
DATA_DIR="${DATA_DIR:-$AGILEX_DIR/data}"

DEXECHAIN_WORKSPACE="${DEXECHAIN_WORKSPACE:-$HOST_HOME/workspace}"
EMBODICHAIN_DIR="${EMBODICHAIN_DIR:-$DEXECHAIN_WORKSPACE/embodichain}"
EMBODICHAIN_REPO_URL="${EMBODICHAIN_REPO_URL:-http://192.168.3.16/Engine/embodichain}"
EMBODICHAIN_BRANCH="${EMBODICHAIN_BRANCH:-umi_gift}"
DEXECHAIN_CONTAINER_NAME="${DEXECHAIN_CONTAINER_NAME:-dexechain-tools}"
DEXECHAIN_IMAGE_X86_64="${DEXECHAIN_IMAGE_X86_64:-192.168.3.13:5000/w1_act:embodichain-20260715-8f82de52}"
DEXECHAIN_IMAGE_AARCH64="${DEXECHAIN_IMAGE_AARCH64:-192.168.3.13:5000/w1_act:embodichain-20260706-fffe080c}"
DEXECHAIN_IMAGE="${DEXECHAIN_IMAGE:-}"
DEXECHAIN_USE_GPU="${DEXECHAIN_USE_GPU:-auto}"
DEXECHAIN_PYTHON="${DEXECHAIN_PYTHON:-/opt/miniconda/envs/py310/bin/python}"
DEXECHAIN_INSTALL_ON_START="${DEXECHAIN_INSTALL_ON_START:-true}"
DEXECHAIN_BOOTSTRAP_PACKAGES="${DEXECHAIN_BOOTSTRAP_PACKAGES:-python-multipart>=0.0.12}"
DEXECHAIN_FALLBACK_EDITABLE_INSTALL="${DEXECHAIN_FALLBACK_EDITABLE_INSTALL:-true}"
DEXECHAIN_PIP_TARGET="${DEXECHAIN_PIP_TARGET:-.[univis]}"
DEXECHAIN_PIP_INDEX_ARGS="${DEXECHAIN_PIP_INDEX_ARGS:---extra-index-url http://pyp.open3dv.site:2345/simple/ --extra-index-url http://192.168.3.43:8080/simple/ --trusted-host pyp.open3dv.site --trusted-host 192.168.3.43}"
UNIVIS_PORT="${UNIVIS_PORT:-8010}"
UNIVIS_OUTPUT_DIR="${UNIVIS_OUTPUT_DIR:-$AGILEX_DIR/hdf5_out}"
UNIVIS_LOG="${UNIVIS_LOG:-$AGILEX_DIR/log/univis.log}"
HDF5_WORKFLOW_DIR="${HDF5_WORKFLOW_DIR:-$AGILEX_DIR/hdf5_workflow}"
RAW2HDF5_BASE_CONFIG="${RAW2HDF5_BASE_CONFIG:-precheck_raw_to_hdf5}"
HEAD_CAMERA_DRIVER="${HEAD_CAMERA_DRIVER:-none}"

c_g='\033[32m'; c_r='\033[31m'; c_y='\033[33m'; c_b='\033[36m'; c_0='\033[0m'
info(){ echo -e "${c_b}▸${c_0} $*"; }
ok(){   echo -e "${c_g}✅ $*${c_0}"; }
warn(){ echo -e "${c_y}⚠️  $*${c_0}"; }
err(){  echo -e "${c_r}❌ $*${c_0}" >&2; }
die(){  err "$*"; exit 1; }

truthy(){
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

select_image(){
  if [ -n "$DEXECHAIN_IMAGE" ]; then
    echo "$DEXECHAIN_IMAGE"
    return 0
  fi
  case "$(uname -m)" in
    x86_64) echo "$DEXECHAIN_IMAGE_X86_64" ;;
    aarch64) echo "$DEXECHAIN_IMAGE_AARCH64" ;;
    *) die "不支持的架构：$(uname -m)。请在 pika_migrate.conf 设置 DEXECHAIN_IMAGE。" ;;
  esac
}

docker_tty_args(){
  if [ -t 0 ] && [ -t 1 ]; then
    printf '%s\n' "-it"
  else
    printf '%s\n' "-i"
  fi
}

ACTIVE_WORKFLOW_PID_FILE=""
ACTIVE_WORKFLOW_INTERRUPT_COUNT=0

forward_active_workflow_signal(){
  local requested_signal=$1 signal=$1 pgid
  if [ "$requested_signal" = "INT" ]; then
    ACTIVE_WORKFLOW_INTERRUPT_COUNT=$((ACTIVE_WORKFLOW_INTERRUPT_COUNT + 1))
    if [ "$ACTIVE_WORKFLOW_INTERRUPT_COUNT" -gt 1 ]; then
      signal="TERM"
    fi
  else
    ACTIVE_WORKFLOW_INTERRUPT_COUNT=$((ACTIVE_WORKFLOW_INTERRUPT_COUNT + 1))
  fi

  if [ -z "$ACTIVE_WORKFLOW_PID_FILE" ] || [ ! -s "$ACTIVE_WORKFLOW_PID_FILE" ]; then
    warn "尚未获得容器 workflow 进程组，无法转发 $signal。"
    return 0
  fi
  pgid="$(tr -d '[:space:]' < "$ACTIVE_WORKFLOW_PID_FILE")"
  if [[ ! "$pgid" =~ ^[0-9]+$ ]]; then
    warn "workflow 进程组记录无效，无法转发 $signal：$pgid"
    return 0
  fi

  warn "正在向容器 workflow 进程组 $pgid 转发 $signal 信号..."
  if ! docker exec "$DEXECHAIN_CONTAINER_NAME" bash -lc \
    'kill -s "$1" -- "-$2"' _ "$signal" "$pgid"; then
    warn "未能向 workflow 进程组 $pgid 发送 $signal；该任务可能已经结束。"
  fi
}

wait_for_active_workflow_exit(){
  local pgid attempt
  [ -n "$ACTIVE_WORKFLOW_PID_FILE" ] && [ -s "$ACTIVE_WORKFLOW_PID_FILE" ] || return 0
  pgid="$(tr -d '[:space:]' < "$ACTIVE_WORKFLOW_PID_FILE")"
  [[ "$pgid" =~ ^[0-9]+$ ]] || return 0
  for attempt in {1..10}; do
    if ! docker exec "$DEXECHAIN_CONTAINER_NAME" bash -lc \
      'kill -0 -- "-$1" 2>/dev/null' _ "$pgid"; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

run_with_workflow_signal_forwarding(){
  [ $# -ge 2 ] || die "内部参数错误：缺少 workflow PID 文件或执行命令。"
  local pid_file=$1 status
  shift
  mkdir -p "$(dirname -- "$pid_file")"
  : > "$pid_file"
  ACTIVE_WORKFLOW_PID_FILE="$pid_file"
  ACTIVE_WORKFLOW_INTERRUPT_COUNT=0
  trap 'forward_active_workflow_signal INT' INT
  trap 'forward_active_workflow_signal TERM' TERM

  if "$@"; then
    status=0
  else
    status=$?
  fi

  if [ "$status" -eq 130 ] && [ "$ACTIVE_WORKFLOW_INTERRUPT_COUNT" -eq 0 ]; then
    forward_active_workflow_signal INT
  fi
  if [ "$ACTIVE_WORKFLOW_INTERRUPT_COUNT" -gt 0 ] && ! wait_for_active_workflow_exit; then
    warn "workflow 未在 SIGINT 后及时退出，正在发送 TERM。"
    forward_active_workflow_signal TERM
    wait_for_active_workflow_exit || warn "workflow 仍未退出，请使用进程组记录手动检查。"
  fi

  trap - INT TERM
  rm -f -- "$pid_file"
  ACTIVE_WORKFLOW_PID_FILE=""
  if [ "$ACTIVE_WORKFLOW_INTERRUPT_COUNT" -gt 0 ]; then
    warn "workflow 已被用户中断。"
    ACTIVE_WORKFLOW_INTERRUPT_COUNT=0
    return 130
  fi
  return "$status"
}

ensure_repo(){
  mkdir -p "$DEXECHAIN_WORKSPACE" "$AGILEX_DIR/log" "$DATA_DIR" "$HDF5_WORKFLOW_DIR" "$UNIVIS_OUTPUT_DIR"
  command -v git >/dev/null 2>&1 || die "未找到 git，无法管理 $EMBODICHAIN_REPO_URL"
  git check-ref-format --branch "$EMBODICHAIN_BRANCH" >/dev/null 2>&1 || \
    die "EMBODICHAIN_BRANCH 不是有效的 Git 分支名：$EMBODICHAIN_BRANCH"
  if [ -d "$EMBODICHAIN_DIR/.git" ]; then
    ok "EmbodiChain 仓库已存在：$EMBODICHAIN_DIR"
    ensure_repo_branch
    return 0
  fi
  [ -e "$EMBODICHAIN_DIR" ] && die "$EMBODICHAIN_DIR 已存在但不是 git 仓库，请手动检查。"
  info "克隆 EmbodiChain：$EMBODICHAIN_REPO_URL"
  git clone --branch "$EMBODICHAIN_BRANCH" "$EMBODICHAIN_REPO_URL" "$EMBODICHAIN_DIR"
}

ensure_repo_branch(){
  local current_branch display_branch answer branch_refspec
  current_branch="$(git -C "$EMBODICHAIN_DIR" branch --show-current)"
  if [ "$current_branch" = "$EMBODICHAIN_BRANCH" ]; then
    ok "EmbodiChain 分支符合配置：$EMBODICHAIN_BRANCH"
    return 0
  fi

  display_branch="${current_branch:-detached HEAD}"
  warn "EmbodiChain 当前分支为 $display_branch，配置期望分支为 $EMBODICHAIN_BRANCH。"
  if [ ! -t 0 ]; then
    die "非交互环境无法确认分支切换。请手动切换，或将 EMBODICHAIN_BRANCH 配置为 $display_branch。"
  fi

  read -r -p "是否切换至 $EMBODICHAIN_BRANCH 分支？[y/N] " answer
  case "$answer" in
    y|Y|yes|YES|Yes|是) ;;
    *) die "已取消切换；当前操作停止。" ;;
  esac

  if git -C "$EMBODICHAIN_DIR" show-ref --verify --quiet "refs/heads/$EMBODICHAIN_BRANCH"; then
    git -C "$EMBODICHAIN_DIR" switch "$EMBODICHAIN_BRANCH"
  else
    info "从 origin 获取 EmbodiChain 分支：$EMBODICHAIN_BRANCH"
    branch_refspec="+refs/heads/$EMBODICHAIN_BRANCH:refs/remotes/origin/$EMBODICHAIN_BRANCH"
    git -C "$EMBODICHAIN_DIR" fetch origin \
      "$branch_refspec" || \
      die "无法从 origin 获取分支：$EMBODICHAIN_BRANCH"
    git -C "$EMBODICHAIN_DIR" show-ref --verify --quiet "refs/remotes/origin/$EMBODICHAIN_BRANCH" || \
      die "远端 origin 不存在分支：$EMBODICHAIN_BRANCH"
    if ! git -C "$EMBODICHAIN_DIR" config --get-all remote.origin.fetch | \
      grep -Fqx -- "$branch_refspec"; then
      git -C "$EMBODICHAIN_DIR" config --add remote.origin.fetch "$branch_refspec"
    fi
    git -C "$EMBODICHAIN_DIR" switch --track -c "$EMBODICHAIN_BRANCH" "origin/$EMBODICHAIN_BRANCH"
  fi
  ok "EmbodiChain 已切换至配置分支：$EMBODICHAIN_BRANCH"
}

docker_has_nvidia_runtime(){
  docker info --format '{{.Runtimes}}' 2>/dev/null | grep -q nvidia
}

append_mount_if_exists(){
  local -n _args=$1
  local host=$2
  local container=$3
  if [ -e "$host" ]; then
    _args+=(--volume "$host:$container")
  fi
  return 0
}

append_device_if_exists(){
  local -n _args=$1
  local dev=$2
  if [ -e "$dev" ]; then
    _args+=(--device "$dev")
  fi
  return 0
}

container_exists(){
  docker ps -a --format '{{.Names}}' | grep -qx "$DEXECHAIN_CONTAINER_NAME"
}

container_running(){
  docker ps --format '{{.Names}}' | grep -qx "$DEXECHAIN_CONTAINER_NAME"
}

start_container(){
  ensure_repo
  command -v docker >/dev/null 2>&1 || die "未找到 docker。"
  docker ps >/dev/null 2>&1 || die "docker 无法免 sudo 运行。"

  local image
  image="$(select_image)"
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    info "拉取 DexEChain 镜像：$image"
    docker pull "$image"
  fi

  if container_running; then
    ok "DexEChain 处理容器已在运行：$DEXECHAIN_CONTAINER_NAME"
    install_or_verify
    return 0
  fi
  if container_exists; then
    info "启动已有容器：$DEXECHAIN_CONTAINER_NAME"
    docker start "$DEXECHAIN_CONTAINER_NAME" >/dev/null
    install_or_verify
    ok "DexEChain 处理容器已启动"
    return 0
  fi

  local args=()
  args+=(--network=host --pid=host)
  args+=(--name "$DEXECHAIN_CONTAINER_NAME")
  args+=(--restart unless-stopped)
  args+=(--volume "$DEXECHAIN_WORKSPACE:/root/workspace")
  args+=(--volume "$EMBODICHAIN_DIR:/root/workspace/embodichain")
  args+=(--volume "$AGILEX_DIR:$AGILEX_DIR")
  args+=(-e "PYTHONPATH=/root/workspace/embodichain/tools/univis/src:/root/workspace/embodichain")
  args+=(-e "PIKA_DATA_DIR=$DATA_DIR")
  args+=(-e "PIKA_HDF5_WORKFLOW_DIR=$HDF5_WORKFLOW_DIR")
  args+=(-e "UNIVIS_PORT=$UNIVIS_PORT")
  args+=(-e "DEXECHAIN_PYTHON=$DEXECHAIN_PYTHON")
  args+=(-e "PATH=$(dirname "$DEXECHAIN_PYTHON"):/root/.local/bin:/usr/local/cuda/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
  args+=(-e "DISPLAY=${DISPLAY:-}")

  append_mount_if_exists args /dev/shm /dev/shm
  append_mount_if_exists args /tmp/.X11-unix /tmp/.X11-unix
  append_mount_if_exists args "$HOST_HOME/.dexforce" /root/.dexforce
  append_mount_if_exists args /usr/share/nvidia /usr/share/nvidia
  append_mount_if_exists args /usr/share/vulkan /usr/share/vulkan
  append_mount_if_exists args /tmp/argus_socket /tmp/argus_socket
  append_mount_if_exists args /etc/enctune.conf /etc/enctune.conf
  append_mount_if_exists args /etc/nv_tegra_release /etc/nv_tegra_release
  append_mount_if_exists args /var/run/dbus /var/run/dbus
  append_mount_if_exists args /var/run/avahi-daemon/socket /var/run/avahi-daemon/socket
  append_mount_if_exists args /var/run/docker.sock /var/run/docker.sock
  append_mount_if_exists args /run/user/1000/pulse /run/user/1000/pulse
  append_device_if_exists args /dev/dri
  append_device_if_exists args /dev/snd
  append_device_if_exists args /dev/bus/usb
  for dev in /dev/i2c-0 /dev/i2c-1 /dev/i2c-2 /dev/i2c-4 /dev/i2c-5 /dev/i2c-7; do
    append_device_if_exists args "$dev"
  done

  case "$DEXECHAIN_USE_GPU" in
    auto)
      if docker_has_nvidia_runtime; then
        args+=(--runtime nvidia)
        args+=(-e NVIDIA_DRIVER_CAPABILITIES=all -e NVIDIA_VISIBLE_DEVICES=all -e NVIDIA_DISABLE_REQUIRE=1)
      else
        warn "未检测到 nvidia 容器运行时，DexEChain 处理容器将不启用 GPU。"
      fi
      ;;
    1|true|TRUE|yes|YES|on|ON)
      docker_has_nvidia_runtime || die "DEXECHAIN_USE_GPU=true，但未检测到 nvidia 容器运行时。"
      args+=(--runtime nvidia)
      args+=(-e NVIDIA_DRIVER_CAPABILITIES=all -e NVIDIA_VISIBLE_DEVICES=all -e NVIDIA_DISABLE_REQUIRE=1)
      ;;
    *) ;;
  esac

  info "启动 DexEChain 处理容器：$DEXECHAIN_CONTAINER_NAME"
  docker run -it -d "${args[@]}" "$image" bash -lc "sleep infinity"
  install_or_verify
  ok "DexEChain 处理容器已启动"
}

ensure_python_env(){
  if docker exec -e DEXECHAIN_PYTHON="$DEXECHAIN_PYTHON" "$DEXECHAIN_CONTAINER_NAME" bash -lc '
      test -x "$DEXECHAIN_PYTHON"
      "$DEXECHAIN_PYTHON" -m pip --version >/dev/null 2>&1
    '; then
    return 0
  fi
  die "容器内 py310 环境不可用或缺少 pip：$DEXECHAIN_PYTHON"
}

install_or_verify(){
  if ! truthy "$DEXECHAIN_INSTALL_ON_START"; then
    return 0
  fi
  ensure_python_env
  if verify_imports; then
    ok "容器内 DexEChain/HDF5/UniVis 基础依赖可 import"
    return 0
  fi

  info "容器内补最小 UniVis 运行依赖：$DEXECHAIN_BOOTSTRAP_PACKAGES"
  docker exec \
    -e DEXECHAIN_PYTHON="$DEXECHAIN_PYTHON" \
    -e DEXECHAIN_BOOTSTRAP_PACKAGES="$DEXECHAIN_BOOTSTRAP_PACKAGES" \
    "$DEXECHAIN_CONTAINER_NAME" bash -lc '
      set -e
      "$DEXECHAIN_PYTHON" -m pip install $DEXECHAIN_BOOTSTRAP_PACKAGES
    '
  if verify_imports; then
    ok "DexEChain/UniVis 最小依赖补齐"
    return 0
  fi

  if ! truthy "$DEXECHAIN_FALLBACK_EDITABLE_INSTALL"; then
    die "最小依赖安装后仍无法 import UniVis；如需完整安装，设置 DEXECHAIN_FALLBACK_EDITABLE_INSTALL=true。"
  fi

  info "最小依赖不足，fallback：pip install -e $DEXECHAIN_PIP_TARGET"
  docker exec \
    -e DEXECHAIN_PYTHON="$DEXECHAIN_PYTHON" \
    -e DEXECHAIN_PIP_TARGET="$DEXECHAIN_PIP_TARGET" \
    -e DEXECHAIN_PIP_INDEX_ARGS="$DEXECHAIN_PIP_INDEX_ARGS" \
    "$DEXECHAIN_CONTAINER_NAME" bash -lc '
      set -e
      cd /root/workspace/embodichain
      "$DEXECHAIN_PYTHON" -m pip install -e "$DEXECHAIN_PIP_TARGET" $DEXECHAIN_PIP_INDEX_ARGS
    '
  verify_imports || die "完整安装后仍无法 import DexEChain/UniVis。"
  ok "DexEChain fallback 安装完成"
}

verify_imports(){
  docker exec -e DEXECHAIN_PYTHON="$DEXECHAIN_PYTHON" "$DEXECHAIN_CONTAINER_NAME" bash -lc '
      "$DEXECHAIN_PYTHON" - <<PY
import dexechain, cv2, h5py, h5ffmpeg
import fastapi, uvicorn, multipart
import univis.app
print("dexechain env ok")
PY
    ' >/dev/null 2>&1
}

start_univis(){
  start_container
  mkdir -p "$(dirname "$UNIVIS_LOG")" "$UNIVIS_OUTPUT_DIR"
  if docker exec -e UNIVIS_PORT="$UNIVIS_PORT" "$DEXECHAIN_CONTAINER_NAME" bash -lc 'ps -eo args | grep "[u]nivis.app" | grep -q -- "--port $UNIVIS_PORT"'; then
    ok "UniVis 已在运行：http://127.0.0.1:$UNIVIS_PORT"
    return 0
  fi
  info "启动 UniVis：http://127.0.0.1:$UNIVIS_PORT"
  docker exec -d \
    -e DATA_DIR="$DATA_DIR" \
    -e UNIVIS_PORT="$UNIVIS_PORT" \
    -e UNIVIS_OUTPUT_DIR="$UNIVIS_OUTPUT_DIR" \
    -e UNIVIS_LOG="$UNIVIS_LOG" \
    -e HDF5_WORKFLOW_DIR="$HDF5_WORKFLOW_DIR" \
    -e DEXECHAIN_PYTHON="$DEXECHAIN_PYTHON" \
    "$DEXECHAIN_CONTAINER_NAME" bash -lc '
      cd /root/workspace/embodichain
      export UNIVIS_PYTHON="$DEXECHAIN_PYTHON"
      export PATH="$(dirname "$DEXECHAIN_PYTHON"):$PATH"
      mkdir -p "$(dirname "$UNIVIS_LOG")" "$UNIVIS_OUTPUT_DIR"
      nohup bash tools/univis/run.sh \
        --host 0.0.0.0 \
        --port "$UNIVIS_PORT" \
        --workspace "raw=$DATA_DIR" \
        --workspace "hdf5=$HDF5_WORKFLOW_DIR" \
        --output "$UNIVIS_OUTPUT_DIR" \
        > "$UNIVIS_LOG" 2>&1 &
    '
  ok "UniVis 启动命令已提交，日志：$UNIVIS_LOG"
}

stop_univis(){
  if ! container_running; then
    ok "DexEChain 处理容器未运行，无需停止 UniVis。"
    return 0
  fi
  docker exec -e UNIVIS_PORT="$UNIVIS_PORT" "$DEXECHAIN_CONTAINER_NAME" bash -lc '
    ps -eo pid,args | awk -v port="$UNIVIS_PORT" '\''/python .*univis[.]app/ && $0 ~ "--port " port { print $1 }'\'' | xargs -r kill
  '
  ok "UniVis 已停止。"
}

restart_univis(){
  stop_univis
  start_univis
}

run_workflow(){
  [ $# -ge 1 ] || die "缺少 workflow YAML 路径。用法：bash start_dexechain_tools.sh workflow /path/to/umi_workflow.yaml"
  start_container
  local tty_arg
  tty_arg="$(docker_tty_args)"
  docker exec $tty_arg \
    -e DEXECHAIN_PYTHON="$DEXECHAIN_PYTHON" \
    -e HOST_UID="$(id -u)" \
    -e HOST_GID="$(id -g)" \
    "$DEXECHAIN_CONTAINER_NAME" bash -lc '
    set +e
    cd /root/workspace/embodichain
    "$DEXECHAIN_PYTHON" -m dexechain.data.scripts.umi2hdf5.workflow "$@"
    status=$?
    if [ "$status" -eq 0 ]; then
      output_dir="$("$DEXECHAIN_PYTHON" - "$1" <<PY
import sys
from pathlib import Path
import yaml
with Path(sys.argv[1]).open("r", encoding="utf-8") as file:
    config = yaml.safe_load(file) or {}
print(config.get("output_dir", ""))
PY
)"
      if [ -n "$output_dir" ] && [ -e "$output_dir" ]; then
        chown -R "$HOST_UID:$HOST_GID" "$output_dir" 2>/dev/null || true
      fi
    fi
    exit "$status"
  ' _ "$@"
}

run_quick_workflow(){
  [ $# -ge 3 ] || die "内部参数错误：run_quick_workflow 缺少 BASE_CONFIG、OUTPUT_DIR 或 workflow 参数。"
  local base_config=$1
  local output_dir=$2
  shift 2
  start_container
  local tty_arg signal_file status
  tty_arg="$(docker_tty_args)"
  signal_file="$output_dir/.raw2hdf5.$$.pgid"
  if run_with_workflow_signal_forwarding "$signal_file" docker exec $tty_arg \
    -e DEXECHAIN_PYTHON="$DEXECHAIN_PYTHON" \
    -e HOST_UID="$(id -u)" \
    -e HOST_GID="$(id -g)" \
    -e WORKFLOW_OUTPUT_DIR="$output_dir" \
    -e WORKFLOW_PID_FILE="$signal_file" \
    -e EMBODICHAIN_BRANCH="$EMBODICHAIN_BRANCH" \
    "$DEXECHAIN_CONTAINER_NAME" setsid --wait bash -lc '
    workflow_pgid="$(ps -o pgid= -p "$$" | tr -d "[:space:]")"
    if [[ ! "$workflow_pgid" =~ ^[0-9]+$ ]]; then
      echo "ERROR: cannot determine workflow process group" >&2
      exit 124
    fi
    printf "%s\n" "$workflow_pgid" > "$WORKFLOW_PID_FILE" || {
      echo "ERROR: cannot write workflow process group: $WORKFLOW_PID_FILE" >&2
      exit 123
    }
    script=/root/workspace/embodichain/dexechain/data/scripts/umi2hdf5/run_workflow.sh
    if [ ! -f "$script" ]; then
      echo "ERROR: EmbodiChain quick workflow script not found: $script" >&2
      echo "ERROR: expected EmbodiChain branch: $EMBODICHAIN_BRANCH" >&2
      exit 127
    fi
    if [ ! -x "$script" ]; then
      echo "ERROR: EmbodiChain quick workflow script is not executable: $script" >&2
      exit 126
    fi
    cd /root/workspace/embodichain || {
      echo "ERROR: cannot enter EmbodiChain repository" >&2
      exit 125
    }
    set +e
    "$script" "$@"
    status=$?
    exit "$status"
  ' _ "$base_config" "$@"; then
    status=0
  else
    status=$?
  fi
  if ! docker exec \
    -e HOST_UID="$(id -u)" \
    -e HOST_GID="$(id -g)" \
    "$DEXECHAIN_CONTAINER_NAME" bash -lc '
      if [ -e "$1" ]; then
        chown -R "$HOST_UID:$HOST_GID" "$1"
      fi
    ' _ "$output_dir"; then
    warn "无法恢复 workflow 输出目录归属：$output_dir"
  fi
  return "$status"
}

run_raw_to_hdf5(){
  [ $# -ge 1 ] || die "缺少 raw batch 或 episode 路径。用法：bash start_dexechain_tools.sh raw2hdf5 /path/to/raw_batch [output_dir]"
  local input_path output_dir
  input_path="$(realpath -m -- "$1")"
  [ -d "$input_path" ] || die "raw 路径不存在或不是目录：$input_path"
  output_dir="${2:-$(default_raw2hdf5_output_dir "$input_path")}"
  output_dir="$(realpath -m -- "$output_dir")"
  if [ $# -ge 3 ]; then
    die "raw2hdf5 不接受第 3 个位置参数；头相机格式由 HEAD_CAMERA_DRIVER 映射。"
  fi

  local workflow_args=(--input "$input_path" --output-dir "$output_dir")
  case "$HEAD_CAMERA_DRIVER" in
    kfcv2) workflow_args+=(--head-camera-format kfcv2) ;;
    orbbec|none) workflow_args+=(--head-camera-format null) ;;
    *) die "无法映射 HEAD_CAMERA_DRIVER=$HEAD_CAMERA_DRIVER；只允许 kfcv2、orbbec 或 none。" ;;
  esac

  info "调用 EmbodiChain quick workflow：$RAW2HDF5_BASE_CONFIG"
  info "头相机映射：HEAD_CAMERA_DRIVER=$HEAD_CAMERA_DRIVER"
  run_quick_workflow "$RAW2HDF5_BASE_CONFIG" "$output_dir" "${workflow_args[@]}"

  local hdf5_count=0
  if [ -d "$output_dir" ]; then
    hdf5_count="$(find "$output_dir" -mindepth 2 -maxdepth 2 -type f \( -name '*.hdf5' -o -name '*.h5' \) | wc -l)"
  fi
  if [ "$hdf5_count" -gt 0 ]; then
    ok "HDF5 输出目录：$output_dir/<batch>（$hdf5_count 个文件）"
  else
    warn "workflow 已结束但未发布 HDF5；请检查 $output_dir/workflow.log。"
  fi
  ok "workflow 配置：$output_dir/umi_workflow.yaml"
  ok "预检报告目录：$output_dir/stages/raw_checker"
}

default_raw2hdf5_output_dir(){
  local input_path=$1
  local timestamp name parent batch data_root
  timestamp="$(date +%Y%m%d_%H%M%S)"
  name="$(basename -- "$input_path")"
  parent="$(basename -- "$(dirname -- "$input_path")")"
  data_root="$(realpath -m -- "$DATA_DIR")"
  if [[ "$name" == episode* ]]; then
    batch="$parent"
    printf '%s/%s_%s_%s\n' "$HDF5_WORKFLOW_DIR" "$batch" "$name" "$timestamp"
  elif [[ "$input_path" == "$data_root"/* ]]; then
    printf '%s/%s_%s\n' "$HDF5_WORKFLOW_DIR" "$name" "$timestamp"
  else
    printf '%s/%s_%s\n' "$HDF5_WORKFLOW_DIR" "$name" "$timestamp"
  fi
}

show_status(){
  if container_running; then
    ok "容器运行中：$DEXECHAIN_CONTAINER_NAME"
  elif container_exists; then
    warn "容器存在但未运行：$DEXECHAIN_CONTAINER_NAME"
  else
    warn "容器不存在：$DEXECHAIN_CONTAINER_NAME"
  fi
  echo "EmbodiChain: $EMBODICHAIN_DIR"
  echo "Raw data   : $DATA_DIR"
  echo "Workflow   : $HDF5_WORKFLOW_DIR"
  echo "Python     : $DEXECHAIN_PYTHON"
  echo "UniVis     : http://127.0.0.1:$UNIVIS_PORT"
}

usage(){
  cat <<EOF
用法：
  bash $0 start                         启动 DexEChain 处理容器
  bash $0 univis                        启动容器并后台启动 UniVis
  bash $0 restart-univis                重启 UniVis 并刷新 workspace
  bash $0 raw2hdf5 RAW [OUT]            调用 EmbodiChain quick workflow：raw_checker + raw_to_hdf5
  bash $0 workflow /path/to/config.yaml 启动容器并运行 UMI workflow
  bash $0 shell                         进入处理容器
  bash $0 status                        查看状态
  bash $0 stop                          停止处理容器

配置来自：$CONFIG_FILE
raw2hdf5 基础配置：$RAW2HDF5_BASE_CONFIG
EmbodiChain 分支：$EMBODICHAIN_BRANCH
EOF
}

cmd="${1:-start}"
shift || true
case "$cmd" in
  start) start_container ;;
  univis) start_univis ;;
  restart-univis) restart_univis ;;
  raw2hdf5|raw-to-hdf5) run_raw_to_hdf5 "$@" ;;
  workflow) run_workflow "$@" ;;
  shell)
    start_container
    docker exec -it "$DEXECHAIN_CONTAINER_NAME" bash
    ;;
  status) show_status ;;
  stop)
    docker stop "$DEXECHAIN_CONTAINER_NAME" >/dev/null 2>&1 || true
    ok "已停止：$DEXECHAIN_CONTAINER_NAME"
    ;;
  -h|--help|help) usage ;;
  *) usage; die "未知命令：$cmd" ;;
esac
