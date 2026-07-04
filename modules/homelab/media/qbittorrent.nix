{ config, lib, ... }:

let
  cfg = config.homelab;
  qbt = cfg.qbittorrent;
in
{
  options.homelab.qbittorrent = {
    enable = lib.mkEnableOption "qBittorrent on the media host";

    webuiPort = lib.mkOption {
      type = lib.types.port;
      default = 8081;
      description = "qBittorrent Web UI port on the media host.";
    };

    downloadDir = lib.mkOption {
      type = lib.types.str;
      default = "/srv/media/downloads";
      description = "Root directory for qBittorrent downloads on the media disk.";
    };
  };

  config = lib.mkIf qbt.enable {
    networking.firewall.allowedTCPPorts = [ qbt.webuiPort ];

    services.qbittorrent = {
      enable = true;
      webuiPort = qbt.webuiPort;
      openFirewall = false;
      extraArgs = [ "--confirm-legal-notice" ];
      serverConfig = {
        LegalNotice.Accepted = true;
        Preferences = {
          WebUI = {
            Address = "*";
            LocalHostAuth = false;
            AuthSubnetWhitelistEnabled = true;
            AuthSubnetWhitelist = "0.0.0.0/0,::/0";
          };
        };
      };
    };

    systemd.services.qbittorrent-media-dirs = {
      description = "Prepare media download directories for qBittorrent";
      after = [ "srv-media.mount" ];
      requires = [ "srv-media.mount" ];
      before = [ "qbittorrent.service" ];
      requiredBy = [ "qbittorrent.service" ];
      serviceConfig.Type = "oneshot";
      script = ''
        install -d -m 0750 -o qbittorrent -g qbittorrent ${qbt.downloadDir}
        install -d -m 0750 -o qbittorrent -g qbittorrent ${qbt.downloadDir}/complete
      '';
    };

    systemd.services.qbittorrent = {
      after = [
        "pia-vpn.service"
        "qbittorrent-media-dirs.service"
      ];
      requires = [
        "pia-vpn.service"
        "qbittorrent-media-dirs.service"
      ];
      bindsTo = [ "pia-vpn.service" ];
      partOf = [ "pia-vpn.service" ];
    };
  };
}
