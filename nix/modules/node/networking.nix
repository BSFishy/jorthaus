{ lib, host, ... }:
let
  ipam = host.ipam;
  ipv4 = ipam.ipv4 or null;
  nameservers =
    ipam.nameservers or (if ipv4 != null && ipv4 ? dnsServer then ipv4.dnsServer else [ ]);
in
{
  networking.hostName = host.hostname;
  networking.useDHCP = lib.mkForce false;
  networking.useNetworkd = true;

  systemd.network.enable = true;
  services.resolved.enable = true;

  networking.nameservers = nameservers;

  systemd.network.networks."10-uplink" = {
    matchConfig.Name = ipam.interface;
    networkConfig.DHCP = "no";
    address = lib.optional (ipv4 != null) "${ipv4.address}/${toString ipv4.prefixLength}";
    routes = lib.optional (ipv4 != null && ipv4 ? gateway) {
      Gateway = ipv4.gateway;
    };
  };
}
