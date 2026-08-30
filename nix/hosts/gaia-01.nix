{
  hostname = "gaia-01";
  system = "x86_64-linux";
  facter = ./gaia-01-facter.json;

  slivers = {
    etcd.enable = true;
    openbao.enable = true;
    postgres.enable = true;
    valkey.enable = true;
    k3s = {
      enable = true;
      role = "controlplane";
    };
    seaweedfs = {
      enable = true;
      role = "controlplane";
    };
  };

  ipam = {
    interface = "enp1s0";
    nameservers = [ "10.1.0.1" ];
    ipv4 = {
      address = "10.1.10.1";
      prefixLength = 16;
      gateway = "10.1.0.1";
    };
  };

  install = {
    systemDisk = {
      device = "/dev/disk/by-id/nvme-CT1000P510SSD8_2537E9CAEBD7";
      bootSize = "1G";
      swapSize = "16G";
    };

    dataDisks = [
      {
        name = "storage";
        device = "/dev/disk/by-id/nvme-Samsung_SSD_990_EVO_Plus_2TB_S7U6NU0Y716078M";
        label = "storage";
        mountpoint = "/srv/storage";
      }
    ];
  };

  disk = {
    root = {
      device = "/dev/disk/by-label/nixos";
      fsType = "btrfs";
      btrfs = {
        enable = true;
      };
    };

    boot = {
      device = "/dev/disk/by-label/BOOT";
      fsType = "vfat";
      options = [
        "fmask=0077"
        "dmask=0077"
      ];
    };

    swap = {
      device = "/dev/disk/by-partlabel/swap";
    };
  };
}
