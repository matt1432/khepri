{
  name = "test-nginx";
  nodes = {
    machine1 = {pkgs, ...}: {
      imports = [./khepri.nix];
      virtualisation.docker = {enable = true;};
      virtualisation.oci-containers.backend = "docker";

      khepri.compositions = {
        nginx = {
          services = {
            nginx1 = {
              image = pkgs.dockerTools.pullImage {
                imageName = "nginx";
                imageDigest = "sha256:0f04e4f646a3f14bf31d8bc8d885b6c951fdcf42589d06845f64d18aec6a3c4d";
                sha256 = "159z86nw6riirs9ix4zix7qawhfngl5fkx7ypmi6ib0sfayc8pw2";
                finalImageName = "nginx";
                finalImageTag = "latest";
              };
              restart = "unless-stopped";
            };
            nginx2 = {image = pkgs.dockerTools.examples.nginx;};
          };
        };
      };

      system.stateVersion = "23,11";
    };
  };

  testScript = {...}: ''
    start_all()
    machine1.wait_for_unit("multi-user.target")
    machine1.succeed("systemctl is-active --quiet docker-nginx_nginx1.service")
    machine1.succeed("systemctl is-active --quiet docker-nginx_nginx2.service")
  '';
}
