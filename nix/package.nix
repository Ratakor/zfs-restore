{
  lib,
  stdenv,
  callPackage,
  makeWrapper,
  zig_0_15,
  zfs,
  coreutils,
}: let
  fs = lib.fileset;
in
  stdenv.mkDerivation (finalAttrs: {
    pname = "zfs-restore";
    # Must match the `version` in `build.zig.zon`.
    version = "0.2.0-dev";

    src = fs.toSource {
      root = ../.;
      fileset = fs.unions [
        ../src
        ../build.zig
        ../build.zig.zon
      ];
    };

    # depsHash when?
    deps = callPackage ./build.zig.zon.nix {};

    nativeBuildInputs = [
      makeWrapper
      zig_0_15.hook
    ];

    buildInputs = [
      zfs
      coreutils
    ];

    zigBuildFlags = ["--system" "${finalAttrs.deps}"];

    postInstall = ''
      wrapProgram $out/bin/zfs-restore \
        --prefix PATH : ${lib.makeBinPath [zfs coreutils]}
    '';

    meta = {
      description = "CLI tool to restore files from ZFS snapshots";
      homepage = "https://github.com/ratakor/zfs-restore";
      license = lib.licenses.eupl12;
      maintainers = [lib.maintainers.ratakor];
      mainProgram = "zfs-restore";
    };
  })
