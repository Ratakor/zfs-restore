{
  description = "TODO";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    zig = {
      url = "github:silversquirl/zig-flake/compat";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    zls = {
      url = "github:zigtools/zls";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        zig-overlay.follows = "zig";
      };
    };
  };

  outputs = {
    nixpkgs,
    zig,
    zls,
    ...
  }: let
    zig-version = "0.15.1";
    forAllSystems = f: builtins.mapAttrs f nixpkgs.legacyPackages;
  in {
    devShells = forAllSystems (system: pkgs: {
      default = pkgs.mkShellNoCC {
        packages = [
          pkgs.bash
          zig.packages.${system}.${zig-version}
          zls.packages.${system}.default
        ];
      };
    });

    packages = forAllSystems (system: pkgs: {
      default = zig.packages.${system}.${zig-version}.makePackage {
        pname = "zfs-restore";
        version = "0.0.0";
        src = ./.;
        zigReleaseMode = "safe";
        depsHash = "sha256-T39rEuZ1T7jmgOhZHF+X0sNyRsSZgFxakqWroFXVpqA=";
        buildInputs = [pkgs.zfs];
      };
    });
  };
}
