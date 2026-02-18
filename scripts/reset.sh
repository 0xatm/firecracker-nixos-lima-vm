#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

VM_NAME="${LIMA_INSTANCE_NAME:-fc-nixos}"
STATE_DIR="${REPO_ROOT}/.state"

if ! command -v limactl >/dev/null 2>&1; then
  echo "Error: limactl is required." >&2
  exit 1
fi

if limactl list 2>/dev/null | awk 'NR>1 {print $1}' | grep -Fxq "$VM_NAME"; then
  limactl stop "$VM_NAME" || true
  limactl delete -f "$VM_NAME"
  echo "Deleted Lima instance '$VM_NAME'."
else
  echo "Lima instance '$VM_NAME' does not exist; skipping delete."
fi

rm -rf "$STATE_DIR"
echo "Removed local state directory: $STATE_DIR"
