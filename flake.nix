{
  description = "CLI tool to restore files from ZFS snapshots";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = {
    self,
    nixpkgs,
    ...
  }: let
    forAllSystems = f: builtins.mapAttrs f nixpkgs.legacyPackages;
  in {
    packages = forAllSystems (system: pkgs: {
      default = self.packages.${system}.zfs-restore;
      zfs-restore = pkgs.callPackage ./nix/package.nix {
        zig = pkgs.zig_0_15;
      };
    });

    devShells = forAllSystems (system: pkgs: {
      default = pkgs.callPackage ./nix/shell.nix {
        zig = pkgs.zig_0_15;
        zls = pkgs.zls_0_15;
      };
    });

    formatter = forAllSystems (_: pkgs: pkgs.alejandra);
  };
}
