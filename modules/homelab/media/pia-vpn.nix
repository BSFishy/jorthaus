{ config, host, lib, pkgs, ... }:

let
  cfg = config.homelab;
  vpn = cfg.piaVpn;
  piaCertificateFile = pkgs.writeText "pia-ca.rsa.4096.crt" (builtins.readFile ../../../files/pia/ca.rsa.4096.crt);
  localRoutingRules = lib.concatMapStrings (
    cidr: ''
        [RoutingPolicyRule]
        To = ${cidr}
        Priority = 1100
        Table = main

''
  ) vpn.localCIDRs;
in
{
  options.homelab.piaVpn = {
    enable = lib.mkEnableOption "PIA WireGuard VPN for the media host";

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Environment file containing PIA_USER and PIA_PASS, typically provided by agenix.";
    };

    certificateFile = lib.mkOption {
      type = lib.types.path;
      default = piaCertificateFile;
      description = "Path to the PIA CA certificate used by the WireGuard bootstrap flow.";
    };

    interface = lib.mkOption {
      type = lib.types.str;
      default = "wg0";
      description = "WireGuard interface name used for the PIA tunnel.";
    };

    region = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Optional fixed PIA region id. Leave empty to auto-select a low-latency port-forwarding region.";
    };

    maxLatency = lib.mkOption {
      type = lib.types.float;
      default = 0.1;
      description = "Maximum acceptable latency, in seconds, when auto-selecting a PIA region.";
    };

    localCIDRs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "10.1.0.0/16"
        "192.168.2.0/24"
      ];
      description = "Destination CIDRs that should stay on the local network instead of being routed through the VPN.";
    };

  };

  config = lib.mkIf vpn.enable {
    assertions = [
      {
        assertion = vpn.environmentFile != null;
        message = "homelab.piaVpn.environmentFile must be set when homelab.piaVpn.enable = true.";
      }
    ];

    networking.enableIPv6 = false;
    networking.nameservers = [ host.ipv4.gateway ];
    networking.firewall.trustedInterfaces = [ vpn.interface ];

    services."pia-vpn" = {
      enable = true;
      inherit (vpn) certificateFile environmentFile interface region maxLatency;

      networkConfig = ''
        [Match]
        Name = ''${interface}

        [Network]
        Description = WireGuard PIA network interface
        Address = ''${peerip}/32

        [RoutingPolicyRule]
        From = ''${peerip}
        Priority = 900
        Table = 42

        [RoutingPolicyRule]
        To = ''${wg_ip}/32
        Priority = 1000

        [RoutingPolicyRule]
        To = ''${meta_ip}/32
        Priority = 1000

${localRoutingRules}        [RoutingPolicyRule]
        To = 0.0.0.0/0
        Priority = 2000
        Table = 42

        [Route]
        Destination = 0.0.0.0/0
        Table = 42
      '';
    };
  };
}
