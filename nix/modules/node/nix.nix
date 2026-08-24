_:

{
  system.stateVersion = "26.11";

  # Allow remote updates
  nix.settings.trusted-users = [
    "root"
    "@wheel"
  ];

  # Enable flakes
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  programs.nh = {
    enable = true;
    clean.enable = true;
  };
}
