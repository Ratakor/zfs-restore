{
  description = "CLI tool to restore files from ZFS snapshots";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  # temporary (awaiting for zig_0_16 to get into nixpkgs)
  inputs.zig = {
    url = "github:silversquirl/zig-flake";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      ...
    }@inputs:
    let
      forAllSystems = f: builtins.mapAttrs f nixpkgs.legacyPackages;
    in
    {
      packages = forAllSystems (
        system: pkgs: {
          default = self.packages.${system}.zfs-restore;
          zfs-restore = pkgs.callPackage ./nix/package.nix {
            # zig = pkgs.zig_0_15;
            zig = inputs.zig.packages.${system}.zig_0_16_0;
          };
        }
      );

      devShells = forAllSystems (
        system: pkgs: {
          default = pkgs.callPackage ./nix/shell.nix {
            # zig = pkgs.zig_0_15;
            zig = inputs.zig.packages.${system}.zig_0_16_0;
            zls = pkgs.zls_0_15;
          };
        }
      );

      formatter = forAllSystems (_: pkgs: pkgs.nixfmt-tree);
    };
}
