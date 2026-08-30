{
  config,
  host,
  lib,
  pkgs,
  ...
}:
let
  infraServiceSubnet = "10.1.11.0/24";
  kubernetesLoadBalancerSubnet = "10.1.12.0/24";
  nodeAs = 64512;
  routerAs = 64512;
  routerAddress = host.ipam.ipv4.gateway;
  uplinkInterface = "bond0";
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

      systemd.services.bird = {
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
      };

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

      # TODO: Gate service IP advertisement on local service health instead of
      # exporting every configured loopback address unconditionally. Anycast
      # endpoints should withdraw when the local daemon or proxy is unhealthy.
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
            interface "${uplinkInterface}";
          }

          # TODO: Replace the coarse whole-subnet Kubernetes advertisement with
          # a cleaner route-server / route-reflector design so Kubernetes
          # LoadBalancer reachability is decoupled from node-local origination.
          filter export_service_ipv4 {
            if net ~ [ ${infraServiceSubnet}{32,32} ] then accept;
            if net = ${kubernetesLoadBalancerSubnet} then accept;
            reject;
          }

          # TODO: Replace this aggregate Kubernetes LoadBalancer route with a
          # more precise advertisement path, ideally via dedicated route-server
          # infrastructure or Cilium-native peering once the architecture is
          # worth the extra moving parts.
          protocol static kubernetes_load_balancers_v4 {
            ipv4;
            route ${kubernetesLoadBalancerSubnet} blackhole;
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
