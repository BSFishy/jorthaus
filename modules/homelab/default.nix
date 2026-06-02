{ ... }:

{
  options = {
    # TODO: add service registry options. gonna use nix as the service discovery
    # tool. all services are gonna be registered in the modules directory,
    # configuration and all, then we use those configurations to generate a
    # traefik (or nginx or whatever) config to reverse proxy those services.
    # im sure we want other configuration options and whatnot here but i know
    # off the top of my head that the service registry stuff is the most
    # important. then we use the inventory to register which services each
    # container/vm should be running.
  };
}
