{ config, host, ... }:
let
  nodeCertName = "node-${host.hostname}";
  nodeDnsName = "${host.hostname}.node.jort.haus";
in
{
  age.secrets.acme-vars.file = ../../../secrets/acme-vars.age;

  users.groups.cert = { };

  security.acme = {
    acceptTerms = true;

    defaults = {
      environmentFile = config.age.secrets.acme-vars.path;
      dnsProvider = "cloudflare";
      email = "mattprovost6@gmail.com";
    };

    certs.${nodeCertName} = {
      domain = nodeDnsName;
      group = "cert";
    };
  };
}
