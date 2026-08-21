{
  hostname = "gaia-01";
  system = "x86_64-linux";
  facter = ./gaia-01-facter.json;

  ipam = {
    interface = "enp1s0";
    nameservers = [ "10.1.0.1" ];
    ipv4 = {
      address = "10.1.10.1";
      prefixLength = 16;
      gateway = "10.1.0.1";
    };
  };

  disk = {
    root = {
      device = "/dev/disk/by-uuid/a6e0744b-b49c-4e5f-9313-008f08542471";
      fsType = "ext4";
    };

    boot = {
      device = "/dev/disk/by-uuid/9682-9CCA";
      fsType = "vfat";
      options = [ "fmask=0077" "dmask=0077" ];
    };

    swap = {
      device = "/dev/disk/by-uuid/c95d5020-209a-4612-a522-4a1b3453f39f";
    };
  };
}
