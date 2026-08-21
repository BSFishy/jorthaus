{
  host,
  inputs,
  lib,
  ...
}:
let
  install = host.install or { };
  systemDisk = install.systemDisk or null;
  systemDiskDevice = systemDisk.device or null;
  dataDisks = install.dataDisks or [ ];
  useDisko = systemDiskDevice != null;
  bootSize = systemDisk.bootSize or "1G";
  swapSize = systemDisk.swapSize or "32G";
  rootLabel = systemDisk.rootLabel or "nixos";
  bootLabel = systemDisk.bootLabel or "BOOT";

  mkDataDisk = dataDisk: {
    type = "disk";
    device = dataDisk.device;
    content = {
      type = "gpt";
      partitions.data = {
        size = "100%";
        content = {
          type = "filesystem";
          format = dataDisk.fsType or "xfs";
          mountpoint = dataDisk.mountpoint;
          extraArgs = lib.optionals (dataDisk ? label) [
            "-L"
            dataDisk.label
          ];
        }
        // lib.optionalAttrs (dataDisk ? mountOptions) {
          mountOptions = dataDisk.mountOptions;
        };
      };
    };
  };
in
{
  imports = [ inputs.disko.nixosModules.disko ];

  config = lib.mkIf useDisko {
    disko.devices.disk = {
      main = {
        type = "disk";
        device = systemDiskDevice;
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              priority = 1;
              name = "ESP";
              start = "1M";
              end = bootSize;
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [ "umask=0077" ];
                extraArgs = [
                  "-n"
                  bootLabel
                ];
              };
            };

            swap = {
              size = swapSize;
              content = {
                type = "swap";
                resumeDevice = true;
              };
            };

            root = {
              size = "100%";
              content = {
                type = "btrfs";
                extraArgs = [
                  "-L"
                  rootLabel
                  "-f"
                ];
                subvolumes = {
                  "/root" = {
                    mountpoint = "/";
                  };
                  "/persistent" = {
                    mountpoint = "/persistent";
                  };
                  "/nix" = {
                    mountpoint = "/nix";
                    mountOptions = [
                      "compress=zstd"
                      "noatime"
                    ];
                  };
                  "/old_roots" = { };
                };
              };
            };
          };
        };
      };
    }
    // lib.listToAttrs (
      map (dataDisk: lib.nameValuePair dataDisk.name (mkDataDisk dataDisk)) dataDisks
    );
  };
}
