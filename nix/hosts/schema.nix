{ lib, name, ... }:
let
  inherit (lib) mkEnableOption mkOption types;
in
{
  options = {
    hostname = mkOption {
      type = types.str;
      default = name;
      description = "Node hostname.";
    };

    system = mkOption {
      type = types.enum [
        "x86_64-linux"
        "aarch64-linux"
      ];
      description = "Target system architecture.";
    };

    facter = mkOption {
      type = types.path;
      description = "Path to the nixos-facter report for this node.";
    };

    slivers.openbao.enable = mkEnableOption "the OpenBao sliver";

    ipam = {
      interface = mkOption {
        type = types.str;
        description = "Primary uplink interface name.";
      };

      nameservers = mkOption {
        type = types.listOf types.str;
        default = [ "10.1.0.1" ];
        description = "Static DNS servers for the node.";
      };

      ipv4 = {
        address = mkOption {
          type = types.str;
          description = "Static IPv4 address.";
        };

        prefixLength = mkOption {
          type = types.ints.between 0 32;
          description = "IPv4 prefix length.";
        };

        gateway = mkOption {
          type = types.str;
          description = "IPv4 default gateway.";
        };
      };
    };

    install = {
      systemDisk = mkOption {
        type = types.nullOr (types.submodule {
          options = {
            device = mkOption {
              type = types.str;
              description = "Disko install target for the OS disk.";
            };

            bootSize = mkOption {
              type = types.str;
              default = "1G";
              description = "EFI system partition size.";
            };

            swapSize = mkOption {
              type = types.str;
              default = "16G";
              description = "Swap partition size.";
            };

            rootLabel = mkOption {
              type = types.str;
              default = "nixos";
              description = "Filesystem label for the Btrfs root disk.";
            };

            bootLabel = mkOption {
              type = types.str;
              default = "BOOT";
              description = "Filesystem label for the EFI system partition.";
            };
          };
        });
        default = null;
        description = "Install-time Disko configuration for the OS disk.";
      };

      dataDisks = mkOption {
        type = types.listOf (types.submodule {
          options = {
            name = mkOption {
              type = types.str;
              description = "Logical name for the data disk in Disko.";
            };

            device = mkOption {
              type = types.str;
              description = "Install target for the data disk.";
            };

            fsType = mkOption {
              type = types.str;
              default = "xfs";
              description = "Filesystem format for the data disk.";
            };

            label = mkOption {
              type = types.str;
              description = "Filesystem label for the data disk.";
            };

            mountpoint = mkOption {
              type = types.str;
              description = "Mount point for the data disk.";
            };

            mountOptions = mkOption {
              type = types.nullOr (types.listOf types.str);
              default = null;
              description = "Optional mount options for the data disk.";
            };
          };
        });
        default = [ ];
        description = "Additional data disks managed by Disko.";
      };
    };

    disk = {
      root = {
        device = mkOption {
          type = types.str;
          description = "Runtime root filesystem device.";
        };

        fsType = mkOption {
          type = types.str;
          description = "Runtime root filesystem type.";
        };

        btrfs = {
          enable = mkEnableOption "Btrfs ephemeral-root support";

          rootSubvolume = mkOption {
            type = types.str;
            default = "root";
            description = "Subvolume mounted at /.";
          };

          oldRootsSubvolume = mkOption {
            type = types.str;
            default = "old_roots";
            description = "Subvolume that stores rotated old roots.";
          };

          persistentSubvolume = mkOption {
            type = types.str;
            default = "persistent";
            description = "Subvolume mounted at /persistent.";
          };

          nixSubvolume = mkOption {
            type = types.str;
            default = "nix";
            description = "Subvolume mounted at /nix.";
          };

          oldRootsRetentionDays = mkOption {
            type = types.int;
            default = 30;
            description = "How many days to retain rotated old roots.";
          };
        };
      };

      boot = {
        device = mkOption {
          type = types.str;
          description = "Runtime boot filesystem device.";
        };

        fsType = mkOption {
          type = types.str;
          description = "Runtime boot filesystem type.";
        };

        options = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Mount options for /boot.";
        };
      };

      swap.device = mkOption {
        type = types.str;
        description = "Runtime swap device.";
      };
    };
  };
}
