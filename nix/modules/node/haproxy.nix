{ config, lib, ... }:
let
  inherit (lib)
    concatLines
    concatMapStringsSep
    flatten
    mapAttrsToList
    mkEnableOption
    mkIf
    mkOption
    optionalString
    types
    unique
    ;

  cfg = config.jorthaus.haproxy;

  enabledServices = lib.filterAttrs (_: service: service.enable) cfg.services;

  renderServer = server:
    "    server ${server.name} ${server.address}:${toString server.port}${optionalString (server.options != "") " ${server.options}"}";

  renderService = name: service:
    let
      backendName = "${name}_backend";
    in
    ''
      frontend ${name}
        bind ${service.address}:${toString service.port}
        mode ${service.mode}
      ${optionalString (service.frontendConfig != "") (concatMapStringsSep "\n" (line: "  ${line}") (lib.splitString "\n" service.frontendConfig))}
        default_backend ${backendName}

      backend ${backendName}
        mode ${service.mode}
      ${optionalString (service.backendConfig != "") (concatMapStringsSep "\n" (line: "  ${line}") (lib.splitString "\n" service.backendConfig))}
      ${concatLines (map renderServer service.backends)}
    '';
in
{
  options.jorthaus.haproxy = {
    services = mkOption {
      default = { };
      type = types.attrsOf (
        types.submodule {
          options = {
            enable = mkEnableOption "this HAProxy frontend";

            address = mkOption {
              type = types.str;
              description = "Service IPv4 address bound by HAProxy.";
            };

            port = mkOption {
              type = types.port;
              description = "Service port bound by HAProxy.";
            };

            mode = mkOption {
              type = types.enum [ "tcp" "http" ];
              default = "tcp";
              description = "HAProxy mode for this frontend/backend pair.";
            };

            frontendConfig = mkOption {
              type = types.lines;
              default = "";
              description = "Additional HAProxy directives inserted into the frontend stanza.";
            };

            backendConfig = mkOption {
              type = types.lines;
              default = "";
              description = "Additional HAProxy directives inserted into the backend stanza.";
            };

            backends = mkOption {
              default = [ ];
              type = types.listOf (
                types.submodule {
                  options = {
                    name = mkOption {
                      type = types.str;
                      description = "HAProxy backend server name.";
                    };

                    address = mkOption {
                      type = types.str;
                      description = "IPv4 address or hostname for the backend server.";
                    };

                    port = mkOption {
                      type = types.port;
                      description = "Backend server port.";
                    };

                    options = mkOption {
                      type = types.str;
                      default = "";
                      description = "Additional raw HAProxy server options appended to the server line.";
                    };
                  };
                }
              );
              description = "Backend servers for this HAProxy service.";
            };

            after = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "Additional systemd ordering dependencies for haproxy.service.";
            };

            wants = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "Additional systemd wants dependencies for haproxy.service.";
            };
          };
        }
      );
      description = "Jorthaus-managed HAProxy frontend/backend services.";
    };
  };

  config = mkIf (enabledServices != { }) {
    assertions = mapAttrsToList (
      name: service: {
        assertion = service.backends != [ ];
        message = "jorthaus.haproxy.services.${name} must define at least one backend.";
      }
    ) enabledServices;

    jorthaus.routing.loopbackAddresses = unique (
      flatten (
        mapAttrsToList (_: service: [ "${service.address}/32" ]) enabledServices
      )
    );

    networking.firewall.allowedTCPPorts = unique (map (service: service.port) (builtins.attrValues enabledServices));

    services.haproxy = {
      enable = true;
      config = ''
        defaults
          timeout connect 5s
          timeout client 1m
          timeout server 1m

      ${concatMapStringsSep "\n" (name: renderService name enabledServices.${name}) (builtins.attrNames enabledServices)}
      '';
    };

    systemd.services.haproxy.after = [ "network-online.target" ] ++ unique (flatten (mapAttrsToList (_: service: service.after) enabledServices));
    systemd.services.haproxy.wants = [ "network-online.target" ] ++ unique (flatten (mapAttrsToList (_: service: service.wants) enabledServices));
  };
}
