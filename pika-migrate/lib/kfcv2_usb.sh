#!/bin/bash

KFCV2_VENDOR_ID="${KFCV2_VENDOR_ID:-1f3b}"
KFCV2_PRODUCT_ID="${KFCV2_PRODUCT_ID:-1021}"
KFCV2_DEV_ROOT="${KFCV2_DEV_ROOT:-/dev}"
KFCV2_UDEVADM="${KFCV2_UDEVADM:-udevadm}"
KFCV2_SYSFS_ROOT="${KFCV2_SYSFS_ROOT:-/sys}"

list_kfcv2_capture_nodes() {
  local node props vendor product caps
  for node in "$KFCV2_DEV_ROOT"/video*; do
    [ -e "$node" ] || continue
    [ -L "$node" ] && continue
    props=$("$KFCV2_UDEVADM" info -q property -n "$node" 2>/dev/null) || continue
    vendor=$(printf '%s\n' "$props" | sed -n 's/^ID_VENDOR_ID=//p')
    product=$(printf '%s\n' "$props" | sed -n 's/^ID_MODEL_ID=//p')
    caps=$(printf '%s\n' "$props" | sed -n 's/^ID_V4L_CAPABILITIES=//p')
    [ "$vendor" = "$KFCV2_VENDOR_ID" ] || continue
    [ "$product" = "$KFCV2_PRODUCT_ID" ] || continue
    case "$caps" in
      *:capture:*) printf '%s\n' "$node" ;;
    esac
  done | sort -V
}

require_single_kfcv2_capture() {
  local nodes=()
  mapfile -t nodes < <(list_kfcv2_capture_nodes)
  case "${#nodes[@]}" in
    1)
      KFCV2_CAPTURE_NODE="${nodes[0]}"
      export KFCV2_CAPTURE_NODE
      return 0
      ;;
    0)
      printf '未检测到 KFCv2 USB 采集节点（需要 1f3b:1021 capture）。\n' >&2
      return 1
      ;;
    *)
      printf '检测到多个 KFCv2 USB 采集节点，拒绝自动选择：\n' >&2
      printf '  %s\n' "${nodes[@]}" >&2
      return 2
      ;;
  esac
}

validate_kfcv2_symlink() {
  local stable="${1:-/dev/kfcv2-camera}" resolved expected
  require_single_kfcv2_capture || return
  [ -L "$stable" ] || {
    printf '缺少稳定链接：%s\n' "$stable" >&2
    return 1
  }
  resolved=$(readlink -f "$stable")
  expected=$(readlink -f "$KFCV2_CAPTURE_NODE")
  [ "$resolved" = "$expected" ] || {
    printf '稳定链接指向错误：%s -> %s，期望 %s\n' "$stable" "$resolved" "$expected" >&2
    return 1
  }
}

require_kfcv2_not_busy() {
  local device="${1:-/dev/kfcv2-camera}" users
  command -v fuser >/dev/null 2>&1 || return 0
  users=$(fuser "$device" 2>/dev/null || true)
  [ -z "$users" ] || {
    printf 'KFCv2 设备正被进程占用：%s\n' "$users" >&2
    return 1
  }
}

kfcv2_usb_speed_mbps() {
  local device="${1:-/dev/kfcv2-camera}" node path
  node=$(basename "$(readlink -f "$device" 2>/dev/null)") || return 1
  path=$(readlink -f "$KFCV2_SYSFS_ROOT/class/video4linux/$node/device" 2>/dev/null) || return 1
  while [ "$path" != "/" ] && [ -n "$path" ]; do
    if [ -r "$path/idVendor" ] && [ -r "$path/speed" ]; then
      cat "$path/speed"
      return 0
    fi
    path=$(dirname "$path")
  done
  return 1
}

smoke_kfcv2_mjpeg() {
  local device="$1" width="$2" height="$3" fps="$4" frames="${5:-3}"
  timeout 12 gst-launch-1.0 -q v4l2src device="$device" num-buffers="$frames" \
    ! "image/jpeg,width=$width,height=$height,framerate=$fps/1" \
    ! fakesink sync=false
}

write_pika_hardware_env() {
  local target="$1" owner="$2" dir tmp
  dir=$(dirname "$target")
  mkdir -p "$dir"
  tmp=$(mktemp "$dir/.pika_hardware.env.XXXXXX") || return 1
  {
    printf 'export L_DEPTH_CAMERA_NO=%q\n' "${L_DEPTH_CAMERA_NO:-}"
    printf 'export R_DEPTH_CAMERA_NO=%q\n' "${R_DEPTH_CAMERA_NO:-}"
    printf 'export PIKA_L_CODE=%q\n' "${PIKA_L_CODE:-}"
    printf 'export PIKA_R_CODE=%q\n' "${PIKA_R_CODE:-}"
    printf 'export HEAD_CAMERA_DEVICE=%q\n' "${HEAD_CAMERA_DEVICE:-/dev/kfcv2-camera}"
  } >"$tmp" || {
    rm -f "$tmp"
    return 1
  }
  bash -n "$tmp" || {
    rm -f "$tmp"
    return 1
  }
  chmod 0644 "$tmp" || {
    rm -f "$tmp"
    return 1
  }
  if [ "$(id -u)" -eq 0 ]; then
    chown "$owner" "$tmp" || {
      rm -f "$tmp"
      return 1
    }
  fi
  mv -f "$tmp" "$target"
}
