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
      usb = [ ];
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
      memory = 2048;
      diskSize = 20;
      machine = "q35";
      bios = "ovmf";
      bridge = "vmbr0";
      imageDatastore = "local";
      vmDiskDatastore = "local-lvm";
      usb = [ ];
    };

    modules = [
      ./modules/hosts/media.nix
    ];
  };
}
