{ config, ... }:

{
  age.secrets.acme-vars.file = ../../../secrets/acme-vars.age;

  security.acme = {
    acceptTerms = true;

    defaults = {
      environmentFile = config.age.secrets.acme-vars.path;
      dnsProvider = "cloudflare";
      email = "mattprovost6@gmail.com";
    };
  };
}
