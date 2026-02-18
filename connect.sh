#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

VM_NAME="${LIMA_INSTANCE_NAME:-fc-nixos}"
TARGET="${MICROVM_TARGET:-root@172.16.0.2}"
KEY_PATH="${MICROVM_KEY:-${SCRIPT_DIR}/.state/ssh/microvm.id_rsa}"

usage() {
  cat <<'USAGE'
Usage:
  ./connect.sh [user@ip] [extra ssh args...]

Defaults:
  user@ip: root@172.16.0.2
  key: ./.state/ssh/microvm.id_rsa
  Lima instance: fc-nixos
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -gt 0 && "${1:0:1}" != "-" ]]; then
  TARGET="$1"
  shift
fi

if ! command -v limactl >/dev/null 2>&1; then
  echo "Error: limactl is required." >&2
  exit 1
fi

if [[ ! -f "$KEY_PATH" ]]; then
  echo "Error: missing SSH key at $KEY_PATH" >&2
  echo "Run ./scripts/bootstrap.sh first." >&2
  exit 1
fi

if ! limactl list 2>/dev/null | awk 'NR>1 {print $1}' | grep -Fxq "$VM_NAME"; then
  echo "Error: Lima instance '$VM_NAME' does not exist." >&2
  echo "Run ./scripts/bootstrap.sh first." >&2
  exit 1
fi

if ! limactl shell "$VM_NAME" -- sh -lc 'command -v nc >/dev/null 2>&1' >/dev/null 2>&1; then
  echo "Error: 'nc' is not available in the guest; rerun ./scripts/bootstrap.sh." >&2
  exit 1
fi

limactl start "$VM_NAME" >/dev/null

limactl shell "$VM_NAME" -- sudo systemctl start firecracker firecracker-microvm-init firecracker-microvm-start >/dev/null

exec ssh \
  -o "ProxyCommand=limactl shell ${VM_NAME} -- nc %h %p" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o IdentitiesOnly=yes \
  -o IdentityAgent=none \
  -i "$KEY_PATH" \
  "$TARGET" \
  "$@"
