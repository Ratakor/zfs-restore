{
  description = "A CLI tool to restore files from ZFS snapshots";

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
        zigReleaseMode = "fast";
        depsHash = "sha256-bQrdwc+ZD2tq9ZHeU/eNh9F/+Vw3Xsq1NoG8lPMJBII=";

        buildInputs = [pkgs.zfs];

        meta = with pkgs.lib; {
          description = "A CLI tool to restore files from ZFS snapshots";
          homepage = "https://github.com/ratakor/zfs-restore";
          license = licenses.eupl12;
          # maintainers = [];
          # platforms = platforms.linux;
          mainProgram = "zfs-restore";
        };
      };
    });
  };
}
