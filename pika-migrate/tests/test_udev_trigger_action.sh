#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
scan_paths=(
  "$repo_root/pika/pika_ros/src/sensor_tools/scripts"
  "$repo_root/pika/pika_ros/src/sensor_tools/README.md"
  "$repo_root/pika-migrate/setup_hardware.sh"
  "$repo_root/pika-migrate/documents"
)

violations=$(
  grep -RIn --include='*.bash' --include='*.sh' --include='*.py' --include='*.md' \
    'udevadm[[:space:]]\+trigger' "${scan_paths[@]}" \
    | grep -v -- '--action=add' || true
)

if [[ -n "$violations" ]]; then
  printf 'udevadm trigger must explicitly use --action=add:\n%s\n' "$violations" >&2
  exit 1
fi

printf 'All project udev trigger commands explicitly use --action=add.\n'
