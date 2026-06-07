{ config, lib, ... }:

let
  cfg = config.homelab;
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

    cloudflareCredentialsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Path to an environment file containing Cloudflare credentials for Traefik DNS challenge usage, typically provided by agenix.";
    };

    acmeEmail = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Email address used for ACME registration.";
    };

    acmeResolverName = lib.mkOption {
      type = lib.types.str;
      default = "cloudflare";
      description = "Name of the Traefik ACME resolver used for DNS challenge certificates.";
    };
  };

  config = {
    networking.firewall.allowedTCPPorts = lib.mkIf cfg.traefik.enable [ 80 443 ];

    services.traefik = {
      enable = cfg.traefik.enable;
      environmentFiles = lib.optional (cfg.traefik.cloudflareCredentialsFile != null) cfg.traefik.cloudflareCredentialsFile;

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
      } // lib.optionalAttrs (cfg.traefik.cloudflareCredentialsFile != null && cfg.traefik.acmeEmail != null) {
        certificatesResolvers.${cfg.traefik.acmeResolverName}.acme = {
          email = cfg.traefik.acmeEmail;
          storage = "${config.services.traefik.dataDir}/acme.json";
          dnsChallenge.provider = "cloudflare";
        };
      };

      dynamicConfigOptions.http = {
        routers = lib.mapAttrs (
          name: service: {
            rule = "Host(`${service.hostname}`)";
            service = name;
            entryPoints = [ "websecure" ];
            tls =
              if cfg.traefik.cloudflareCredentialsFile != null && cfg.traefik.acmeEmail != null then
                {
                  certResolver = cfg.traefik.acmeResolverName;
                }
              else
                { };
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
