{ host, lib, ... }:
let
  root = host.disk.root;
  useBtrfsEphemeralRoot = root.btrfs.enable;
  useDisko = host.install.systemDisk != null;
in
{
  hardware.facter.reportPath = host.facter;
  hardware.facter.detected.dhcp.enable = false;
  hardware.bluetooth.enable = false;

  fileSystems = lib.optionalAttrs (!useDisko) (
    {
      "/boot" = host.disk.boot;
    }
    // lib.optionalAttrs (!useBtrfsEphemeralRoot) {
      "/" = root;
    }
  );

  swapDevices = lib.optional (!useDisko) host.disk.swap;
}
