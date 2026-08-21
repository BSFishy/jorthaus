{
  config,
  inputs,
  lib,
  options,
  ...
}:

let
  cfg = config.jorthaus.persistence;
  persistenceOpts = options.environment.persistence.type.getSubOptions [ ];
  fileType = lib.types.oneOf [
    lib.types.str
    lib.types.attrs
  ];
  directoryType = lib.types.oneOf [
    lib.types.str
    lib.types.attrs
  ];
in
{
  imports = [ inputs.impermanence.nixosModules.impermanence ];

  options.jorthaus.persistence = {
    files = lib.mkOption {
      type = lib.types.listOf fileType;
      default = [ ];
      example = persistenceOpts.files.example;
      description = "Additional files to make persistent.";
    };

    directories = lib.mkOption {
      type = lib.types.listOf directoryType;
      default = [ ];
      example = persistenceOpts.directories.example;
      description = "Additional directories to make persistent.";
    };
  };

  config = {
    environment.persistence."/persistent" = {
      enable = true;
      hideMounts = true;

      files = [
        "/etc/machine-id"
      ]
      ++ cfg.files;

      directories = [
        "/etc/ssh"
        "/var/lib/nixos"
        "/var/lib/systemd"
        "/var/log"
      ]
      ++ cfg.directories;
    };
  };
}
