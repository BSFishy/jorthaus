# Disk images

This document describes how VM disk images are built in this repository, which Nix image variant is used, how those images are imported into Proxmox, and the rationale behind the current setup.

## Overview

This repository uses:

- **Nix** to define NixOS systems and build reproducible VM disk images
- **OpenTofu** to upload and deploy those images as VMs in Proxmox
- **Proxmox cloud-init integration** to provide first-boot configuration such as networking and other initialization data

The image build and deploy flow is:

1. Define a NixOS host in `inventory/`
2. Build a VM image from that host definition with `nix build`
3. Produce a stable, predictable image filename such as `result/home.qcow2`
4. Upload that image to Proxmox with OpenTofu
5. Create a VM that imports the image and applies Proxmox-side settings such as CPU, memory, disk attachment, networking, and cloud-init initialization

## Current image variant

The repository currently builds the **`qemu-efi`** image variant.

This is exposed in `flake.nix` through:

- `packages.x86_64-linux.<hostname>` for per-host images
- `packages.x86_64-linux.vm-images` for all VM images together

The built image is wrapped so that each host gets a stable name:

- `home` -> `home.qcow2`

That stable naming is intentional so that OpenTofu can reference a consistent path such as `../result/home.qcow2` instead of a generated store filename.

## Why `qemu-efi`

The original approach used the NixOS `proxmox` image variant, which produces a Proxmox backup archive such as `.vma.zst`.

That format is useful for Proxmox-native backup/restore workflows, but it is not the best fit for the OpenTofu resource flow used in this repository.

### Why not the `proxmox` variant

The `proxmox` image variant produces a Proxmox backup artifact:

- VMA archive
- compressed as `.vma.zst`
- includes Proxmox-specific restore metadata

That is a good fit for restore-style workflows, but this repo uses OpenTofu resources that work better with a **VM disk image import** flow.

In practice, the `qemu-efi` variant is a better match because it gives us a general-purpose disk image that Proxmox can import as a VM disk.

### Why not raw images

A raw image would also work, but `qemu-efi` defaults to **qcow2**, which is typically much smaller than raw for mostly-empty guest disks.

That makes `qemu-efi` a better default here because it offers:

- smaller build artifacts
- less data to upload to Proxmox
- a cleaner fit for image import workflows

## EFI and machine choices

The current Terraform VM definition uses:

- `machine = "q35"`
- `bios = "ovmf"`

This matches the EFI-capable image produced by `qemu-efi`.

The intent is to keep the VM configuration modern and explicit:

- **OVMF** for UEFI firmware
- **q35** for a modern machine type

## Guest-side settings required for Proxmox

Although the image variant is `qemu-efi`, the guest itself is configured to behave like a Proxmox-friendly imported VM.

Those guest-side settings live in:

- `modules/system/default.nix`

That module includes the following important behavior.

### Bootloader

- GRUB is disabled with `lib.mkForce false`
- `systemd-boot` is enabled

This matches the EFI-oriented image layout.

### Cloud-init inside the guest

The guest enables cloud-init:

- `services.cloud-init.enable = true`
- `services.cloud-init.network.enable = true`

This is important because the OpenTofu `initialization` block relies on Proxmox cloud-init behavior. Without cloud-init enabled in the guest, the Proxmox-side initialization settings would not be applied as intended.

### Networking ownership

The guest sets:

- `networking.hostName = ""`
- `networking.useDHCP = false`

The intent is for cloud-init to control first-boot networking and related initialization instead of the image hard-coding those values ahead of time.

### QEMU guest support

The guest enables:

- `services.qemuGuest.enable = true`

This improves Proxmox integration and guest management.

### Console behavior

The guest sets:

- `boot.kernelParams = [ "console=ttyS0" ]`

This aligns the guest with the serial console setup used by Proxmox.

### Filesystem layout and growth

The guest expects:

- root filesystem at `/dev/disk/by-label/nixos`
- EFI system partition at `/dev/disk/by-label/ESP`

It also enables automatic root partition growth:

- `boot.growPartition = true`
- root filesystem uses `autoResize = true`

This allows the imported image to start small while still growing cleanly when the Proxmox VM disk is sized larger.

## Build outputs

The flake wraps the raw NixOS image output to expose stable filenames.

### Per-host build

Build a single host image:

```bash
nix build .#home --out-link result-home
```

Result:

```text
result-home/home.qcow2
```

### All-host build

Build all defined VM images:

```bash
nix build .#vm-images --out-link result
```

Result:

```text
result/home.qcow2
```

## Just recipes

The common workflows are exposed in `justfile`.

### Build images

```bash
just build
```

Builds all VM images into `result/`.

### Build a single host image

```bash
just build-home
```

Builds the `home` image into `result-home/`.

### Plan and apply

```bash
just plan
just apply
```

These depend on `build`, so they rebuild the current image set before running OpenTofu from the `terraform/` directory.

## How OpenTofu uses the image

The current Terraform VM definition lives in:

- `terraform/home.tf`

The image upload uses `proxmox_virtual_environment_file` with:

- `content_type = "import"`
- `source_file.path = "../result/home.qcow2"`

That means Proxmox treats the uploaded file as an importable VM disk image rather than as a backup archive.

The VM then attaches that uploaded image as its primary disk.

## Proxmox-side settings in Terraform

The VM resource currently defines Proxmox-side behavior such as:

- CPU cores and CPU type
- memory
- machine type
- firmware type
- serial console device
- disk bus and disk options
- network bridge and NIC model
- cloud-init initialization settings

This split is intentional:

- **Nix** defines the guest OS and image behavior
- **OpenTofu** defines the Proxmox VM that consumes that image

## Cloud-init rationale

The `initialization` block in Terraform is the Proxmox-side interface for cloud-init-driven first-boot configuration.

This lets the VM image stay fairly generic while still allowing deployment-time settings such as:

- DHCP or static IP configuration
- user/account initialization
- custom cloud-init user-data, meta-data, vendor-data, or network-data later if needed

That is preferable to baking deployment-specific details directly into the image.

## Current tradeoffs

The current design favors:

- reproducible image builds with Nix
- stable file names for deployment automation
- smaller import artifacts via qcow2
- a clean separation between guest image configuration and Proxmox VM configuration

Tradeoffs include:

- the image is no longer a Proxmox-native `.vma.zst` backup artifact
- some Proxmox-specific defaults that came from the NixOS `proxmox` image module are now maintained explicitly in this repo

That tradeoff is considered worthwhile because it better matches the OpenTofu import workflow used here.

## Operational notes

- The Proxmox datastore used for the upload must support the `import` content type.
- The VM firmware and machine type should remain aligned with the image layout. Since this repo currently builds `qemu-efi`, the VM should continue using UEFI-compatible settings unless the image strategy changes.
- If the image format, firmware mode, bootloader, or import strategy changes, this document should be updated as part of the same change.

## Future directions

Potential future improvements include:

- parameterizing image builds per host or per role
- documenting additional host images as more inventory entries are added
- adding more operational documentation for deployment, rollback, and troubleshooting
- generating more of the Terraform-side configuration from shared host metadata
