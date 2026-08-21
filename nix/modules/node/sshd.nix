{ lib, ... }:

let
  mattAuthorizedKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGOo7iBDgCXP99GA4NStJudsWkZQVaA9iDqDo6IQF2ve";
in
{
  services.openssh.enable = lib.mkDefault true;
  users.users.matt.openssh.authorizedKeys.keys = [ mattAuthorizedKey ];
}
