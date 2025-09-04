{
  lib,
  zigPlatform,
  makeWrapper,
  zfs,
  coreutils,
}: let
  fs = lib.fileset;
in
  zigPlatform.makePackage {
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

    zigReleaseMode = "fast";
    depsHash = "sha256-jF/wi+CVsGbjjOgYIdR7S0nMitqgjcTnNrswQBKGjBE=";

    nativeBuildInputs = [
      makeWrapper
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
  }
