{ lib, host, ... }:
let
  ipam = host.ipam;
  ipv4 = ipam.ipv4;
  nameservers = ipam.nameservers;
  uplinkInterface = "bond0";
in
{
  networking.hostName = host.hostname;
  networking.useDHCP = lib.mkForce false;
  networking.useNetworkd = true;

  systemd.network.enable = true;
  systemd.network.wait-online.extraArgs = [ "--interface=${uplinkInterface}" ];
  services.resolved.enable = true;

  networking.nameservers = nameservers;

  systemd.network.netdevs = {
    "10-bond0" = {
      netdevConfig = {
        Kind = "bond";
        Name = "bond0";
      };
      bondConfig.Mode = "active-backup";
    };
  };

  systemd.network.networks = {
    "10-bond-member-${ipam.interface}" = {
      matchConfig.Name = ipam.interface;
      networkConfig.Bond = "bond0";
    };

    "10-uplink" = {
      matchConfig.Name = uplinkInterface;
      address = lib.optional (ipv4 != null) "${ipv4.address}/${toString ipv4.prefixLength}";
      dns = nameservers;
      routes = lib.optional (ipv4 != null && ipv4 ? gateway) {
        Gateway = ipv4.gateway;
      };

      networkConfig = {
        DHCP = "no";
        DNSDefaultRoute = false;
      };

      ipv6AcceptRAConfig = {
        UseDNS = false;
        UseDomains = false;
      };
    };
  };
}
