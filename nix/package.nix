{
  lib,
  stdenv,
  callPackage,
  makeWrapper,
  zig,
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

    deps = callPackage ./deps.nix {};

    zigBuildFlags = ["--system" "${finalAttrs.deps}"];

    nativeBuildInputs = [
      makeWrapper
      zig.hook
    ];

    buildInputs = [
      zfs
      coreutils
    ];

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
