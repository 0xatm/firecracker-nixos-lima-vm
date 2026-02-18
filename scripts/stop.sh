#!/usr/bin/env bash
set -euo pipefail

VM_NAME="${LIMA_INSTANCE_NAME:-fc-nixos}"

if ! command -v limactl >/dev/null 2>&1; then
  echo "Error: limactl is required." >&2
  exit 1
fi

if limactl list 2>/dev/null | awk 'NR>1 {print $1}' | grep -Fxq "$VM_NAME"; then
  limactl stop "$VM_NAME"
  echo "Stopped Lima instance '$VM_NAME'."
else
  echo "Lima instance '$VM_NAME' does not exist; nothing to stop."
fi
