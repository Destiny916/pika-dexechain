#!/usr/bin/env bash
# Runs on PC1/PC2. Installs one verified bundle and atomically switches current.
set -euo pipefail

INSTALL_ROOT="${1:-}"
BUNDLE_ID="${2:-}"
ROLE="${3:-}"
ARCHIVE="${4:-}"

fail(){ echo "❌ $*" >&2; exit 1; }

check_pc2_dependencies(){
  local -a missing=()
  local -a apt_packages=()
  local import_name package_name package
  local -A seen_packages=()

  if ! command -v v4l2-ctl >/dev/null 2>&1; then
    missing+=("命令 v4l2-ctl")
    apt_packages+=("v4l-utils")
  fi
  if ! ros2 pkg prefix compressed_image_transport >/dev/null 2>&1; then
    missing+=("ROS 包 compressed_image_transport")
    apt_packages+=("ros-${ROS_DISTRO}-compressed-image-transport")
  fi

  # These imports are used by the deployed usb_camera.py and compressor workflow.
  while IFS='|' read -r import_name package_name; do
    if ! /usr/bin/python3 -c "import ${import_name}" >/dev/null 2>&1; then
      missing+=("Python 模块 ${import_name}")
      apt_packages+=("${package_name}")
    fi
  done <<EOF
cv2|python3-opencv
rclpy|ros-${ROS_DISTRO}-rclpy
cv_bridge|ros-${ROS_DISTRO}-cv-bridge
sensor_msgs|ros-${ROS_DISTRO}-sensor-msgs
tf2_ros|ros-${ROS_DISTRO}-tf2-ros
geometry_msgs|ros-${ROS_DISTRO}-geometry-msgs
EOF

  if ! /usr/bin/python3 -c 'import numpy, sys; sys.exit(int(numpy.__version__.split(".")[0]) >= 2)' >/dev/null 2>&1; then
    missing+=("Python 模块 NumPy<2")
    apt_packages+=("python3-numpy")
  fi

  if ((${#missing[@]} == 0)); then
    return 0
  fi

  echo "PC2 依赖检查失败，缺少：" >&2
  printf '  - %s\n' "${missing[@]}" >&2
  echo >&2
  echo "请在 PC2 上执行以下命令后重新部署：" >&2
  echo "  sudo apt-get update" >&2
  # Keep the suggestion readable when multiple checks map to one apt package.
  printf '  sudo apt-get install -y'
  for package in "${apt_packages[@]}"; do
    if [[ -z "${seen_packages[$package]+x}" ]]; then
      printf ' %s' "$package"
      seen_packages[$package]=1
    fi
  done
  echo >&2
  if printf '%s\n' "${missing[@]}" | grep -q 'NumPy<2'; then
    echo "  如果安装后 NumPy 仍为 2.x，请检查是否被 pip/conda 覆盖，并确保 /usr/bin/python3 使用 NumPy<2。" >&2
  fi
  return 1
}

case "$ROLE" in pc1|pc2) ;; *) fail "非法角色：$ROLE" ;; esac
[[ "$BUNDLE_ID" =~ ^(pc1|pc2)-[0-9a-f]{12}$ ]] || fail "非法 bundle id：$BUNDLE_ID"
[[ "$INSTALL_ROOT" =~ ^/home/[a-zA-Z0-9._-]+/workspace/pika_w1$ ]] \
  || fail "拒绝安装到非标准目录：$INSTALL_ROOT"
[[ "$ARCHIVE" =~ ^/tmp/pika-w1-(pc1|pc2)-[0-9a-f]{12}\.tar\.gz$ ]] \
  || fail "非法临时包路径：$ARCHIVE"
[ -f "$ARCHIVE" ] || fail "找不到上传包：$ARCHIVE"

command -v tar >/dev/null || fail "目标机缺少 tar"
command -v sha256sum >/dev/null || fail "目标机缺少 sha256sum"

RELEASES="$INSTALL_ROOT/releases"
INCOMING_ROOT="$INSTALL_ROOT/.incoming"
RELEASE="$RELEASES/$BUNDLE_ID"
INCOMING="$INCOMING_ROOT/$BUNDLE_ID.$$"

cleanup(){
  rm -f -- "$ARCHIVE"
  [ ! -e "$INCOMING" ] || rm -rf -- "$INCOMING"
}
trap cleanup EXIT

mkdir -p "$RELEASES" "$INCOMING_ROOT" "$INSTALL_ROOT/logs" "$INSTALL_ROOT/run" "$INSTALL_ROOT/config"
mkdir "$INCOMING"
tar xzf "$ARCHIVE" -C "$INCOMING"
[ -f "$INCOMING/manifest.sha256" ] || fail "部署包缺少 manifest.sha256"
(cd "$INCOMING" && sha256sum -c manifest.sha256 >/dev/null) || fail "部署包 SHA256 校验失败"
grep -qx "ROLE=$ROLE" "$INCOMING/metadata.env" || fail "部署包角色与目标不一致"

case "$ROLE" in
  pc1)
    command -v dpkg-deb >/dev/null || fail "PC1 缺少 dpkg-deb"
    [ "$(dpkg --print-architecture)" = "arm64" ] || fail "PC1 不是 arm64：$(dpkg --print-architecture)"
    [ -f /opt/ros/humble/setup.bash ] || fail "PC1 缺少 ROS 2 Humble"
    deb=("$INCOMING"/payload/*.deb)
    [ "${#deb[@]}" -eq 1 ] && [ -f "${deb[0]}" ] || fail "PC1 部署包必须且只能包含一个 deb"
    [ "$(dpkg-deb -f "${deb[0]}" Architecture)" = "arm64" ] || fail "KFCv2 deb 不是 arm64"
    mkdir -p "$INCOMING/runtime/dexe_sensors"
    dpkg-deb -x "${deb[0]}" "$INCOMING/runtime/dexe_sensors"
    kfc_prefix="$INCOMING/runtime/dexe_sensors/home/dexforce/w1/install/kfcv2"
    [ -x "$kfc_prefix/lib/kfcv2/kfcv2_publisher" ] || fail "deb 解包后缺少 kfcv2_publisher"
    [ -x "$INCOMING/scripts/control_kfc.sh" ] || fail "缺少 KFCv2 控制脚本"
    ;;
  pc2)
    [ -f /opt/ros/humble/setup.bash ] || fail "PC2 缺少 ROS 2 Humble"
    [ -x "$INCOMING/scripts/start_pika_fisheye_compressors.sh" ] || fail "缺少鱼眼启动脚本"
    [ -x "$INCOMING/scripts/usb_camera.py" ] || fail "缺少 usb_camera.py"
    [ -x "$INCOMING/scripts/control_fisheye.sh" ] || fail "缺少鱼眼控制脚本"
    # ROS setup.bash references optional variables that may be unset; do not let
    # the installer's strict nounset mode turn that into a false dependency error.
    set +u
    source /opt/ros/humble/setup.bash
    set -u
    check_pc2_dependencies || fail "请按上面的提示安装 PC2 依赖"
    ;;
esac

if [ -d "$RELEASE" ]; then
  (cd "$RELEASE" && sha256sum -c manifest.sha256 >/dev/null) \
    || fail "同名 release 已存在但内容损坏：$RELEASE"
  rm -rf -- "$INCOMING"
else
  mv "$INCOMING" "$RELEASE"
fi

case "$ROLE" in
  pc1)
    cat > "$RELEASE/deployment.env" <<EOF
export PIKA_W1_ROLE=pc1
export KFCV2_PREFIX="$RELEASE/runtime/dexe_sensors/home/dexforce/w1/install/kfcv2"
export PC1_ROS_DOMAIN_ID="${PC1_ROS_DOMAIN_ID:-20}"
export PC1_KFC_IP="${PC1_KFC_IP:-192.168.20.30}"
export PC1_KFC_TOPIC="${PC1_KFC_TOPIC:-/camera/kfc_compressed_external}"
EOF
    ;;
  pc2)
    cat > "$RELEASE/deployment.env" <<EOF
export PIKA_W1_ROLE=pc2
export FISHEYE_START_SCRIPT="$RELEASE/scripts/start_pika_fisheye_compressors.sh"
export FISHEYE_CAMERA_NODE="$RELEASE/scripts/usb_camera.py"
EOF
    ;;
esac

ln -sfn "releases/$BUNDLE_ID" "$INSTALL_ROOT/current.new"
mv -Tf "$INSTALL_ROOT/current.new" "$INSTALL_ROOT/current"

echo "✅ $ROLE 部署完成"
echo "   release: $RELEASE"
echo "   current: $INSTALL_ROOT/current"
