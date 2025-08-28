{
  description = "A CLI tool to restore files from ZFS snapshots";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    zig = {
      url = "github:silversquirl/zig-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    zls = {
      # https://github.com/zigtools/zls/pull/2469
      url = "github:Ratakor/zls/older-versions";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        zig-flake.follows = "zig";
      };
    };
  };

  outputs = {
    nixpkgs,
    zig,
    zls,
    ...
  }: let
    forAllSystems = f: builtins.mapAttrs f nixpkgs.legacyPackages;
  in {
    devShells = forAllSystems (system: pkgs: {
      default = pkgs.mkShellNoCC {
        packages = [
          pkgs.bash
          zig.packages.${system}.zig_0_15_1
          zls.packages.${system}.zls_0_15_0
        ];
      };
    });

    packages = forAllSystems (system: pkgs: {
      default = zig.packages.${system}.zig_0_15_1.makePackage {
        pname = "zfs-restore";
        version = "0.1.0";

        src = ./.;
        zigReleaseMode = "fast";
        depsHash = "sha256-jF/wi+CVsGbjjOgYIdR7S0nMitqgjcTnNrswQBKGjBE=";

        nativeBuildInputs = with pkgs; [
          makeWrapper
        ];

        buildInputs = with pkgs; [
          zfs
          coreutils
        ];

        postInstall = with pkgs; ''
          wrapProgram $out/bin/zfs-restore \
            --prefix PATH : ${lib.makeBinPath [zfs coreutils]}
        '';

        meta = with pkgs.lib; {
          description = "A CLI tool to restore files from ZFS snapshots";
          homepage = "https://github.com/ratakor/zfs-restore";
          license = licenses.eupl12;
          mainProgram = "zfs-restore";
        };
      };
    });
  };
}
