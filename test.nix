let
  nixpkgs = fetchTarball "https://github.com/NixOS/nixpkgs/tarball/nixos-23.11";
  pkgs = import nixpkgs {
    config = { };
    overlays = [ ];
  };
in pkgs.testers.runNixOSTest {
  name = "test-caddy";
  nodes = {
    machine1 = { config, pkgs, ... }: {
      imports = [ ./khepri.nix ];
      virtualisation.docker = { enable = true; };
      virtualisation.oci-containers.backend = "docker";

      khepri.compositions = {
        caddy = {
          networks.proxy_net = { };
          volumes = [ "caddy_data" ];
          services = {
            caddy = {
              image = "caddy:alpine";
              networks = [ "proxy_net" ];
              volumes = [ "caddy_data:/data:rw" ];
              ports = [ "80:80/tcp" "443:443/tcp" "443:443/udp" ];
              restart = "unless-stopped";
            };
          };
        };
      };

      system.stateVersion = "23,11";
    };
  };

  testScript = { nodes, ... }: ''
    start_all()
    machine1.wait_for_unit("multi-user.target")
    machine1.succeed("sudo systemctl is-active --quiet docker-caddy_caddy.service")
  '';
}
