{
  hostname = "gaia-05";
  system = "x86_64-linux";
  facter = ./gaia-05-facter.json;

  slivers = {
    k3s = {
      enable = true;
      role = "dataplane";
    };
    seaweedfs = {
      enable = true;
      role = "dataplane";
    };
  };

  ipam = {
    interface = "enp2s0";
    nameservers = [ "10.1.0.1" ];
    ipv4 = {
      address = "10.1.10.5";
      prefixLength = 16;
      gateway = "10.1.0.1";
    };
  };

  install = {
    systemDisk = {
      device = "/dev/disk/by-id/nvme-KINGSTON_OM8PGP41024Q-A0_50026B738300BB9C";
      bootSize = "1G";
      swapSize = "16G";
    };

    dataDisks = [
      {
        name = "storage";
        device = "/dev/disk/by-id/nvme-Samsung_SSD_990_EVO_Plus_2TB_S7U6NU0YA32820Z";
        label = "storage";
        mountpoint = "/srv/storage";
      }
    ];
  };

  disk = {
    root = {
      device = "/dev/disk/by-label/nixos";
      fsType = "btrfs";
      btrfs.enable = true;
    };

    boot = {
      device = "/dev/disk/by-label/BOOT";
      fsType = "vfat";
      options = [
        "fmask=0077"
        "dmask=0077"
      ];
    };

    swap.device = "/dev/disk/by-partlabel/swap";
  };
}
