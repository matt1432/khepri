{
  description = "Nix native docker container orchestration";
  inputs = { nixpkgs.url = "github:nixos/nixpkgs/nixos-23.11"; };
  outputs = { ... }: { nixosModules.default = ./khepri.nix; };
}
