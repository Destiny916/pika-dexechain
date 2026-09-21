#!/bin/bash
# =============================================================================
# Pika 迁移 · 软件轨一键安装
# -----------------------------------------------------------------------------
# 作用：把「PIKA 采集镜像 + 项目目录 + 容器配置」一次性落到新机器；
#      并按配置启动 DexEChain HDF5/UniVis 工具容器。
# 不做：任何物理相关的事（USB 绑定 / 基站校准 / 左右手）——那些走 setup_hardware.sh。
#
# 用法：  bash migrate_software.sh [--reinstall]
# 特性：  默认安装；--reinstall 清理可重建的软件环境后全新安装。
# =============================================================================
set -uo pipefail

REINSTALL=false
case "${1:-}" in
  "") ;;
  --reinstall) REINSTALL=true ;;
  -h|--help)
    echo "用法：bash migrate_software.sh [--reinstall]"
    echo "  --reinstall  删除可重建的软件环境，保留采集数据和 EmbodiChain 仓库，再全新安装"
    exit 0
    ;;
  *)
    echo "未知参数：$1" >&2
    echo "用法：bash migrate_software.sh [--reinstall]" >&2
    exit 2
    ;;
esac
[ "$#" -le 1 ] || { echo "参数过多。用法：bash migrate_software.sh [--reinstall]" >&2; exit 2; }

# tar 包默认与本脚本同目录（即整个 pika-migrate/）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/pika_migrate.conf}"
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

# ---- 可调参数（优先从 pika_migrate.conf 读取）-------------------------------
PIKA_USER="${PIKA_USER:-kw}"
HOST_HOME="${HOST_HOME:-/home/kw}"
APP_DIR="${APP_DIR:-$HOST_HOME/app}"           # 项目根目录（容器内外同路径）
PIKA_DIR="${PIKA_DIR:-$APP_DIR/pika}"
PIKA_MIGRATE_DIR="${PIKA_MIGRATE_DIR:-$APP_DIR/pika-migrate}"
AGILEX_DIR="${AGILEX_DIR:-$HOST_HOME/agilex}"
DATA_DIR="${DATA_DIR:-$AGILEX_DIR/data}"
IMAGE_NAME="${IMAGE_NAME:-pika:humble}"
CONTAINER_NAME="${CONTAINER_NAME:-pika}"
ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-42}"
USE_GPU="${USE_GPU:-false}"
HEAD_CAMERA_DRIVER="${HEAD_CAMERA_DRIVER:-kfcv2}"
HEAD_CAMERA_DEVICE="${HEAD_CAMERA_DEVICE:-/dev/kfcv2-camera}"
HEAD_CAMERA_WIDTH="${HEAD_CAMERA_WIDTH:-3840}"
HEAD_CAMERA_HEIGHT="${HEAD_CAMERA_HEIGHT:-1080}"
HEAD_CAMERA_FPS="${HEAD_CAMERA_FPS:-30}"
HEAD_CAMERA_MIN_FPS="${HEAD_CAMERA_MIN_FPS:-25}"
HEAD_CAMERA_EYE="${HEAD_CAMERA_EYE:-left}"
HEAD_CAMERA_INPUT_TOPIC="${HEAD_CAMERA_INPUT_TOPIC:-/camera/kfc_compressed}"
KFC_ALIGN_BEFORE_CAPTURE="${KFC_ALIGN_BEFORE_CAPTURE:-true}"
KFC_ALIGN_REFERENCE_DIR="${KFC_ALIGN_REFERENCE_DIR:-$AGILEX_DIR/kfc_reference}"
KFC_ALIGN_FPS="${KFC_ALIGN_FPS:-5}"
CAPTURE_HZ="${CAPTURE_HZ:-}"
ENABLE_HDF5_CONVERT="${ENABLE_HDF5_CONVERT:-false}"
HDF5_CONVERT_SCRIPT="${HDF5_CONVERT_SCRIPT:-}"
ENABLE_DEXECHAIN_TOOLS="${ENABLE_DEXECHAIN_TOOLS:-true}"
START_UNIVIS_AFTER_MIGRATE="${START_UNIVIS_AFTER_MIGRATE:-false}"
DEXECHAIN_CONTAINER_NAME="${DEXECHAIN_CONTAINER_NAME:-dexechain-tools}"
DEXECHAIN_WORKSPACE="${DEXECHAIN_WORKSPACE:-$HOST_HOME/workspace}"
EMBODICHAIN_DIR="${EMBODICHAIN_DIR:-$DEXECHAIN_WORKSPACE/embodichain}"
EMBODICHAIN_REPO_URL="${EMBODICHAIN_REPO_URL:-http://192.168.3.16/Engine/embodichain}"
EMBODICHAIN_BRANCH="${EMBODICHAIN_BRANCH:-umi_gift}"
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
HDF5_WORKFLOW_DIR="${HDF5_WORKFLOW_DIR:-$AGILEX_DIR/hdf5_workflow}"
RAW2HDF5_BASE_CONFIG="${RAW2HDF5_BASE_CONFIG:-precheck_raw_to_hdf5}"
UNIVIS_PORT="${UNIVIS_PORT:-8010}"
UNIVIS_OUTPUT_DIR="${UNIVIS_OUTPUT_DIR:-$AGILEX_DIR/hdf5_out}"
UNIVIS_LOG="${UNIVIS_LOG:-$AGILEX_DIR/log/univis.log}"
MIN_FREE_GB=8                                  # 解压+载镜像所需最小空闲
HARDWARE_ENV="$PIKA_DIR/pika_hardware.env"
PRESERVED_HARDWARE_ENV=""

