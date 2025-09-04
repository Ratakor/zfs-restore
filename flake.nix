{
  description = "CLI tool to restore files from ZFS snapshots";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    zls = {
      url = "github:zigtools/zls/0.15.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    zls,
    ...
  }: let
    forAllSystems = f: builtins.mapAttrs f nixpkgs.legacyPackages;
  in {
    packages = forAllSystems (system: pkgs: {
      default = self.packages.${system}.zfs-restore;
      zfs-restore = pkgs.callPackage ./nix/package.nix {};
    });

    devShells = forAllSystems (system: pkgs: {
      default = pkgs.callPackage ./nix/shell.nix {
        # https://github.com/NixOS/nixpkgs/pull/438854
        zls_0_15 = zls.packages.${system}.default;
        # zls_0_15 = pkgs.zls;
      };
    });

    formatter = forAllSystems (_: pkgs: pkgs.alejandra);
  };
}
