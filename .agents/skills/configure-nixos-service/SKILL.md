---
name: configure-nixos-service
description: Explore NixOS module options and effective configuration for a service or subsystem. Use when figuring out how to configure services.<name>.*, homelab.* options, firewall settings, systemd units, or other NixOS options before or after adding a service.
---

# Configure NixOS Service

Use this skill when you need to discover what options exist and how a service should be configured.

This skill is not limited to adding new services. It is for general NixOS-side option discovery and configuration work.

## Goal

Given a host and a target option namespace, figure out:

- what options exist
- what types and defaults they have
- what the current effective config is for a host
- what related options are commonly configured together
- whether configuration belongs under `services.*`, `networking.*`, `systemd.*`, or `homelab.*`

## Inputs to gather

Before starting, identify:

- the host to evaluate, such as `home` or `infra`
- the option namespace, such as:
  - `services.paperless`
  - `services.home-assistant`
  - `services.traefik`
  - `homelab.paperless`
  - `networking.firewall`
  - `systemd.services.paperless`

If the target namespace is not known, derive it from the service name and verify it by exploration.

## Primary exploration commands

These are the most useful commands for exploring options in this repo.

### Show the full option subtree

```bash
nix eval --json .#nixosConfigurations.<host>.options.services.paperless
```

### Show a specific option description

```bash
nix eval .#nixosConfigurations.<host>.options.services.paperless.enable.description
```

### Show a specific option type

```bash
nix eval .#nixosConfigurations.<host>.options.services.paperless.port.type.description
```

### Show the effective config subtree for a host

```bash
nix eval --json .#nixosConfigurations.<host>.config.services.paperless
```

### Show the effective value of one option

```bash
nix eval .#nixosConfigurations.<host>.config.services.paperless.enable
```

### Explore homelab-specific options

```bash
nix eval --json .#nixosConfigurations.<host>.options.homelab.paperless
nix eval --json .#nixosConfigurations.<host>.config.homelab.paperless
```

### Explore generated external routing registry

```bash
nix eval --json .#nixosConfigurations.<host>.config.homelab.services
```

## Useful search commands

Use ripgrep to find where options or services are declared in the repo.

Important caveat:

- ripgrep results are helpful, but not always conclusive for Nix
- Nix attribute paths are often split across nested attrsets, `let` bindings, merges, `mkIf`, and imports
- because of that, a simple text search may miss valid configuration paths or related option definitions
- `nix eval` against `options.*` and `config.*` is often more comprehensive for discovering what exists, even though it does not directly tell you the source file location

### Find homelab option declarations

```bash
rg -n "options\\.homelab\\.paperless|homelab\\.paperless|homelab\\.services\\.paperless" modules
```

### Find NixOS service configuration usage in the repo

```bash
rg -n "services\\.paperless|systemd\\.services\\.paperless|networking\\.firewall" modules
```

### Find host enablement

```bash
rg -n "paperless\\.enable = true|homelab\\.paperless" modules/hosts
```

## Suggested workflow

### 1. Start from the option subtree

First inspect the options subtree for the target namespace.

Example:

```bash
nix eval --json .#nixosConfigurations.home.options.services.home-assistant
```

This is useful for learning:

- available child options
- descriptions
- defaults
- types

### 2. Inspect the effective config

Then inspect what the evaluated host configuration actually contains.

Example:

```bash
nix eval --json .#nixosConfigurations.home.config.services.home-assistant
```

This tells you what is currently being set after module evaluation.

### 3. Inspect adjacent namespaces

Many services require configuration in adjacent namespaces. Common places to inspect:

- `networking.firewall`
- `systemd.services`
- `users.users`
- `users.groups`
- `services.<name>`
- `homelab.<name>`
- `homelab.services`

Examples:

```bash
nix eval --json .#nixosConfigurations.infra.config.networking.firewall
nix eval --json .#nixosConfigurations.infra.config.services.traefik
nix eval --json .#nixosConfigurations.infra.config.homelab.traefik
```

### 4. Search the repository for existing patterns

Look for similar modules or service styles in the repo.

Example searches:

```bash
rg -n "mkEnableOption|allowedTCPPorts|homelab\\.services" modules/homelab
rg -n "services\\.[a-zA-Z0-9_-]+\\.enable = config\\.homelab" modules/homelab
```

### 5. Translate findings into homelab-facing config

When adding or refining a service module:

- keep service-specific configuration under `services.*` when that is the upstream NixOS interface
- expose operator-facing knobs under `homelab.<service>.*` when the homelab needs a stable local abstraction
- gate side effects on `homelab.<service>.enable`

## Common command recipes

### Discover all top-level service namespaces

```bash
nix eval --json .#nixosConfigurations.<host>.options.services | jq 'keys'
```

### Discover all top-level homelab namespaces

```bash
nix eval --json .#nixosConfigurations.<host>.options.homelab | jq 'keys'
```

### Check whether a service exposes an enable option

```bash
nix eval .#nixosConfigurations.<host>.options.services.paperless.enable.description
```

### Check whether a homelab wrapper exposes an enable option

```bash
nix eval .#nixosConfigurations.<host>.options.homelab.paperless.enable.description
```

### See whether a route is registered for a host

```bash
nix eval --json .#nixosConfigurations.<host>.config.homelab.services.paperless
```

## Interpretation guidance

When reading option metadata:

- `description` explains intent
- `default` shows what happens when you do nothing
- `type` constrains what values are valid
- `example` may exist for some upstream options

When reading evaluated config:

- prefer `config.*` to answer "what is this host actually set to?"
- prefer `options.*` to answer "what could I configure here?"

## Common mistakes to avoid

- looking only at repo code and not at evaluated `options.*`
- looking only at `options.*` and not at evaluated `config.*`
- configuring `services.*` directly in a host module when the repo should instead expose `homelab.<service>.*`
- forgetting related namespaces like firewall, reverse proxy routing, secrets, or systemd dependencies

## Reference files

- [references/command-recipes.md](references/command-recipes.md)
- [references/option-inspection-examples.md](references/option-inspection-examples.md)
- [references/decision-guide.md](references/decision-guide.md)
