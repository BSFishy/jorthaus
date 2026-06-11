# Option-gating Patterns

Use these patterns when building service modules.

## Enable option

```nix
options.homelab.paperless = {
  enable = lib.mkEnableOption "Paperless";
};
```

## Service enable tied to homelab option

```nix
services.paperless = {
  enable = config.homelab.paperless.enable;
  address = "0.0.0.0";
  port = config.homelab.paperless.port;
};
```

## Side effects gated with mkIf

```nix
networking.firewall.allowedTCPPorts = lib.mkIf config.homelab.paperless.enable [
  config.homelab.paperless.port
];
```

## External routing registration

```nix
homelab.services.paperless = lib.mkIf config.homelab.paperless.enable {
  host = inventory.docs;
  port = config.homelab.paperless.port;
  hostname = "paperless.jort.haus";
  scheme = "http";
};
```

## Import list update for host-scoped service

```nix
_:

{
  imports = [
    ./paperless.nix
  ];
}
```
