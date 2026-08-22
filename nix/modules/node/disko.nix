{
  host,
  inputs,
  lib,
  ...
}:
let
  install = host.install;
  systemDisk = install.systemDisk;
  dataDisks = install.dataDisks;
  useDisko = systemDisk != null;
  systemDiskDevice = if useDisko then systemDisk.device else null;
  bootSize = if useDisko then systemDisk.bootSize else null;
  swapSize = if useDisko then systemDisk.swapSize else null;
  rootLabel = if useDisko then systemDisk.rootLabel else null;
  bootLabel = if useDisko then systemDisk.bootLabel else null;

  mkDataDisk = dataDisk: {
    type = "disk";
    device = dataDisk.device;
    content = {
      type = "gpt";
      partitions.data = {
        size = "100%";
        content = {
          type = "filesystem";
          format = dataDisk.fsType;
          mountpoint = dataDisk.mountpoint;
          extraArgs = lib.optionals (dataDisk ? label) [
            "-L"
            dataDisk.label
          ];
        }
        // lib.optionalAttrs (dataDisk.mountOptions != null) {
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
