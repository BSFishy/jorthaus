<host> = {
  hostName = "<host>";

  ipv4 = {
    address = "10.1.4.<octet>";
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
  };

  modules = [
    ./modules/hosts/<host>.nix
  ];
};
