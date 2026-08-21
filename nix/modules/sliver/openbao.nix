{ host, lib, ... }:

let
  cfg = host.slivers.openbao or { };
  enabled = cfg.enable or false;
  ipv4Address = host.ipam.ipv4.address;
  serviceAddress = "10.1.11.10";
in
{
  config = lib.mkIf enabled {
    users = {
      users.openbao = {
        isSystemUser = true;
        group = "openbao";
      };

      groups.openbao = { };
    };

    jorthaus.persistence.directories = [
      {
        directory = "/srv/openbao";
        user = "openbao";
        group = "openbao";
        mode = "0700";
      }
    ];

    jorthaus.routing.loopbackAddresses = [ "${serviceAddress}/32" ];

    # TODO: currently not accepting connections on port 8201. need to look into
    # that.
    networking.firewall.allowedTCPPorts = [
      8200
      8201
    ];

    systemd.services.openbao = {
      unitConfig.RequiresMountsFor = "/srv/openbao";
      serviceConfig = {
        DynamicUser = lib.mkForce false;
        User = lib.mkForce "openbao";
        Group = lib.mkForce "openbao";
        ReadWritePaths = [ "/srv/openbao" ];
      };
    };

    services.openbao = {
      enable = true;
      settings = {
        ui = true;

        # TODO: use dns records rather than ips for proper tls
        api_addr = "https://${serviceAddress}:8200";
        cluster_addr = "https://${ipv4Address}:8201";

        listener.default = {
          type = "tcp";
          address = "[::]:8200";
          cluster_address = "[::]:8201";
        };

        storage.raft = {
          node_id = host.hostname;
          path = "/srv/openbao";
        };
      };
    };
  };
}
