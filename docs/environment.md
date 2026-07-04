# Environment configuration and system assumptions

This document records the parts of the current setup that are specific to the present environment so the homelab can be rebuilt more easily if needed.

The intent is to separate:

- **repository-side configuration** — things configured here in the repo or local shell environment
- **system assumptions** — things that must already exist or be configured in Proxmox and the surrounding network

## Repository-side configuration

These are the things configured in this repository or local workstation environment that are required for the current workflow.

### Proxmox provider environment variables

The OpenTofu Proxmox provider is configured through environment variables.

Current values are defined in:

- `.env`

Current variables:

- `PROXMOX_VE_ENDPOINT=https://10.1.1.202:8006/`
- `PROXMOX_VE_API_TOKEN=root@pam!terraform=...`
- `PROXMOX_VE_INSECURE=true`
- `PROXMOX_VE_SSH_USERNAME=root`

#### Meaning

- `PROXMOX_VE_ENDPOINT` — Proxmox API endpoint
- `PROXMOX_VE_API_TOKEN` — API token used by OpenTofu provider operations
- `PROXMOX_VE_INSECURE` — disables TLS certificate verification for the Proxmox API
- `PROXMOX_VE_SSH_USERNAME` — SSH user used for provider SSH operations against the Proxmox host

### Proxmox SSH private key loading

The Proxmox SSH private key is loaded through:

- `.envrc`

Current behavior:

- if `$HOME/.ssh/id_ed25519` exists, its contents are exported to `PROXMOX_VE_SSH_PRIVATE_KEY`

This means the current workflow assumes:

- the local workstation has the SSH private key at `$HOME/.ssh/id_ed25519`
- that key is authorized for SSH access to the Proxmox host

### Bootstrap guest SSH identity

The bootstrap image contains a built-in administrative user so newly provisioned VMs are reachable immediately over SSH.

This is configured in:

- `modules/system/default.nix`

Current settings:

- username: `matt`
- authorized public key: committed directly in `modules/system/default.nix`
- `matt` is in the `wheel` group
- passwordless sudo for wheel is enabled

This is repository-side configuration because it is part of the guest image built by Nix.

### Shared deployable host inventory

Deployable hosts are defined in:

- `inventory.nix`

This file is the source of truth for per-host deployment metadata such as:

- host name
- IP addressing
- Proxmox node name
- Proxmox hardware/layout settings
- host-specific NixOS modules

### Terraform variables generated from inventory

Terraform host data is generated from the flake inventory output into:

- `terraform/generated.auto.tfvars.json`

This is produced by:

```bash
nix eval --json .#terraform.vars > terraform/generated.auto.tfvars.json
```

The `just tfvars`, `just plan`, and `just apply` recipes depend on this pattern.

## System assumptions

These are not primarily configured in the repo itself. They are assumptions about the Proxmox environment, surrounding network, or external state that must already exist for the current setup to work.

## Proxmox node names

Current inventory expects the Proxmox node:

- `gaia-05`

Defined in:

- `inventory.nix`
- used by `terraform/proxmox.tf`

This means the current Proxmox environment must have a node with that exact name.

### Proxmox management IP scheme

Current evidence in the repo suggests Proxmox physical nodes use the `10.1.1.20x` management IP scheme.

Currently referenced example:

- `gaia-05` API endpoint: `10.1.1.202`

This is separate from the VM guest network in `10.1.4.x`.
When adding additional physical Proxmox nodes, prefer assigning them from the same `10.1.1.20x` management range unless the environment design changes.

## Proxmox storage layout

Current inventory expects these storages to exist:

- image upload datastore: `local`
- VM disk datastore: `local-lvm`

Defined in:

- `inventory.nix`
- used by `terraform/proxmox.tf`

### Additional storage assumption

The datastore used for bootstrap image uploads must support:

- `content_type = "import"`

This is required by the Terraform resource that uploads `bootstrap.qcow2` to Proxmox.

## Proxmox VM/network layout assumptions

Current inventory expects:

- bridge: `vmbr0`
- machine type: `q35`
- firmware: `ovmf`

Defined in:

- `inventory.nix`
- used by `terraform/proxmox.tf`

These are assumptions about how VMs should be attached and booted in the Proxmox environment.

## Network addressing assumptions

The current deployed host inventory assumes a network layout with:

- `home`: `10.1.4.10/16`
- `infra`: `10.1.4.11/16`
- `media`: `10.1.4.12/16`
- gateway: `10.1.0.1`

Defined in:

- `inventory.nix`

This implies the surrounding environment must support:

- the `10.1.0.0/16` network
- host addressing in the `10.1.4.x` range
- gateway `10.1.0.1`
- routing/connectivity between the Proxmox guest network and the machine from which `nh os switch` and SSH are run

## Proxmox API reachability

The current environment assumes the Proxmox API is reachable at:

- `https://10.1.1.202:8006/`

Defined in:

- `.env`

This is not just a repo setting; it also implies that the actual Proxmox environment is reachable there from the machine running OpenTofu.

## Proxmox SSH reachability

The current environment assumes:

- SSH access to the Proxmox host as `root`
- the local SSH private key is accepted by that host

