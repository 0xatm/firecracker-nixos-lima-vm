# Firecracker-on-Lima (Portable NixOS Stack)

This repository provides a portable, fresh-clone workflow to run a Firecracker microVM inside a NixOS Lima VM on Apple Silicon.

1. Install Lima.
2. Bootstrap the NixOS guest.
3. Connect directly to the inner Firecracker VM.

## Prerequisites

- macOS on Apple Silicon
- `limactl` installed (via Homebrew or Nix)

Install examples:

```bash
brew install lima
```

or

```bash
nix-env -iA nixpkgs.lima
```

## Quick Start

From the repository root:

```bash
./scripts/bootstrap.sh
./connect.sh
```

What `bootstrap.sh` does:

- creates or recreates the Lima instance (`fc-nixos` by default),
- applies NixOS config and Firecracker services in the guest,
- initializes Firecracker assets on first run,
- exports the inner guest SSH key to `./.state/ssh/microvm.id_rsa`.

## Configuration

`scripts/bootstrap.sh` auto-loads `./.bootstrap.env` if present.

Example `./.bootstrap.env`:

```bash
LIMA_CPUS=4
LIMA_MEMORY=4GiB
LIMA_DISK=100GiB
MICROVM_VCPUS=1
MICROVM_MEM_MIB=1024
MICROVM_ROOTFS_SIZE=1G
```

Supported variables:

- `LIMA_INSTANCE_NAME` (default: `fc-nixos`)
- `LIMA_TEMPLATE_PATH` (default: `lima/nixos.yaml`)
- `LIMA_CPUS` (default: `4`)
- `LIMA_MEMORY` (default: `4GiB`)
- `LIMA_DISK` (default: `100GiB`)
- `MICROVM_VCPUS` (default: `1`)
- `MICROVM_MEM_MIB` (default: `1024`)
- `MICROVM_ROOTFS_SIZE` (default: `1G`)
- `FC_BOOTSTRAP_FORCE=1` to skip the interactive delete confirmation

Unit formats:

- `LIMA_MEMORY` / `LIMA_DISK`: use Lima-style units like `4GiB`, `100GiB`.
- `MICROVM_MEM_MIB`: use an integer MiB value like `1024`, `12288`.
- `MICROVM_ROOTFS_SIZE`: use `truncate -s` style size values like `20G`, `1G`.

Precedence:

- exported shell env vars override `.bootstrap.env`,
- `.bootstrap.env` overrides script defaults.

## Bootstrap Behavior

- If the instance already exists, `bootstrap.sh` asks for confirmation before deletion.
- In non-interactive shells, bootstrap aborts instead of deleting unless `FC_BOOTSTRAP_FORCE=1` is set.
- Bootstrap is intentionally destructive to avoid drift.

## Daily Commands

Connect (starts services as needed):

```bash
./connect.sh
```

Stop the Lima instance:

```bash
./scripts/stop.sh
```

Reset everything (delete Lima instance + local state):

```bash
./scripts/reset.sh
```

## Repo Layout

- `scripts/bootstrap.sh` - create/recreate Lima guest and apply config
- `scripts/stop.sh` - stop Lima instance
- `scripts/reset.sh` - delete Lima instance and local state
- `connect.sh` - SSH helper from host to inner Firecracker VM
- `lima/nixos.yaml` - base Lima template
- `nixos/configuration.nix` - NixOS module applied in guest
- `nixos/scripts/init-first-run.sh` - one-time Firecracker asset initialization
- `nixos/scripts/start-stack.sh` - Firecracker startup and networking


## Troubleshooting

### On Host

Check service state:

```bash
limactl shell fc-nixos -- sudo systemctl status firecracker firecracker-microvm-init firecracker-microvm-start
```

Follow logs:

```bash
limactl shell fc-nixos -- sudo journalctl -u firecracker -u firecracker-microvm-init -u firecracker-microvm-start -f
```

Verify KVM availability in guest:

```bash
limactl shell fc-nixos -- ls -l /dev/kvm
```

## Credits

Thank you to the upstream projects this setup builds on:

- [`yashdiq/firecracker-lima-vm`](https://github.com/yashdiq/firecracker-lima-vm) for the original Lima + Firecracker flow and script shape
- [`nixos-lima/nixos-lima`](https://github.com/nixos-lima/nixos-lima) for the NixOS Lima template base
- [`firecracker-microvm/firecracker`](https://github.com/firecracker-microvm/firecracker)

Licenses remain with their upstream projects (`yashdiq/firecracker-lima-vm` / Firecracker: Apache-2.0, nixos-lima: MIT).
