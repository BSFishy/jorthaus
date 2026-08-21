{ host, lib, ... }:
let
  root = host.disk.root;
  useBtrfsEphemeralRoot = root.btrfs.enable or false;
in
{
  hardware.facter.reportPath = host.facter;

  fileSystems = {
    "/boot" = host.disk.boot;
  } // lib.optionalAttrs (!useBtrfsEphemeralRoot) {
    "/" = root;
  };

  swapDevices = [ host.disk.swap ];
}