This is implied by:

- `.env`
- `.envrc`

## Current hardware layout assumptions for deployable hosts

The current VMs assume:

- CPU cores: `2`
- memory: `2048` MiB
- disk size: `20` GiB
- network model: `virtio`
- primary disk interface: `virtio0`
- cloud-init interface: `ide2`
- serial device: `socket`
- guest OS type: `l26`
- CPU type in Terraform: `max`

These values are defined by:

- `inventory.nix`
- `terraform/proxmox.tf`

The current deployable hosts are:

- `home`
- `infra`
- `media`

### Optional USB passthrough

Per-host Proxmox USB passthrough can now be declared in:

- `inventory.nix` under `proxmox.usb`
- consumed by `terraform/proxmox.tf`

The current shape is a list of objects such as:

```nix
usb = [
  {
    host = "1a86:55d4";
    usb3 = true;
  }
];
```

or, if Proxmox resource mappings are preferred:

```nix
usb = [
  {
    mapping = "zigbee-coordinator";
    usb3 = true;
  }
];
```

This is intended for devices such as a Zigbee coordinator attached to the `home` VM.
The exact `host` vendor/product ID or `mapping` name is environment-specific and must be discovered from the Proxmox side before enabling passthrough.

Current repository expectation for the `home` VM:

- USB mapping name: `zigbee-coordinator`
- guest service consumer: Zigbee2MQTT
- configured guest serial path: `/dev/serial/by-id/usb-ITead_Sonoff_Zigbee_3.0_USB_Dongle_Plus_fc390a86e549ef118fc7cd8cff00cc63-if00-port0`

### Optional PCI passthrough

Per-host Proxmox PCI passthrough can now be declared in:

- `inventory.nix` under `proxmox.hostpci`
- consumed by `terraform/proxmox.tf`

The current shape is a list of objects such as:

```nix
hostpci = [
  {
    device = "hostpci0";
    mapping = "amd-igpu";
    pcie = true;
  }
];
```

This is intended for devices such as the AMD iGPU passed through to the `media` VM for Jellyfin transcoding.
Using a Proxmox resource mapping is the preferred repository-side abstraction when the same guest may need equivalent hardware on different physical nodes.
The exact mapping definition must exist in Proxmox on the relevant nodes before Terraform apply succeeds.

Current repository expectation for the `media` VM:

- mapping name: `amd-igpu`
- guest slot name: `hostpci0`
- PCIe enabled: yes
- ROM BAR enabled: yes

Current known Proxmox-side device on `gaia-05`:

- `0000:c5:00.0` — AMD Phoenix1 iGPU

For the current Jellyfin setup, map the VGA function rather than enabling mediated-device mode.
The repository is currently configured for full PCI passthrough of the GPU function to the guest, not mediated/vGPU-style sharing.
On additional Proxmox nodes, create the same `amd-igpu` mapping name and point it at that node's local AMD iGPU PCI address.
The guest configuration also expects `hardware.enableRedistributableFirmware = true` so the AMDGPU firmware blobs are available inside NixOS.

### Optional additional VM data disks

Per-host additional VM disks can now be declared in:

- `inventory.nix` under `proxmox.dataDisks`
- consumed by `terraform/proxmox.tf`

The current shape is a list of objects such as:

```nix
dataDisks = [
  {
    interface = "virtio1";
    datastoreId = "media";
    size = 800;
    serial = "media";
    cache = "none";
    backup = false;
    replicate = false;
    discard = "on";
    iothread = true;
  }
];
```

This is intended for guest-visible data volumes such as the `media` VM's Ceph RBD-backed Jellyfin library disk.
`datastoreId` is the Proxmox storage identifier, which may itself be backed by a Ceph pool.
For the current `media` host, the additional disk is expected to appear in the guest as `/dev/disk/by-id/virtio-media` and is declaratively partitioned and mounted by the host configuration.

## Why this distinction matters

When rebuilding from scratch, failures often come from confusing repository configuration with environmental assumptions.

Examples:

- changing `.env` is a repository/workstation-side config change
- renaming a Proxmox node or storage is an environment-side assumption change
- changing the bootstrap SSH key is a repository-side config change
- changing the real network gateway or subnet is an environment-side assumption change

This document exists to make that distinction explicit.

## Rebuild checklist

If starting over, confirm these repository-side configuration items first:

- `.env` contains the correct Proxmox API endpoint, token, insecure setting, and SSH username
- `.envrc` exports the expected Proxmox SSH private key
- `modules/system/default.nix` contains the intended bootstrap user and authorized key
- `inventory.nix` contains the correct host metadata

Then confirm these environment/system assumptions:

- Proxmox node names match inventory
- required storages exist and `import` is enabled on the image upload datastore
- bridge names match inventory
- network addressing and gateway match reality
- Proxmox API is reachable at the configured endpoint
- the Proxmox host accepts the configured SSH key

## Maintenance note

If any of the following change, this document should be updated:

- `.env` or `.envrc` conventions
- bootstrap SSH username or key
- node names
- storage names
- bridge names
- subnet or gateway assumptions
- default VM hardware/layout assumptions
