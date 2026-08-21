_:

{
  security.sudo.wheelNeedsPassword = false;

  users.users.matt = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
  };
}
