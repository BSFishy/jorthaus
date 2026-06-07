{ config, ... }:

{
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
