{
  hostname = "gaia-03";
  system = "x86_64-linux";
  facter = ./gaia-03-facter.json;

  ipam = {
    interface = "enp1s0";
    nameservers = [ "10.1.0.1" ];
    ipv4 = {
      address = "10.1.10.3";
      prefixLength = 16;
      gateway = "10.1.0.1";
    };
  };

  disk = {
    root = {
      device = "/dev/disk/by-uuid/9f2f1ef4-cbdd-4815-bf9c-2172a22985df";
      fsType = "ext4";
    };

    boot = {
      device = "/dev/disk/by-uuid/ECF1-CCC9";
      fsType = "vfat";
      options = [
        "fmask=0077"
        "dmask=0077"
      ];
    };

    swap = {
      device = "/dev/disk/by-uuid/f6824e5e-9225-4e14-8f28-96c6a64e0016";
    };
  };
}
