{
  config,
  host,
  lib,
  pkgs,
  ...
}:
let
  serviceSubnet = "10.1.11.0/24";
  nodeAs = 64512;
  routerAs = 64512;
  routerAddress = host.ipam.ipv4.gateway;
in
{
  options.jorthaus.routing = {
    loopbackAddresses = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "IPv4 service addresses to assign to the loopback interface.";
    };
  };

  config =
    let
      loopbackAddresses = config.jorthaus.routing.loopbackAddresses;
    in
    {
      networking.firewall.allowedTCPPorts = [ 179 ];
      networking.firewall.allowedUDPPorts = [
        3784
        3785
      ];

      systemd.network.networks."10-loopback" = lib.mkIf (loopbackAddresses != [ ]) {
        matchConfig.Name = "lo";
        address = loopbackAddresses;
      };

      users.users.matt.extraGroups = [ "bird" ];

      environment.systemPackages = [
        (pkgs.writeShellScriptBin "jorthaus-service-ip" ''
          set -eu

          usage() {
            echo "usage: jorthaus-service-ip add|del ADDRESS[/PREFIX]" >&2
            exit 1
          }

          [ "$#" -eq 2 ] || usage

          action="$1"
          address="$2"

          case "$action" in
            add|del) ;;
            *) usage ;;
          esac

          exec ${pkgs.iproute2}/bin/ip address "$action" "$address" dev lo
        '')
      ];

      services.bird = {
        enable = true;
        config = ''
          router id ${host.ipam.ipv4.address};

          protocol device {}

          protocol direct direct_lo {
            ipv4;
            interface "lo";
          }

          protocol kernel kernel_v4 {
            learn;
            ipv4 {
              import none;
              export none;
            };
          }

          protocol bfd {
            interface "${host.ipam.interface}";
          }

          filter export_service_ipv4 {
            if net ~ [ ${serviceSubnet}{32,32} ] then accept;
            reject;
          }

          protocol bgp upstream {
            local as ${toString nodeAs};
            neighbor ${routerAddress} as ${toString routerAs};
            source address ${host.ipam.ipv4.address};
            bfd on;
            graceful restart on;

            ipv4 {
              import none;
              export filter export_service_ipv4;
            };
          }
        '';
      };
    };
}
