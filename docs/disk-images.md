# Disk images

This document describes how VM bootstrap images are built in this repository, how they are used with OpenTofu and Proxmox, and how that ties into the intended long-term management workflow.

## Intended workflow

The goal of this repository is:

1. use OpenTofu to provision a VM in Proxmox from a generic NixOS bootstrap image
2. ensure that VM is reachable over SSH at a predictable address
3. manage the VM after provisioning with `nh os switch --target-host ...` against a host-specific NixOS configuration

That means image builds are primarily for **initial provisioning**, not for day-2 configuration changes.

In practice, the workflow is intended to be:

```bash
just apply
just switch home
```

After the VM exists, most normal changes should be applied with `nh os switch` rather than by rebuilding and reimporting the VM image.

## Current image strategy

This repository builds a single generic bootstrap image:

- flake package: `packages.x86_64-linux.bootstrap-image`
- build output file: `bootstrap.qcow2`

The image is built from the bootstrap-specific module path wired directly in `flake.nix` and wrapped to expose a stable output path.

Example build:

```bash
nix build .#bootstrap-image --out-link result
```

Result:

```text
result/bootstrap.qcow2
```

## Why a single bootstrap image

The repository previously built per-host images. That approach works, but it makes ongoing changes feel more image-centric than necessary.

The current design uses a single bootstrap image because it better matches the intended lifecycle:

- OpenTofu provisions the VM once
- the VM becomes reachable over SSH
- host-specific configuration is applied with `nh os switch`

This keeps the provisioning image generic while allowing each actual machine to be fully defined in `inventory.nix` and exposed through `nixosConfigurations`.

## Current image variant

The bootstrap image uses the NixOS **`qemu-efi`** image variant.

This was chosen because it is a good fit for Proxmox VM disk import workflows:

- it produces a qcow2 disk image
- qcow2 is smaller than raw in typical cases
- it works well with Proxmox `import` uploads
- it avoids the Proxmox backup/archive workflow used by `.vma.zst` images

## Why not the `proxmox` image variant

The NixOS `proxmox` image variant produces a Proxmox-specific backup artifact such as `.vma.zst`.

That is useful for backup/restore-style workflows, but this repository uses OpenTofu resources that import a disk image into a VM definition.

Because of that, a generic qcow2 disk image is the better fit here.

## Build and inventory configuration locations

The shared deployable host inventory lives in:

- `inventory.nix`

The generic guest image behavior is configured in:

- `modules/system/default.nix`

The bootstrap-only host module lives in:

- `modules/hosts/bootstrap.nix`

The deployable host modules live in:

- `modules/hosts/`

The flake wiring that exposes `bootstrap-image`, `inventory`, `terraform.vars`, and `nixosConfigurations` lives in:

- `flake.nix`

## What the bootstrap image contains

The bootstrap image is intentionally generic, but it includes the baseline features needed for Proxmox provisioning and later remote management.

### Boot setup

The image is configured for EFI boot:

- GRUB disabled
- `systemd-boot` enabled
- intended for Proxmox with `bios = "ovmf"`
- intended for modern machine type `q35`

### Cloud-init support

The guest enables cloud-init:

- `services.cloud-init.enable = true`
- `services.cloud-init.network.enable = true`

Cloud-init is used here primarily for first-boot network configuration provided by Terraform.

### QEMU / Proxmox guest support

The guest enables:

- `services.qemuGuest.enable = true`
- serial console via `boot.kernelParams = [ "console=ttyS0" ]`

This keeps the guest aligned with the Proxmox VM configuration used in Terraform.

### Filesystem layout and growth

The image expects:

- root filesystem labeled `nixos`
- EFI system partition labeled `ESP`

It also allows the root partition and filesystem to grow when the VM disk is larger than the original image size.

### SSH access

The image contains a built-in administrative user:

- username: `matt`

That user:

- is a normal user
- is in the `wheel` group
- has passwordless sudo via wheel
- has the repository-managed SSH public key installed as an authorized key

This is what allows the VM to be reached over SSH immediately after provisioning without requiring a cloud-init user definition.

## Where the SSH username and public key are defined

The SSH bootstrap identity is intentionally committed to the repository.

### Username

The bootstrap username is defined in:

- `modules/system/default.nix`

Current value:

- `matt`

### Public key

The authorized SSH public key is also defined in:

