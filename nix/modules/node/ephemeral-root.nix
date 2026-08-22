{
  config,
  host,
  lib,
  utils,
  ...
}:
let
  root = host.disk.root;
  btrfs = root.btrfs;
  enabled = btrfs.enable;
  useDisko = host.install.systemDisk != null;
  mountDevice = if useDisko then config.fileSystems."/".device else root.device;
  mountDeviceUnit = "${utils.escapeSystemdPath mountDevice}.device";
  rootSubvolume = btrfs.rootSubvolume;
  oldRootsSubvolume = btrfs.oldRootsSubvolume;
  persistentSubvolume = btrfs.persistentSubvolume;
  nixSubvolume = btrfs.nixSubvolume;
  oldRootsRetentionDays = toString btrfs.oldRootsRetentionDays;
in
{
  config = lib.mkIf enabled (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = root.fsType == "btrfs";
            message = "host.disk.root.fsType must be btrfs when host.disk.root.btrfs.enable is true.";
          }
        ];
      }

      (lib.optionalAttrs (!useDisko) {
        fileSystems = {
          "/" = {
            device = mountDevice;
            fsType = "btrfs";
            options = [ "subvol=${rootSubvolume}" ];
          };

          "/persistent" = {
            device = mountDevice;
            fsType = "btrfs";
            neededForBoot = true;
            options = [ "subvol=${persistentSubvolume}" ];
          };

          "/nix" = {
            device = mountDevice;
            fsType = "btrfs";
            neededForBoot = true;
            options = [ "subvol=${nixSubvolume}" ];
          };
        };
      })

      {
        fileSystems."/persistent".neededForBoot = lib.mkForce true;
        fileSystems."/nix".neededForBoot = lib.mkForce true;

        boot.initrd.systemd.services.rollback-root = {
          description = "Rotate the btrfs root subvolume before mounting /sysroot";
          wantedBy = [ "initrd.target" ];
          before = [ "sysroot.mount" ];
          after = [
            "systemd-udev-settle.service"
            mountDeviceUnit
          ];
          requires = [ mountDeviceUnit ];
          unitConfig.DefaultDependencies = false;
          serviceConfig.Type = "oneshot";
          script = ''
            mkdir -p /btrfs_tmp
            mount -t btrfs -o subvolid=5 ${lib.escapeShellArg mountDevice} /btrfs_tmp

            if [[ -e /btrfs_tmp/${rootSubvolume} ]]; then
              mkdir -p /btrfs_tmp/${oldRootsSubvolume}
              timestamp=$(date --date="@$(stat -c %Y /btrfs_tmp/${rootSubvolume})" "+%Y-%m-%d_%H:%M:%S")
              mv /btrfs_tmp/${rootSubvolume} "/btrfs_tmp/${oldRootsSubvolume}/$timestamp"
            fi

            delete_subvolume_recursively() {
              IFS=$'\n'
              for subvolume in $(btrfs subvolume list -o "$1" | cut -f 9- -d ' '); do
                delete_subvolume_recursively "/btrfs_tmp/$subvolume"
              done
              btrfs subvolume delete "$1"
            }

            if [[ -d /btrfs_tmp/${oldRootsSubvolume} ]]; then
              for old_root in $(find /btrfs_tmp/${oldRootsSubvolume} -maxdepth 1 -mindepth 1 -mtime +${oldRootsRetentionDays}); do
                delete_subvolume_recursively "$old_root"
              done
            fi

            btrfs subvolume create /btrfs_tmp/${rootSubvolume}
            umount /btrfs_tmp
          '';
        };
      }
    ]
  );
}
