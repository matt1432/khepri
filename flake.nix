{
  description = "Nix native docker container orchestration";

  inputs = {
    nixpkgs = {
      type = "github";
      owner = "NixOS";
      repo = "nixpkgs";
      ref = "nixos-unstable";
    };
  };

  outputs = {
    self,
    nixpkgs,
    ...
  }: let
    supportedSystems = [
      "x86_64-linux"
      "aarch64-linux"
    ];

    perSystem = attrs:
      nixpkgs.lib.genAttrs supportedSystems (system:
        attrs (import nixpkgs {inherit system;}));
  in {
    nixosModules = {
      default = self.nixosModules.khepri;

      khepri = import ./modules;
    };

    packages = perSystem (pkgs: {
      nixos-tests = pkgs.testers.runNixOSTest ./test.nix;
    });

    formatter = perSystem (pkgs: pkgs.alejandra);

    devShells = perSystem (pkgs: {
      default = pkgs.mkShell {
        buildInputs = with pkgs; [
          nix-unit
        ];
      };
    });
  };
}
