# Firecracker-on-Lima (Declarative NixOS)

This repo bootstraps a NixOS Lima VM that declaratively runs Firecracker and a nested Ubuntu microVM.

It builds on:
- [`yashdiq/firecracker-lima-vm`](https://github.com/yashdiq/firecracker-lima-vm) for the original Firecracker-on-Lima flow and networking approach
- [`nixos-lima/nixos-lima`](https://github.com/nixos-lima/nixos-lima) for the NixOS-on-Lima base template

## Prerequisites

- macOS on Apple Silicon
- Lima (`limactl`)

Install examples:

```bash
brew install lima
```

or

```bash
nix-env -iA nixpkgs.lima
```

## Quick Start

From repo root:

```bash
./scripts/bootstrap.sh
./connect.sh
```

`bootstrap.sh` will:
- create/recreate the Lima VM (`fc-nixos` by default)
- stage Firecracker + Lima NixOS modules into `/etc/nixos`
- apply a **bootable** declarative generation (`nixos-rebuild boot`)
- reboot the guest and verify Firecracker services
- export the nested microVM SSH key to `./.state/ssh/microvm.id_rsa`

`connect.sh` will:
- ensure the Lima VM is running
- start `firecracker-microvm-start.service`
- SSH into the nested microVM via Lima proxy

## Configuration

`./scripts/bootstrap.sh` auto-loads `./.bootstrap.env` if present.

Example:

```bash
LIMA_CPUS=8
LIMA_MEMORY=14GiB
LIMA_DISK=80GiB
MICROVM_VCPUS=6
MICROVM_MEM_MIB=49152
MICROVM_ROOTFS_SIZE=40G
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
- `FC_BOOTSTRAP_FORCE=1` (skip delete confirmation)

Unit notes:
- `LIMA_MEMORY` / `LIMA_DISK` use Lima byte units like `GiB`
- `MICROVM_MEM_MIB` uses integer MiB
- `MICROVM_ROOTFS_SIZE` uses `truncate` syntax (`G`, `M`, etc.)

Why mixed units: Lima and Firecracker/rootfs tooling consume different unit formats; the script passes each in its native format.

Precedence:
- exported shell env vars override `.bootstrap.env`
- `.bootstrap.env` overrides script defaults

## Daily Commands

Connect to nested microVM:

```bash
./connect.sh
```

Stop Lima VM:

```bash
./scripts/stop.sh
```

Reset everything (delete VM + local state):

```bash
./scripts/reset.sh
```

## Repo Layout

- `scripts/bootstrap.sh` - deterministic VM bootstrap + declarative guest config
- `scripts/stop.sh` - stop Lima instance
- `scripts/reset.sh` - delete Lima instance + local state
- `connect.sh` - host-to-microVM SSH helper
- `lima/nixos.yaml` - Lima template (nested virtualization enabled)
- `nixos/configuration.nix` - Firecracker NixOS module
- `nixos/lima.nix` - vendored `nixos-lima` base guest module
- `nixos/lima-init.nix` - vendored `nixos-lima` cidata/guest-agent init module
- `nixos/scripts/init-first-run.sh` - one-time kernel/rootfs init inside guest
- `nixos/scripts/start-stack.sh` - Firecracker API config + tap/NAT + microVM start

## Troubleshooting

Check KVM inside guest:

```bash
limactl shell fc-nixos -- ls -l /dev/kvm
```

Check Firecracker services:

```bash
limactl shell fc-nixos -- sudo systemctl --no-pager --full status firecracker firecracker-microvm-init firecracker-microvm-start
```

Check Firecracker API socket/process:

```bash
limactl shell fc-nixos -- bash -lc "ps -ef | grep -E '[f]irecracker --api-sock /tmp/firecracker.socket'; ls -l /tmp/firecracker.socket"
```

## License

Upstream licenses apply:
- `firecracker-microvm/firecracker` and `yashdiq/firecracker-lima-vm`: Apache-2.0
- `nixos-lima/nixos-lima`: MIT
