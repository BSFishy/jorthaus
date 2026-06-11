---
name: add-host
description: Add a new deployable host to this homelab repo. Use when creating a new VM/host definition so inventory.nix and a host module under modules/hosts/ stay in sync with the inventory-driven flake and Terraform workflow.
---

# Add Host

Use this skill when adding a new deployable host to the homelab.

Always read these repo docs first:

- [`../../../docs/disk-images.md`](../../../docs/disk-images.md)
- [`../../../docs/environment.md`](../../../docs/environment.md)
- [`../../../docs/README.md`](../../../docs/README.md)

Then verify the current repository state before editing:

- read `inventory.nix`
- read the existing files in `modules/hosts/`
- read `flake.nix`
- read `justfile`

## Goal

A new host should usually result in both of these changes:

1. a new entry in `inventory.nix`
2. a new host module at `modules/hosts/<host>.nix`

The flake already derives `nixosConfigurations` and Terraform vars from `inventory.nix`, so the main job is to add correct inventory metadata and a minimal host module.

## Principles

- `inventory.nix` is only for deployable hosts
- host-specific NixOS config belongs in `modules/hosts/`
- keep host modules concise
- prefer shared modules for reusable behavior and host modules for enable/config toggles
- preserve the existing inventory schema unless the user explicitly asks to change it
- update docs if the new host changes documented assumptions

## Workflow

### 1. Gather the new host details

Before editing, identify:

- host attribute name, such as `media`
- `hostName`
- IPv4 address
- prefix length
- gateway
- Proxmox node name
- CPU cores
- memory
- disk size
- machine type
- BIOS/firmware type
- bridge
- image datastore
- VM disk datastore
- whether the host needs any host-specific services enabled immediately

If the user did not provide these, ask or infer only from existing documented defaults after verifying them.

### 2. Add an inventory entry

Add a new attrset entry to `inventory.nix` matching the current schema.

Use this example pattern:

```nix
media = {
  hostName = "media";

  ipv4 = {
    address = "10.1.4.12";
    prefixLength = 16;
    gateway = "10.1.0.1";
  };

  proxmox = {
    nodeName = "gaia-05";
    cpuCores = 2;
    memory = 4096;
    diskSize = 40;
    machine = "q35";
    bios = "ovmf";
    bridge = "vmbr0";
    imageDatastore = "local";
    vmDiskDatastore = "local-lvm";
  };

  modules = [
    ./modules/hosts/media.nix
  ];
};
```

Also see the reusable template in [references/inventory-entry-template.nix](references/inventory-entry-template.nix).

### 3. Create the host module

Create `modules/hosts/<host>.nix`.

A minimal host module can be very small and should primarily enable the host's intended homelab services.

Example:

```nix
_:

{
  homelab = {
    jellyfin.enable = true;
    scrape.enable = true;
  };
}
```

Also see [references/host-module-template.nix](references/host-module-template.nix).

### 4. Wire any shared or host-scoped services intentionally

If the host should run existing services:

- enable them in the new host module
- do not duplicate service logic in the host module
- keep service implementation in homelab modules

If the host also needs a brand-new service, use the `add-service` skill after the host exists.

### 5. Check whether secrets support is needed

If the new host must decrypt secrets:

- consult [`../../../docs/agenix.md`](../../../docs/agenix.md)
- after the host exists, collect its SSH host public key
- add that key to `secrets.nix`
- add the host to the recipient lists for the secrets it needs

Do not invent secret wiring unless the user asked for it.

### 6. Update docs when assumptions change

Update docs when the new host changes documented reality, especially:

- [`../../../docs/environment.md`](../../../docs/environment.md) for inventory or network assumptions
- [`../../../docs/routing-and-dns.md`](../../../docs/routing-and-dns.md) if the host changes ingress/DNS behavior
- [`../../../docs/agenix.md`](../../../docs/agenix.md) if host secret handling changes

## Validation checklist

After making changes, verify:

- `inventory.nix` parses and includes the new host
- `modules/hosts/<host>.nix` exists
- the new inventory entry points at the new host module path
- the host module uses valid `homelab.*` options
- documented network/storage/node assumptions still match reality

Useful checks:

```bash
nix eval --json .#inventory
nix eval .#nixosConfigurations.<host>.config.networking.hostName
nix eval --json .#terraform.vars
```

If the user wants provisioning immediately, suggest the normal workflow:

```bash
just plan
just apply
just switch <host>
```

## Common mistakes to avoid

- adding `bootstrap` to `inventory.nix`
- putting host-specific config directly into shared modules without a reason
- forgetting to create the host module referenced by inventory
- changing inventory schema unintentionally
- forgetting to update docs when network or deployment assumptions change

## Reference files

- [references/inventory-entry-template.nix](references/inventory-entry-template.nix)
- [references/host-module-template.nix](references/host-module-template.nix)
- [references/host-addition-checklist.md](references/host-addition-checklist.md)
