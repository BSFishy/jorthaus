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

    "20-bond0-personal" = {
      netdevConfig = {
        Kind = "vlan";
        Name = "bond0.3";
      };
      vlanConfig.Id = 3;
    };

    "20-bond0-iot" = {
      netdevConfig = {
        Kind = "vlan";
        Name = "bond0.5";
      };
      vlanConfig.Id = 5;
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
        VLAN = [
          "bond0.3"
          "bond0.5"
        ];
      };

      # TODO: Enable dual-stack service networking.
      #
      # This requires a routed IPv6 prefix on the uplink, IPv6 BGP peering
      # between UniFi and Gaia, an IPv6 Cilium LoadBalancer IP pool, and a
      # dual-stack Traefik Service with fixed IPv4 and IPv6 VIPs. Publish the
      # resulting Traefik IPv6 VIP as an internal AAAA record and validate
      # both address families from LAN clients.
      ipv6AcceptRAConfig = {
        UseDNS = false;
        UseDomains = false;
      };
    };

    "20-ssdp-personal" = {
      matchConfig.Name = "bond0.3";
      linkConfig.RequiredForOnline = false;
      networkConfig.LinkLocalAddressing = "no";
    };

    "20-ssdp-iot" = {
      matchConfig.Name = "bond0.5";
      linkConfig.RequiredForOnline = false;
      networkConfig.LinkLocalAddressing = "no";
    };
  };
}
