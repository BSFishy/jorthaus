{ lib, ... }:

{
  options.homelab = {
    services = lib.mkOption {
      default = { };
      description = "Homelab service registry used for service-specific defaults and reverse proxy generation.";
      type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
        options = {
          host = lib.mkOption {
            type = lib.types.nullOr lib.types.attrs;
            default = null;
            description = "Inventory host definition that serves ${name}.";
          };

          port = lib.mkOption {
            type = lib.types.nullOr lib.types.port;
            default = null;
            description = "Port where ${name} should be reached by other homelab services.";
          };

          hostname = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Hostname Traefik should route for ${name}.";
          };

          scheme = lib.mkOption {
            type = lib.types.enum [ "http" "https" ];
            default = "http";
            description = "Protocol Traefik should use when proxying to ${name}.";
          };
        };
      }));
    };
  };

  imports = [
    ./home
    ./infra
    ./media
  ];
}
