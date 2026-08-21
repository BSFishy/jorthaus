{ host, lib, ... }:
let
  root = host.disk.root;
  useBtrfsEphemeralRoot = root.btrfs.enable or false;
  useDisko = (host.install or { }) ? systemDisk;
in
{
  hardware.facter.reportPath = host.facter;

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
