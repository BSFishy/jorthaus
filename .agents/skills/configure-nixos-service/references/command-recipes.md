# Command Recipes

## Explore available service namespaces

```bash
nix eval --json .#nixosConfigurations.home.options.services | jq 'keys'
```

## Explore one service's option tree

```bash
nix eval --json .#nixosConfigurations.home.options.services.paperless
```

## Explore one service's effective config

```bash
nix eval --json .#nixosConfigurations.home.config.services.paperless
```

## Explore one homelab wrapper option tree

```bash
nix eval --json .#nixosConfigurations.home.options.homelab.paperless
```

## Explore the evaluated homelab wrapper config

```bash
nix eval --json .#nixosConfigurations.home.config.homelab.paperless
```

## Explore generated routing entries

```bash
nix eval --json .#nixosConfigurations.infra.config.homelab.services
```

## Search the repo for related config

```bash
rg -n "paperless|home-assistant|traefik|allowedTCPPorts|mkEnableOption" modules
```