IMAGE_TAR="${IMAGE_TAR:-$SCRIPT_DIR/pika-image.tar.gz}"
PROJECT_TAR="${PROJECT_TAR:-$SCRIPT_DIR/pika-project.tar.gz}"

# ---- 输出小工具 ------------------------------------------------------------
c_g='\033[32m'; c_r='\033[31m'; c_y='\033[33m'; c_b='\033[36m'; c_0='\033[0m'
info(){ echo -e "${c_b}▸${c_0} $*"; }
ok(){   echo -e "${c_g}✅ $*${c_0}"; }
warn(){ echo -e "${c_y}⚠️  $*${c_0}"; }
err(){  echo -e "${c_r}❌ $*${c_0}" >&2; }
die(){  err "$*"; echo; err "已中止。修好上面的问题再重跑本脚本即可（脚本幂等）。"; exit 1; }
step(){ echo; echo -e "${c_b}━━ $* ━━${c_0}"; }
truthy(){
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

validate_reinstall_targets(){
  local resolved_pika resolved_app resolved_migrate resolved_agilex resolved_repo
  resolved_pika="$(realpath -m -- "$PIKA_DIR")"
  resolved_app="$(realpath -m -- "$APP_DIR")"
  resolved_migrate="$(realpath -m -- "$PIKA_MIGRATE_DIR")"
  resolved_agilex="$(realpath -m -- "$AGILEX_DIR")"
  resolved_repo="$(realpath -m -- "$EMBODICHAIN_DIR")"

  [ "$resolved_pika" != "/" ] || die "拒绝重装：PIKA_DIR 不能是 /"
  [ "$resolved_pika" != "$resolved_app" ] || die "拒绝重装：PIKA_DIR 不能等于 APP_DIR"
  [ "$resolved_pika" != "$resolved_migrate" ] || die "拒绝重装：PIKA_DIR 不能等于迁移包目录"
  [ "$resolved_pika" != "$resolved_agilex" ] || die "拒绝重装：PIKA_DIR 不能等于 AGILEX_DIR"
  [ "$resolved_pika" != "$resolved_repo" ] || die "拒绝重装：PIKA_DIR 不能等于 EmbodiChain 仓库"
  case "$resolved_pika/" in
    "$resolved_app"/*) ;;
    *) die "拒绝重装：PIKA_DIR 必须位于 APP_DIR 内（$resolved_app）" ;;
  esac
}

reinstall_cleanup(){
  local answer
  validate_reinstall_targets

  step "重装确认（删除后不自动备份）"
  warn "将永久删除以下可重建的软件环境："
  echo "  - PIKA 容器：$CONTAINER_NAME"
  echo "  - DexEChain 工具容器：$DEXECHAIN_CONTAINER_NAME"
  echo "  - PIKA 项目目录及其中配置/校准：$PIKA_DIR"
  echo "  - PIKA Docker 镜像：$IMAGE_NAME"
  echo
  ok "明确保留："
  echo "  - 全部 Agilex 数据：$AGILEX_DIR"
  echo "  - EmbodiChain 仓库：$EMBODICHAIN_DIR"
  echo "  - DexEChain 基础镜像、迁移包、硬件 udev 规则与 pika_hardware.env"
  echo
  [ -t 0 ] || die "--reinstall 必须在交互式终端中确认，未执行任何删除。"
  read -rp "请输入 REINSTALL 确认删除并重装（其他输入取消）: " answer || answer=""
  if [ "$answer" != "REINSTALL" ]; then
    warn "已取消重装，未删除任何内容。"
    exit 0
  fi

  info "删除 PIKA 和 DexEChain 工具容器..."
  docker rm -f "$CONTAINER_NAME" "$DEXECHAIN_CONTAINER_NAME" >/dev/null 2>&1 || true

  if docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
    info "删除 PIKA 镜像：$IMAGE_NAME"
    docker image rm "$IMAGE_NAME" >/dev/null || die "无法删除镜像 $IMAGE_NAME；可能仍被其他容器引用。"
  fi

  if [ -f "$HARDWARE_ENV" ]; then
    bash -n "$HARDWARE_ENV" || die "现有硬件配置语法无效，拒绝重装：$HARDWARE_ENV"
    PRESERVED_HARDWARE_ENV=$(mktemp "$SCRIPT_DIR/.pika_hardware.env.reinstall.XXXXXX") || die "无法暂存硬件配置"
    cp -a "$HARDWARE_ENV" "$PRESERVED_HARDWARE_ENV" || die "暂存硬件配置失败"
    ok "已暂存硬件配置，项目解压后自动恢复。"
  fi

  if [ -e "$PIKA_DIR" ]; then
    info "删除 PIKA 项目目录：$PIKA_DIR"
    rm -rf -- "$PIKA_DIR" || die "删除 PIKA 项目目录失败：$PIKA_DIR"
  fi

  ok "软件环境清理完成；Agilex 数据和 EmbodiChain 仓库均已保留。"
}

warn_if_existing_install(){
  local -a found=()
  local answer

  [ -e "$PIKA_DIR" ] && found+=("PIKA 项目目录：$PIKA_DIR")
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
    found+=("PIKA 容器：$CONTAINER_NAME")
  fi
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$DEXECHAIN_CONTAINER_NAME"; then
    found+=("DexEChain 工具容器：$DEXECHAIN_CONTAINER_NAME")
  fi
  if docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
    found+=("PIKA 镜像：$IMAGE_NAME")
  fi
  [ "${#found[@]}" -gt 0 ] || return 0

  echo
  warn "检测到已有安装环境；无参数模式会复用旧内容，结果可能不是标准全新安装。"
  printf '  - %s\n' "${found[@]}"
  echo
  warn "标准做法：取消本次运行，然后执行："
  echo "  bash $SCRIPT_DIR/migrate_software.sh --reinstall"
  echo "  （会保留 $AGILEX_DIR 和 $EMBODICHAIN_DIR）"
  echo
  if [ ! -t 0 ]; then
    die "非空白环境下无参数安装已停止；请使用 --reinstall。"
  fi
  read -rp "仍要复用现有环境继续吗？[y/N]: " answer || answer=""
  case "$answer" in
    y|Y|yes|YES|Yes) warn "已选择继续复用现有环境。" ;;
    *) warn "已取消，未做安装修改。请改用 --reinstall。"; exit 0 ;;
  esac
}

write_runtime_config(){
  mkdir -p "$PIKA_DIR"
  cat > "$PIKA_DIR/pika_runtime.env" <<EOF
# Generated by migrate_software.sh from $CONFIG_FILE.
export PIKA_USER="$PIKA_USER"
export HOST_HOME="$HOST_HOME"
export APP_DIR="$APP_DIR"
export PIKA_DIR="$PIKA_DIR"
export PIKA_MIGRATE_DIR="$PIKA_MIGRATE_DIR"
export AGILEX_DIR="$AGILEX_DIR"
export DATA_DIR="$DATA_DIR"
export IMAGE_NAME="$IMAGE_NAME"
export CONTAINER_NAME="$CONTAINER_NAME"
export ROS_DOMAIN_ID="$ROS_DOMAIN_ID"
export USE_GPU="$USE_GPU"
export HEAD_CAMERA_DRIVER="$HEAD_CAMERA_DRIVER"
export HEAD_CAMERA_DEVICE="$HEAD_CAMERA_DEVICE"
export HEAD_CAMERA_WIDTH="$HEAD_CAMERA_WIDTH"
export HEAD_CAMERA_HEIGHT="$HEAD_CAMERA_HEIGHT"
export HEAD_CAMERA_FPS="$HEAD_CAMERA_FPS"
export HEAD_CAMERA_MIN_FPS="$HEAD_CAMERA_MIN_FPS"
export HEAD_CAMERA_EYE="$HEAD_CAMERA_EYE"
export HEAD_CAMERA_INPUT_TOPIC="$HEAD_CAMERA_INPUT_TOPIC"
export KFC_ALIGN_BEFORE_CAPTURE="$KFC_ALIGN_BEFORE_CAPTURE"
export KFC_ALIGN_REFERENCE_DIR="$KFC_ALIGN_REFERENCE_DIR"
export KFC_ALIGN_FPS="$KFC_ALIGN_FPS"
export CAPTURE_HZ="$CAPTURE_HZ"
export ENABLE_HDF5_CONVERT="$ENABLE_HDF5_CONVERT"
export HDF5_CONVERT_SCRIPT="$HDF5_CONVERT_SCRIPT"
export ENABLE_DEXECHAIN_TOOLS="$ENABLE_DEXECHAIN_TOOLS"
export START_UNIVIS_AFTER_MIGRATE="$START_UNIVIS_AFTER_MIGRATE"
export DEXECHAIN_CONTAINER_NAME="$DEXECHAIN_CONTAINER_NAME"
export DEXECHAIN_WORKSPACE="$DEXECHAIN_WORKSPACE"
export EMBODICHAIN_DIR="$EMBODICHAIN_DIR"
export EMBODICHAIN_REPO_URL="$EMBODICHAIN_REPO_URL"
export EMBODICHAIN_BRANCH="$EMBODICHAIN_BRANCH"
export DEXECHAIN_IMAGE_X86_64="$DEXECHAIN_IMAGE_X86_64"
export DEXECHAIN_IMAGE_AARCH64="$DEXECHAIN_IMAGE_AARCH64"
export DEXECHAIN_IMAGE="$DEXECHAIN_IMAGE"
export DEXECHAIN_USE_GPU="$DEXECHAIN_USE_GPU"
export DEXECHAIN_PYTHON="$DEXECHAIN_PYTHON"
export DEXECHAIN_INSTALL_ON_START="$DEXECHAIN_INSTALL_ON_START"
export DEXECHAIN_BOOTSTRAP_PACKAGES="$DEXECHAIN_BOOTSTRAP_PACKAGES"
export DEXECHAIN_FALLBACK_EDITABLE_INSTALL="$DEXECHAIN_FALLBACK_EDITABLE_INSTALL"
export DEXECHAIN_PIP_TARGET="$DEXECHAIN_PIP_TARGET"
export DEXECHAIN_PIP_INDEX_ARGS="$DEXECHAIN_PIP_INDEX_ARGS"
export HDF5_WORKFLOW_DIR="$HDF5_WORKFLOW_DIR"
export RAW2HDF5_BASE_CONFIG="$RAW2HDF5_BASE_CONFIG"
export UNIVIS_PORT="$UNIVIS_PORT"
export UNIVIS_OUTPUT_DIR="$UNIVIS_OUTPUT_DIR"
export UNIVIS_LOG="$UNIVIS_LOG"
EOF
}

patch_project_paths(){
  info "按配置修复项目默认/构建路径"
  local files
  files=$(find "$PIKA_DIR" -type f \
    ! -path '*/.git/*' \
    ! -path '*/__pycache__/*' \
    ! -path '*/build/*' \
    ! -path '*/install/*' \
    ! -path '*/log/*' \
    ! -name '*.pyc' \
    ! -name '*.so' \
    ! -name '*.a' \
    ! -name '*.zip' \
    ! -name '*.tar' \
    ! -name '*.gz' \
    \( -exec grep -Il '/home/dex' {} + -o -exec grep -Il '/home/ppn/pika_ros' {} + \) 2>/dev/null)
  [ -n "$files" ] || return 0
  printf '%s\n' "$files" | sort -u | xargs -r sed -i \
    -e "s#/home/dex#$HOST_HOME#g" \
    -e "s#/home/ppn/pika_ros#$PIKA_DIR/pika_ros#g"
}

install_usb_runtime_payload(){
  local payload="$SCRIPT_DIR/payload/pika" rel
  local executable_files=(
    docker_run.sh
    pika_ros/scripts/start_collect.sh
    pika_ros/scripts/start_multi_sensor.bash
    pika_ros/src/sensor_tools/scripts/kfcv2_usb_publisher.py
  )
  local data_files=(
    pika_ros/src/sensor_tools/CMakeLists.txt
    pika_ros/src/sensor_tools/package.xml
    pika_ros/src/sensor_tools/launch/open_multi_sensor.launch.py
  )

  [ -d "$payload" ] || die "缺少 USB 运行文件：$payload"
  for rel in "${executable_files[@]}"; do
    [ -f "$payload/$rel" ] || die "缺少 USB 运行文件：$payload/$rel"
    install -D -m 0755 "$payload/$rel" "$PIKA_DIR/$rel" || return 1
  done
  for rel in "${data_files[@]}"; do
    [ -f "$payload/$rel" ] || die "缺少 USB 运行文件：$payload/$rel"
    install -D -m 0644 "$payload/$rel" "$PIKA_DIR/$rel" || return 1
  done
}

install_kfc_alignment_integration(){
  local source_dir target_dir collect_script anchor_count
  source_dir="$SCRIPT_DIR/tools/kfc_alignment"
  target_dir="$PIKA_DIR/pika_ros/scripts/kfc"
  collect_script="$PIKA_DIR/pika_ros/scripts/start_collect.sh"

  [ -f "$source_dir/align_kfc_camera.py" ] || die "缺少 KFCv2 对齐工具：$source_dir/align_kfc_camera.py"
  [ -f "$source_dir/align_before_capture.sh" ] || die "缺少 KFCv2 启动助手：$source_dir/align_before_capture.sh"
  [ -f "$collect_script" ] || die "缺少标准采集入口：$collect_script"

  mkdir -p "$target_dir" || return 1
  install -m 0755 "$source_dir/align_kfc_camera.py" "$target_dir/align_kfc_camera.py" || return 1

  if ! grep -qF '# >>> pika-migrate: KFCv2 alignment >>>' "$collect_script"; then
    anchor_count="$(grep -c '^  # ans 作为位置参数' "$collect_script" || true)"
    [ "$anchor_count" = "1" ] || die "无法安全接入 KFCv2 对齐：start_collect.sh 锚点数量=$anchor_count"
    python3 - "$collect_script" <<'PY'
import os
import sys
import tempfile
from pathlib import Path

target = Path(sys.argv[1])
anchor = "  # ans 作为位置参数"
block = '''  # >>> pika-migrate: KFCv2 alignment >>>
  if [ "$HEAD_CAMERA_DRIVER" = "kfcv2" ]; then
    KFC_ALIGN_TOPIC="${HEAD_CAMERA_INPUT_TOPIC:-/camera/kfc_compressed}" bash "$PIKA_MIGRATE_DIR/tools/kfc_alignment/align_before_capture.sh" || {
        warn "KFCv2 画面对齐未完成，取消本次采集。"
        continue
      }
  fi
  # <<< pika-migrate: KFCv2 alignment <<<
'''
original = target.read_text()
if original.count(anchor) != 1:
    raise SystemExit(f"unsafe start_collect.sh anchor count: {original.count(anchor)}")
updated = original.replace(anchor, block + anchor, 1)
mode = target.stat().st_mode
with tempfile.NamedTemporaryFile("w", dir=target.parent, delete=False) as handle:
    temporary = Path(handle.name)
    handle.write(updated)
os.chmod(temporary, mode)
os.replace(temporary, target)
PY
    [ "$?" -eq 0 ] || return 1
  fi

  ok "KFCv2 采集前画面对齐已接入：每次启动采集前弹窗，非 KFCv2 自动跳过"
}

# =============================================================================
[ "$PIKA_USER" = "kw" ] || die "本部署只允许 PIKA_USER=kw"
[ "$HOST_HOME" = "/home/kw" ] || die "本部署只允许 HOST_HOME=/home/kw"
if ! truthy "$REINSTALL"; then
  warn_if_existing_install
fi

step "0/8 前置体检（不满足直接退出，不自动安装）"

command -v docker >/dev/null 2>&1 || die "未找到 docker。装法：curl -fsSL https://get.docker.com | sudo sh"
if ! docker ps >/dev/null 2>&1; then
  die "docker 无法免 sudo 运行。执行：sudo usermod -aG docker \$USER 然后重新登录。"
fi
ok "docker 可用：$(docker --version)"
ok "配置文件：$CONFIG_FILE"
ok "目标用户/路径：PIKA_USER=$PIKA_USER  PIKA_DIR=$PIKA_DIR  DATA_DIR=$DATA_DIR"
ok "头相机配置：driver=$HEAD_CAMERA_DRIVER device=$HEAD_CAMERA_DEVICE ${HEAD_CAMERA_WIDTH}x${HEAD_CAMERA_HEIGHT}@${HEAD_CAMERA_FPS}"
ok "DexEChain 工具容器：enabled=$ENABLE_DEXECHAIN_TOOLS container=$DEXECHAIN_CONTAINER_NAME repo=$EMBODICHAIN_DIR"

case "$USE_GPU" in
  1|true|TRUE|yes|YES|on|ON)
    if [[ "$(docker info --format '{{.Runtimes}}' 2>/dev/null)" == *nvidia* ]]; then
      ok "USE_GPU=true，检测到 nvidia 容器运行时"
    else
      warn "USE_GPU=true，但未检测到 nvidia 容器运行时。docker_run.sh 会用 --gpus all，缺它起容器会失败。"
      warn "装法：sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker"
      die "请先装好 nvidia 容器运行时，或在 pika_migrate.conf 里设置 USE_GPU=false。"
    fi
    ;;
  *)
    ok "USE_GPU=false，跳过 nvidia 容器运行时检查（PIKA raw 采集/KFCv2 不需要 GPU）。"
    ;;
esac

[ -f "$IMAGE_TAR" ]   || die "找不到镜像包：$IMAGE_TAR"
[ -f "$PROJECT_TAR" ] || die "找不到项目包：$PROJECT_TAR"
ok "迁移包就位：$(basename "$IMAGE_TAR") / $(basename "$PROJECT_TAR")"

# 磁盘空闲（检查 APP_DIR 所在分区，目录不存在则退到其父/根）
chk="$APP_DIR"; while [ ! -d "$chk" ] && [ "$chk" != "/" ]; do chk="$(dirname "$chk")"; done
free_gb=$(df -BG --output=avail "$chk" 2>/dev/null | tail -1 | tr -dc '0-9')
if [ -n "$free_gb" ] && [ "$free_gb" -lt "$MIN_FREE_GB" ]; then
  die "磁盘空闲不足：${free_gb}G < ${MIN_FREE_GB}G（$chk）"
fi
ok "磁盘空闲：${free_gb:-?}G"

if truthy "$REINSTALL"; then
  reinstall_cleanup
fi

# =============================================================================
step "1/8 导入 PIKA 采集镜像"
if docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
  ok "$IMAGE_NAME 已存在，跳过导入"
else
  info "正在 docker load（约几分钟）..."
  gunzip -c "$IMAGE_TAR" | docker load || die "镜像导入失败"
  docker image inspect "$IMAGE_NAME" >/dev/null 2>&1 || die "导入后仍找不到 $IMAGE_NAME"
  ok "镜像导入完成"
fi

# =============================================================================
step "2/8 解压 PIKA 项目到 $APP_DIR"
if [ -d "$PIKA_DIR" ]; then
  warn "$PIKA_DIR 已存在，跳过解压（不覆盖现有代码/配置）"
else
  mkdir -p "$APP_DIR"
  info "正在解压项目包..."
  tar xzf "$PROJECT_TAR" -C "$APP_DIR" || die "项目解压失败"
  [ -f "$PIKA_DIR/docker_run.sh" ] || die "解压后缺 docker_run.sh，包可能不完整"
  ok "项目解压完成：$PIKA_DIR"
fi
patch_project_paths || die "项目路径替换失败"
install_usb_runtime_payload || die "安装 KFCv2 USB 运行文件失败"
install_kfc_alignment_integration || die "安装 KFCv2 采集前画面对齐失败"
if [ -n "$PRESERVED_HARDWARE_ENV" ] && [ -f "$PRESERVED_HARDWARE_ENV" ]; then
  install -m 0644 "$PRESERVED_HARDWARE_ENV" "$HARDWARE_ENV" || die "恢复硬件配置失败"
  chown "$PIKA_USER:$PIKA_USER" "$HARDWARE_ENV" 2>/dev/null || true
  rm -f "$PRESERVED_HARDWARE_ENV"
  PRESERVED_HARDWARE_ENV=""
  ok "已恢复硬件配置：$HARDWARE_ENV"
elif [ -f "$HARDWARE_ENV" ]; then
  ok "保留现有硬件配置：$HARDWARE_ENV"
else
  info "尚无 $HARDWARE_ENV；稍后运行 setup_hardware.sh 生成。"
fi
write_runtime_config || die "写运行时配置失败"
ok "运行时配置已写入：$PIKA_DIR/pika_runtime.env"

# =============================================================================
step "3/8 建数据目录"
mkdir -p "$DATA_DIR" && ok "数据目录就绪：$DATA_DIR"

# =============================================================================
step "4/8 校验 KFCv2 USB 运行文件"
[ -f "$PIKA_DIR/pika_ros/src/sensor_tools/scripts/kfcv2_usb_publisher.py" ] || die "缺少 KFCv2 USB publisher"
[ -f "$SCRIPT_DIR/99-kfcv2-head.rules" ] || die "缺少 KFCv2 udev 规则"
[ -f "$SCRIPT_DIR/lib/kfcv2_usb.sh" ] || die "缺少 KFCv2 USB 检测库"
ok "KFCv2 USB 源码、udev 规则和检测库已就位"

# =============================================================================
step "5/8 启动 PIKA 采集容器"
if [ -n "$(docker ps -q -f "name=^${CONTAINER_NAME}$")" ]; then
  ok "容器 $CONTAINER_NAME 已在运行，跳过"
else
  info "运行 docker_run.sh（会重建同名容器、授权 X11）..."
  ( cd "$PIKA_DIR" && bash docker_run.sh ) || die "容器启动失败"
  [ -n "$(docker ps -q -f "name=^${CONTAINER_NAME}$")" ] || die "启动后未见容器在运行"
  ok "容器已启动"
fi

if [ "$HEAD_CAMERA_DRIVER" = "kfcv2" ]; then
  step "5.5/8 安装 KFCv2 USB 依赖并构建 sensor_tools"
  if docker exec "$CONTAINER_NAME" bash -lc 'command -v gst-inspect-1.0 >/dev/null 2>&1 && gst-inspect-1.0 v4l2src >/dev/null 2>&1 && gst-inspect-1.0 appsink >/dev/null 2>&1 && /usr/bin/python3 -c "import gi"'; then
    ok "KFCv2 GStreamer/PyGObject 依赖可用"
  else
    warn "KFCv2 缺少 USB publisher 依赖，正在容器内安装（需要联网）..."
    docker exec "$CONTAINER_NAME" bash -lc '
      set -e
      apt-get update -o Acquire::Retries=3
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        python3-gi gir1.2-gstreamer-1.0 gstreamer1.0-tools \
        gstreamer1.0-plugins-base gstreamer1.0-plugins-good
      gst-inspect-1.0 v4l2src >/dev/null
      gst-inspect-1.0 appsink >/dev/null
      /usr/bin/python3 -c "import gi"
    ' || die "KFCv2 USB 依赖安装失败"
    ok "KFCv2 USB 依赖安装完成"
  fi

  docker exec -e COLCON_CURRENT_PREFIX="$PIKA_DIR/pika_ros/install/data_msgs" "$CONTAINER_NAME" bash -lc '
    set -e
    source /opt/ros/humble/setup.bash
    cd /home/kw/app/pika/pika_ros
    colcon --log-base /tmp/kfcv2-colcon-log build --symlink-install --packages-select sensor_tools
    source install/setup.bash
    ros2 pkg executables sensor_tools | grep -q kfcv2_usb_publisher.py
  ' || die "sensor_tools 构建或 KFCv2 USB publisher 注册失败"
  ok "sensor_tools 已构建并注册 kfcv2_usb_publisher.py"

  if docker exec "$CONTAINER_NAME" bash -c '
      source /opt/ros/humble/setup.bash
      /usr/bin/python3 -c "import cv2, numpy, rclpy; from sensor_msgs.msg import CompressedImage"'; then
    ok "KFCv2 对齐窗口依赖可用（OpenCV / NumPy / ROS 2 Python）"
  else
    die "KFCv2 对齐窗口缺少依赖。容器需提供 python3-opencv、python3-numpy、python3-rclpy 和 ros-humble-sensor-msgs。"
  fi
fi

# =============================================================================
step "6/8 补 PIKA 容器内配置（.bashrc + libsurvive 软链，幂等）"
docker exec "$CONTAINER_NAME" bash -c '
  set -e
  brc=/root/.bashrc
  # 普通行：不存在才追加
  add_line(){ grep -qF "$1" "$brc" || echo "$1" >> "$brc"; }
  # export 行：先删同名旧行再写新值。
  set_export(){ sed -i "/^export $1=/d" "$brc"; echo "export $1=$2" >> "$brc"; }
  PIKA_DIR="'"$PIKA_DIR"'"
  add_line  "source $PIKA_DIR/pika_ros/install/setup.bash"
  add_line  "[ -f $PIKA_DIR/pika_runtime.env ] && source $PIKA_DIR/pika_runtime.env"
  add_line  "[ -f $PIKA_DIR/pika_hardware.env ] && source $PIKA_DIR/pika_hardware.env"
  set_export LD_LIBRARY_PATH "$PIKA_DIR/pika_ros/install/libsurvive/lib:\$LD_LIBRARY_PATH"
  # 校准结果持久化软链（容器重建不丢）
  mkdir -p "$PIKA_DIR/libsurvive_config" /root/.config
  ln -sfn "$PIKA_DIR/libsurvive_config" /root/.config/libsurvive
' && ok "容器配置已写入（LHR 由 pika_hardware.env 提供）" \
  || die "写容器配置失败"

# =============================================================================
step "7/8 验证 PIKA 软件环境"
# 直接 source 两个 setup.bash 来验证 —— 不能用 bash -lc：login shell 不读 ~/.bashrc，
# 会漏掉 install 的 source（日常 docker exec -it pika bash 是交互式 shell，才读 .bashrc）。
if docker exec "$CONTAINER_NAME" bash -c '
    source /opt/ros/humble/setup.bash 2>/dev/null
    source '"$PIKA_DIR"'/pika_ros/install/setup.bash 2>/dev/null
    ros2 pkg list 2>/dev/null | grep -q pika_locator'; then
  ok "ros2 + 项目 install 已加载（找到 pika_locator）"
else
  die "未找到 pika_locator —— install 可能没加载，检查 $PIKA_DIR/pika_ros/install"
fi

if docker exec "$CONTAINER_NAME" bash -c '
    source /opt/ros/humble/setup.bash 2>/dev/null
    source '"$PIKA_DIR"'/pika_ros/install/setup.bash 2>/dev/null
    ros2 pkg executables sensor_tools 2>/dev/null | grep -q kfcv2_usb_publisher.py'; then
  ok "KFCv2 USB 后端可用（找到 kfcv2_usb_publisher.py）"
else
  die "KFCv2 USB 后端不可用（未找到 kfcv2_usb_publisher.py）"
fi

# =============================================================================
step "8/8 启动 DexEChain HDF5/UniVis 处理容器"
if truthy "$ENABLE_DEXECHAIN_TOOLS"; then
  [ -x "$SCRIPT_DIR/start_dexechain_tools.sh" ] || die "找不到或不可执行：$SCRIPT_DIR/start_dexechain_tools.sh"
  CONFIG_FILE="$CONFIG_FILE" bash "$SCRIPT_DIR/start_dexechain_tools.sh" start \
    || die "DexEChain 处理容器启动失败"
  if truthy "$START_UNIVIS_AFTER_MIGRATE"; then
    CONFIG_FILE="$CONFIG_FILE" bash "$SCRIPT_DIR/start_dexechain_tools.sh" univis \
      || die "UniVis 启动失败"
  else
    ok "UniVis 未自动启动；需要时执行：bash $SCRIPT_DIR/start_dexechain_tools.sh univis"
  fi
else
  ok "ENABLE_DEXECHAIN_TOOLS=false，跳过 DexEChain 处理容器。"
fi

# =============================================================================
echo
echo -e "${c_g}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${c_0}"
ok "软件轨迁移完成 🎉"
echo -e "${c_g}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${c_0}"
cat <<EOF

下一步（接上硬件后）：
  bash $SCRIPT_DIR/setup_hardware.sh     # 引导式：USB 绑定 / D405 序列号 / 基站校准

日常使用：
  docker start pika                      # 开机后（别用 docker_run.sh，那是重建会丢配置）
  xhost +local:root
  docker exec -it pika bash

HDF5/UniVis 处理：
  bash $SCRIPT_DIR/start_dexechain_tools.sh univis
  bash $SCRIPT_DIR/start_dexechain_tools.sh raw2hdf5 $DATA_DIR/<task>
  # 默认输出：$HDF5_WORKFLOW_DIR/<task>_YYYYMMDD_HHMMSS
  # 上传/UniVis：<output_dir>/<task>
  bash $SCRIPT_DIR/start_dexechain_tools.sh workflow <output_dir>/umi_workflow.yaml
EOF
