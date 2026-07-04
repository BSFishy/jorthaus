{ config, ... }:

{
  networking.enableIPv6 = true;
  networking.tempAddresses = "disabled";

  environment.etc."systemd/network/10-cloud-init-eth0.network.d/10-ipv6-slaac.conf".text = ''
    [Network]
    IPv6AcceptRA=yes
    IPv6PrivacyExtensions=no
  '';

  homelab = {
    traefik = {
      enable = true;
      cloudflareCredentialsFile = config.age.secrets.cloudflare-token-env.path;
      acmeEmail = "mattprovost6@gmail.com";
    };
  };

  age.secrets.cloudflare-token-env = {
    file = ../../secrets/cloudflare-token.env.age;
    owner = "traefik";
    group = "traefik";
    mode = "0400";
  };
}
