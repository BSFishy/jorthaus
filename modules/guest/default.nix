{ lib, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  services.qemuGuest.enable = lib.mkDefault true; # Enable QEMU Guest for Proxmox

  # This keeps the VM configuration simple since no extra devices are needed. The
  # bootloader lets you roll back configurations from within the Proxmox console
  # if something goes wrong.
  boot.loader.grub.enable = lib.mkDefault true; # Use the boot drive for GRUB
  boot.loader.grub.devices = [ "nodev" ];

  # Automatically grow partition to allow growing storage in Proxmox
  boot.growPartition = lib.mkDefault true;
}
