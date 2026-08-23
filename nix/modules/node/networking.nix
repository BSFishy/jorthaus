{ lib, host, ... }:
let
  ipam = host.ipam;
  ipv4 = ipam.ipv4;
  nameservers = ipam.nameservers;
in
{
  networking.hostName = host.hostname;
  networking.useDHCP = lib.mkForce false;
  networking.useNetworkd = true;

  systemd.network.enable = true;
  systemd.network.wait-online.extraArgs = [ "--interface=${ipam.interface}" ];
  services.resolved.enable = true;

  networking.nameservers = nameservers;

  systemd.network.networks."10-uplink" = {
    matchConfig.Name = ipam.interface;
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
}
