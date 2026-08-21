{ config, inputs, lib, options, ... }:

let
  cfg = config.jorthaus.persistence;
  persistenceOpts = options.environment.persistence.type.getSubOptions [ ];
in
{
  imports = [ inputs.impermanence.nixosModules.impermanence ];

  options.jorthaus.persistence = {
    files = lib.mkOption {
      type = persistenceOpts.files.type;
      default = [];
      description = "Additional files to make persistent";
    };

    directories = lib.mkOption {
      type = persistenceOpts.directories.type;
      default = [];
      description = "Additional directories to make persistent";
    };
  };

  config = {
    environment.persistence."/persistent" = {
      enable = true;
      hideMounts = true;

      files = [
        "/etc/machine-id"
      ] ++ cfg.files;

      directories = [
        "/etc/ssh"
        "/var/lib/nixos"
        "/var/lib/systemd"
        "/var/log"
      ] ++ cfg.directories;
    };
  };
}
