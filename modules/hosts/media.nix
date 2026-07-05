{ config, ... }:

{
  homelab = {
    flaresolverr.enable = true;
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
    recyclarr = {
      enable = true;
      sonarrApiKeyFile = config.age.secrets.recyclarr-sonarr-api-key.path;
      radarrApiKeyFile = config.age.secrets.recyclarr-radarr-api-key.path;
    };
    sonarr.enable = true;
  };

  age.secrets.pia-media-env = {
    file = ../../secrets/pia-media.env.age;
    mode = "0400";
  };

  age.secrets.recyclarr-sonarr-api-key = {
    file = ../../secrets/recyclarr-sonarr-api-key.age;
    mode = "0400";
  };

  age.secrets.recyclarr-radarr-api-key = {
    file = ../../secrets/recyclarr-radarr-api-key.age;
    mode = "0400";
  };
}