- `modules/system/default.nix`

It is installed for the `matt` user in `users.users.matt.openssh.authorizedKeys.keys`.

## Host inventory and host modules

Deployable hosts are defined in the root inventory attrset:

- `inventory.nix`

Each attribute name is the host name, and each host definition contains things such as:

- hostname
- IP information
- Proxmox VM settings
- host-specific NixOS modules

The current deployable hosts are:

- `home`
- `infra`
- `media`

Host-specific NixOS modules live in:

- `modules/hosts/`

The bootstrap image is intentionally **not** part of the deployable host inventory. It is referenced directly by the flake so that `inventory.nix` remains focused on actual deployed machines.

The long-term desired configuration for each host is exposed through `nixosConfigurations`, for example:

- `nixosConfigurations.home`
- `nixosConfigurations.infra`
- `nixosConfigurations.media`

A normal host update is intended to be applied with:

```bash
just switch home
```

## How Terraform uses the bootstrap image

The current VM template is in:

- `terraform/proxmox.tf`

Terraform uploads:

- `../result/bootstrap.qcow2`

using:

- `proxmox_virtual_environment_file`
- `content_type = "import"`

Terraform host data is generated from the flake inventory output into:

- `terraform/generated.auto.tfvars.json`

That generated file is produced from:

- `nix eval --json .#terraform.vars`

and is used by the generic Terraform resources defined in `terraform/proxmox.tf`.

The bootstrap image upload is not duplicated per VM. Instead, Terraform groups hosts by Proxmox image upload target and uploads the bootstrap image once per unique:

- Proxmox node
- image datastore

The VMs then reference the uploaded bootstrap image for their corresponding target.

## Proxmox-side settings in Terraform

Terraform owns the Proxmox VM definition, including things such as:

- VM name
- target node
- machine type
- firmware type
- CPU and memory
- disk placement and disk interface
- optional additional VM data disks declared per host in `inventory.nix`
- network bridge and NIC model
- optional USB passthrough devices declared per host in `inventory.nix`
- optional PCI passthrough devices declared per host in `inventory.nix`
- first-boot cloud-init network configuration

It also manages bootstrap image uploads per unique image target rather than per individual VM.

## Static addressing

The current VM is provisioned with a static address in the `10.1.0.0/16` network.

Current values are defined in:

- `inventory.nix`

Current settings include:

- `home`: `10.1.4.10/16`
- `infra`: `10.1.4.11/16`
- `media`: `10.1.4.12/16`
- gateway: `10.1.0.1`

The intended convention is to count upward within the `10.1.4.x` range as more VMs are added.

## Why cloud-init does not define the SSH user

The SSH user and authorized key are already present in the bootstrap image itself.

Because of that, Terraform cloud-init does **not** need to create the user or inject SSH keys for normal bootstrap access.

Cloud-init remains enabled because it is still useful for first-boot network configuration and other metadata-driven initialization if needed later.

## Ongoing management model

After a VM is created from the bootstrap image, the preferred management path is:

```bash
just switch home
```

which expands to an `nh os switch` call using the management IP from `inventory.nix`.

That means:

- OpenTofu provisions infrastructure
- NixOS host configurations manage the guest long-term

Rebuilding and reimporting the bootstrap image should generally only be necessary when changing the generic bootstrap image itself.

## Just recipes

The common entry points are exposed through `justfile`.

### Build the bootstrap image

```bash
just build
```

This runs:

```bash
nix build .#bootstrap-image --out-link result
```

### Generate Terraform variables from inventory

```bash
just tfvars
```

This writes:

- `terraform/generated.auto.tfvars.json`

from:

```bash
nix eval --json .#terraform.vars
```

### Switch a deployed host

```bash
just switch home
```

This resolves the target host IP from `inventory.nix` and runs `nh os switch` against `.#home`.

### Plan and apply

```bash
just plan
just apply
```

These build the current bootstrap image, generate Terraform variables from inventory, and then run OpenTofu from the `terraform/` directory.

## Operational notes

- The Proxmox datastore used for the uploaded image must support the `import` content type.
- The Proxmox VM settings should remain aligned with the image strategy. Since the image is `qemu-efi`, the VM should continue using UEFI-compatible settings unless the image strategy changes.
- If the bootstrap username, SSH key, inventory schema, static addressing convention, or provisioning workflow changes, this document should be updated in the same change.
