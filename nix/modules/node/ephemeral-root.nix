{ host, lib, ... }:
let
  root = host.disk.root;
  btrfs = root.btrfs or { };
  enabled = btrfs.enable or false;
  mountDevice = btrfs.device or root.device;
  rootSubvolume = btrfs.rootSubvolume or "root";
  oldRootsSubvolume = btrfs.oldRootsSubvolume or "old_roots";
  persistentSubvolume = btrfs.persistentSubvolume or "persistent";
  nixSubvolume = btrfs.nixSubvolume or "nix";
in
{
  config = lib.mkIf enabled {
    assertions = [
      {
        assertion = root.fsType == "btrfs";
        message = "host.disk.root.fsType must be btrfs when host.disk.root.btrfs.enable is true.";
      }
    ];

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

    boot.initrd.postResumeCommands = lib.mkAfter ''
      mkdir -p /btrfs_tmp
      mount ${lib.escapeShellArg mountDevice} /btrfs_tmp

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

      btrfs subvolume create /btrfs_tmp/${rootSubvolume}
      umount /btrfs_tmp
    '';
  };
}
