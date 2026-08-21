{
  hostname = "gaia-02";
  system = "x86_64-linux";
  facter = ./gaia-02-facter.json;

  ipam = {
    interface = "enp1s0";
    nameservers = [ "10.1.0.1" ];
    ipv4 = {
      address = "10.1.10.2";
      prefixLength = 16;
      gateway = "10.1.0.1";
    };
  };

  disk = {
    root = {
      device = "/dev/disk/by-uuid/a3993711-0dd6-4f6e-a406-c465c53c3759";
      fsType = "ext4";
    };

    boot = {
      device = "/dev/disk/by-uuid/CCC9-5728";
      fsType = "vfat";
      options = [
        "fmask=0077"
        "dmask=0077"
      ];
    };

    swap = {
      device = "/dev/disk/by-uuid/cf7bb12d-6760-4a2e-8daa-008ba6668c92";
    };
  };
}
