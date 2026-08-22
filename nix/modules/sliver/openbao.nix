{
  config,
  host,
  lib,
  ...
}:

let
  cfg = host.slivers.openbao or { };
  enabled = cfg.enable or false;
  serviceAddress = "10.1.11.10";
  certName = "openbao-${host.hostname}";
  nodeDnsName = "${host.hostname}.node.jort.haus";
  internalApiDnsName = "openbao.service.jort.haus";
  externalApiDnsName = "openbao.jort.haus";
  certDir = config.security.acme.certs.${certName}.directory;
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

    security.acme.certs.${certName} = {
      domain = nodeDnsName;
      extraDomainNames = [
        internalApiDnsName
        externalApiDnsName
      ];
      group = "openbao";
      reloadServices = [ "openbao.service" ];
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
      after = [ "acme-order-renew-${certName}.service" ];
      wants = [ "acme-order-renew-${certName}.service" ];
      unitConfig = {
        RequiresMountsFor = "/srv/openbao";
        ConditionPathExists = "${certDir}/fullchain.pem";
      };
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

        api_addr = "https://${externalApiDnsName}:8200";
        cluster_addr = "https://${nodeDnsName}:8201";

        listener.default = {
          type = "tcp";
          address = "[::]:8200";
          cluster_address = "[::]:8201";
          tls_cert_file = "${certDir}/fullchain.pem";
          tls_key_file = "${certDir}/key.pem";
        };

        storage.raft = {
          node_id = host.hostname;
          path = "/srv/openbao";
        };
      };
    };
  };
}
