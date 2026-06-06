{ config, lib, ... }:

let
  cfg = config.homelab;
  traefik-enable = cfg.traefik.enable;
  traefikServices = lib.filterAttrs (
    _: service:
      service.host != null
      && service.hostname != null
      && service.port != null
  ) cfg.services;
in
{
  options.homelab.traefik = {
    enable = lib.mkEnableOption "Traefik reverse proxy";

    webAddress = lib.mkOption {
      type = lib.types.str;
      default = ":80";
      description = "Address for the Traefik web entrypoint.";
    };

    websecureAddress = lib.mkOption {
      type = lib.types.str;
      default = ":443";
      description = "Address for the Traefik websecure entrypoint.";
    };
  };

  config = {
    networking.firewall.allowedTCPPorts = lib.mkIf cfg.traefik.enable [ 80 443 ];

    services.traefik = {
      enable = cfg.traefik.enable;

      staticConfigOptions = {
        entryPoints = {
          web = {
            address = cfg.traefik.webAddress;
            http.redirections.entryPoint = {
              to = "websecure";
              scheme = "https";
            };
          };
          websecure.address = cfg.traefik.websecureAddress;
        };
      };

      dynamicConfigOptions.http = {
        routers = lib.mapAttrs (
          name: service: {
            rule = "Host(`${service.hostname}`)";
            service = name;
            entryPoints = [ "websecure" ];
            tls = { };
          }
        ) traefikServices;

        services = lib.mapAttrs (
          _: service: {
            loadBalancer.servers = [
              {
                url = "${service.scheme}://${service.host.ipv4.address}:${toString service.port}";
              }
            ];
          }
        ) traefikServices;
      };
    };
  };
}
