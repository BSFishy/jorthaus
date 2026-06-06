{ lib, ... }:

{
  system.stateVersion = "26.05";

  nix.settings.trusted-users = [ "root" "@wheel" ]; # Allow remote updates
  nix.settings.experimental-features = [ "nix-command" "flakes" ]; # Enable flakes

  # Build a generic EFI-capable disk image that still behaves like a Proxmox
  # guest once imported.
  boot.loader.grub.enable = lib.mkForce false;
  boot.loader.systemd-boot.enable = lib.mkDefault true;

  # Cloud-init should own first-boot networking and hostname configuration.
  networking.hostName = lib.mkForce "";
  networking.useDHCP = lib.mkForce false;

  # Match the serial console expectations used by Proxmox.
  boot.kernelParams = [ "console=ttyS0" ];

  services.cloud-init = {
    enable = true;
    network.enable = true;
  };

  services.qemuGuest.enable = lib.mkDefault true;
  services.sshd.enable = lib.mkDefault true;

  fileSystems."/" = lib.mkDefault {
    device = "/dev/disk/by-label/nixos";
    autoResize = true;
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-label/ESP";
    fsType = "vfat";
  };
}
