---
name: add-service
description: Add a new homelab service module and enable it on the appropriate host or hosts. Use when introducing a service under modules/homelab/<host>/ or modules/homelab/shared/ with homelab.* options, enable-gated system changes, and optional homelab.services registry entries for externally routed services.
---

# Add Service

Use this skill when adding a new service to the homelab.

Always read these repo docs first:

- [`../../../docs/README.md`](../../../docs/README.md)
- [`../../../docs/routing-and-dns.md`](../../../docs/routing-and-dns.md)
- [`../../../docs/agenix.md`](../../../docs/agenix.md)
- [`../../../docs/environment.md`](../../../docs/environment.md)

Then verify the current repository state before editing:

- read `modules/homelab/default.nix`
- read the relevant host module in `modules/hosts/`
- read the host-specific import file under `modules/homelab/<host>/default.nix` if this is a host-scoped service
- read `inventory.nix` if the service needs host-aware routing via `homelab.services.*`
- use the internal reference notes in [references/option-gating-patterns.md](references/option-gating-patterns.md) for enable-gated configuration structure

## Goal

Most new services should get their own Nix module.

Usually that means one of these paths:

- `modules/homelab/<host>/<service>.nix` for host-scoped services
- `modules/homelab/shared/<service>.nix` for services intended to be usable on multiple hosts

The skill should also ensure the service is enabled in the relevant host module.

## Decision rule: host-scoped or shared

Create a host-scoped module when the service is effectively tied to one host role.

Examples:

- a reverse proxy that only belongs on the infra host
- a home-automation service that only belongs on the home host

Create a shared module when the same service may reasonably run on multiple hosts with the same option shape.

Examples:

- an exporter
- a backup agent
- a metrics agent
- a common utility service

## Design rules

### 1. Every service module should expose a homelab enable option

Use a homelab option such as:

```nix
options.homelab.paperless.enable = lib.mkEnableOption "Paperless";
```

That enable should gate any change that modifies system behavior, such as:

- enabling the service
- opening firewall ports
- creating users or groups
- writing config files
- registering timers
- enabling reverse proxy behavior

### 2. Configure the service outright, but only enable it when toggled on

Prefer module structure like this:

```nix
services.example = {
  enable = config.homelab.example.enable;
  settingA = "value";
  settingB = 1234;
};
```

or with explicit gating around unrelated changes:

```nix
networking.firewall.allowedTCPPorts = lib.mkIf cfg.example.enable [ 8080 ];
```

### 3. Use `homelab.*` options for homelab-internal configuration

If the service needs operator-facing settings, expose them under `homelab.<service>.*`.

Example pattern:

```nix
options.homelab.paperless = {
  enable = lib.mkEnableOption "Paperless";

  hostname = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    description = "External hostname for Paperless.";
  };

  port = lib.mkOption {
    type = lib.types.port;
    default = 8000;
    description = "Listen port for Paperless.";
  };
};
```

### 4. Register externally accessible services in `homelab.services.*`

If the service should be reachable through Traefik or other homelab consumers, populate the dynamic registry.

Pattern:

```nix
homelab.services.paperless = {
  host = inventory.docs;
  port = config.homelab.paperless.port;
  hostname = config.homelab.paperless.hostname;
  scheme = "http";
};
```

If the service is internal-only, do not add a registry entry unless another homelab integration needs it.

### 5. Enable the service in the intended host module

If the service is added for `docs`, make sure `modules/hosts/docs.nix` contains:

```nix
_:

{
  homelab.paperless.enable = true;
}
```

For shared modules, enable the service in each intended host module explicitly.

## Recommended workflow

### 1. Choose the destination path

Use one of these:

- `modules/homelab/<host>/<service>.nix`
- `modules/homelab/shared/<service>.nix`

### 2. Add or update imports

If you create a host-scoped module, add it to that host namespace's `default.nix` import list.

Example:

```nix
_:

{
  imports = [
    ./paperless.nix
  ];
}
```

If you create a shared module, make sure it is imported from the appropriate shared aggregation point. If no shared aggregation point exists yet, create one carefully and then include it from the top-level homelab module.

### 3. Implement the service module

Use the module templates in the reference files.

If you need to discover which upstream NixOS options exist for a service before implementing it, use the `configure-nixos-service` skill.

Host-scoped example:

```nix
{ config, inventory, lib, ... }:

let
  cfg = config.homelab;
in
{
  options.homelab.paperless = {
    enable = lib.mkEnableOption "Paperless";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8000;
      description = "Listen port for Paperless.";
    };
  };

  config = {
    homelab.services.paperless = lib.mkIf cfg.paperless.enable {
      host = inventory.docs;
      port = cfg.paperless.port;
      hostname = "paperless.jort.haus";
      scheme = "http";
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.paperless.enable [ cfg.paperless.port ];

    services.paperless = {
      enable = cfg.paperless.enable;
      address = "0.0.0.0";
      port = cfg.paperless.port;
    };
  };
}
```

Also see:

- [references/host-service-template.nix](references/host-service-template.nix)
- [references/shared-service-template.nix](references/shared-service-template.nix)
- [references/host-enable-snippet.nix](references/host-enable-snippet.nix)

### 4. Enable it in the host module

Add the new service enable in the relevant host file under `modules/hosts/`.

### 5. Update DNS/routing docs when externally accessible

If the service is externally accessible:

- update [`../../../docs/routing-and-dns.md`](../../../docs/routing-and-dns.md)
- ensure the hostname plan matches split-horizon expectations
- note any Cloudflare/public exposure expectations

### 6. Update secret handling if needed

If the service needs credentials or tokens:

- add homelab-facing options for secret file paths or related config
- wire secrets through agenix as appropriate
- update [`../../../docs/agenix.md`](../../../docs/agenix.md) if the secret workflow changes materially

## Validation checklist

After edits, verify:

- the module is imported from the correct `default.nix`
- the module defines `homelab.<service>.enable`
- enable-gated behavior is actually gated
- the host module enables the service where intended
- `homelab.services.<name>` is populated if the service should be externally reachable
- docs were updated if the service changes routing, DNS, or secret workflows

Useful checks:

```bash
nix eval .#nixosConfigurations.<host>.options.homelab.<service>.enable.description
nix eval .#nixosConfigurations.<host>.config.homelab.<service>.enable
nix eval --json .#nixosConfigurations.<host>.config.homelab.services
```

If the user wants deployment next, suggest:

```bash
just switch <host>
```

and, if infrastructure or DNS Terraform changed:

```bash
just plan
just apply
```

## Common mistakes to avoid

- implementing service logic directly in a host module instead of a service module
- forgetting to add the new module to the relevant import list
- using raw top-level options instead of `homelab.*` where homelab-local configuration is intended
- forgetting to gate firewall changes or other side effects on the service enable option
- forgetting to enable the new service in the intended host module
- forgetting to add `homelab.services.*` for externally accessible services
- exposing a service externally without updating routing/DNS docs

## Reference files

- [references/host-service-template.nix](references/host-service-template.nix)
- [references/shared-service-template.nix](references/shared-service-template.nix)
- [references/host-enable-snippet.nix](references/host-enable-snippet.nix)
- [references/service-addition-checklist.md](references/service-addition-checklist.md)
- [references/option-gating-patterns.md](references/option-gating-patterns.md)
