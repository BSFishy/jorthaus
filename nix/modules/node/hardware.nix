{ host, ... }:

{
  hardware.facter.reportPath = host.facter;

  fileSystems = {
    "/" = host.disk.root;
    "/boot" = host.disk.boot;
  };

  swapDevices = [ host.disk.swap ];
}
