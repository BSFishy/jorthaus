{
  home = {
    hostName = "home";

    ipv4 = {
      address = "10.1.4.10";
      prefixLength = 16;
      gateway = "10.1.0.1";
    };

    proxmox = {
      nodeName = "gaia-05";
      cpuCores = 2;
      memory = 2048;
      diskSize = 20;
      machine = "q35";
      bios = "ovmf";
      bridge = "vmbr0";
      imageDatastore = "local";
      vmDiskDatastore = "local-lvm";
      usb = [
        {
          mapping = "zigbee-coordinator";
        }
      ];
      hostpci = [ ];
      dataDisks = [ ];
    };

    modules = [
      ./modules/hosts/home.nix
    ];
  };

  infra = {
    hostName = "infra";

    ipv4 = {
      address = "10.1.4.11";
      prefixLength = 16;
      gateway = "10.1.0.1";
    };

    proxmox = {
      nodeName = "gaia-05";
      cpuCores = 2;
      memory = 2048;
      diskSize = 20;
      machine = "q35";
      bios = "ovmf";
      bridge = "vmbr0";
      imageDatastore = "local";
      vmDiskDatastore = "local-lvm";
      usb = [ ];
      hostpci = [ ];
      dataDisks = [ ];
    };

    modules = [
      ./modules/hosts/infra.nix
    ];
  };

  media = {
    hostName = "media";

    ipv4 = {
      address = "10.1.4.12";
      prefixLength = 16;
      gateway = "10.1.0.1";
    };

    proxmox = {
      nodeName = "gaia-05";
      cpuCores = 2;
      memory = 5120;
      diskSize = 20;
      machine = "q35";
      bios = "ovmf";
      bridge = "vmbr0";
      imageDatastore = "local";
      vmDiskDatastore = "local-lvm";
      usb = [ ];
      hostpci = [
        {
          device = "hostpci0";
          mapping = "amd-igpu";
          pcie = true;
          rombar = true;
        }
      ];
      dataDisks = [
        {
          interface = "virtio1";
          datastoreId = "media";
          size = 800;
          serial = "media";
          cache = "none";
          backup = false;
          replicate = false;
          discard = "on";
          iothread = true;
        }
      ];
    };

    modules = [
      ./modules/hosts/media.nix
    ];
  };
}
