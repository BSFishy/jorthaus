# Option Inspection Examples

## Example: find what can be configured for `services.paperless.*`

```bash
nix eval --json .#nixosConfigurations.home.options.services.paperless
```

Then inspect a specific option:

```bash
nix eval .#nixosConfigurations.home.options.services.paperless.port.description
nix eval .#nixosConfigurations.home.options.services.paperless.port.type.description
```

Then inspect the effective configuration:

```bash
nix eval --json .#nixosConfigurations.home.config.services.paperless
```

## Example: find what the homelab wrapper exposes

```bash
nix eval --json .#nixosConfigurations.home.options.homelab.paperless
nix eval --json .#nixosConfigurations.home.config.homelab.paperless
```

## Example: inspect reverse-proxy registration

```bash
nix eval --json .#nixosConfigurations.home.config.homelab.services.paperless
```

## Example: inspect adjacent firewall config

```bash
nix eval --json .#nixosConfigurations.home.config.networking.firewall
```
