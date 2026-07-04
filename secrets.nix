let
  matt = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGOo7iBDgCXP99GA4NStJudsWkZQVaA9iDqDo6IQF2ve";

  # Add deployed host SSH host public keys here once they exist so those hosts
  # can decrypt the secrets addressed to them.
  infra = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILKvv/mX+U/Ouxjc145bSp4PM5j9t+TlrHhbPSaJ4wX7";
  media = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP++7SF2K99o/BOIgo/smI0PE0fUCTg+ryYSyuFh8K2N";
in
{
  "secrets/cloudflare-token.env.age".publicKeys = [ matt infra ];
  "secrets/pia-media.env.age".publicKeys = [ matt media ];
  "secrets/recyclarr-sonarr-api-key.age".publicKeys = [ matt media ];
  "secrets/recyclarr-radarr-api-key.age".publicKeys = [ matt media ];
}
