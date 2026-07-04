{ config, ... }:

{
  homelab = {
    jellyfin.enable = true;
    media-storage.enable = true;
    piaVpn = {
      enable = true;
      environmentFile = config.age.secrets.pia-media-env.path;
      region = "gt_guatemala-pf";
      maxLatency = 10.0;
    };
    qbittorrent.enable = true;
    prowlarr.enable = true;
    radarr.enable = true;
    sonarr.enable = true;
  };

  age.secrets.pia-media-env = {
    file = ../../secrets/pia-media.env.age;
    mode = "0400";
  };
}
