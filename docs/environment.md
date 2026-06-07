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
