{
  lib,
  stdenv,
  callPackage,
  makeWrapper,
  zig,
  zfs,
  coreutils,
  releaseMode ? "safe",
}:
let
  fs = lib.fileset;
in
stdenv.mkDerivation (finalAttrs: {
  pname = "zfs-restore";
  inherit (import ./version.nix lib) version;

  src = fs.toSource {
    root = ../.;
    fileset = fs.unions [
      ../src
      ../build.zig
      ../build.zig.zon
    ];
  };

  nativeBuildInputs = [
    makeWrapper
    zig
  ];

  buildInputs = [
    zfs
    coreutils
  ];

  configurePhase = ''
    export ZIG_GLOBAL_CACHE_DIR=$TEMP/.cache
    PACKAGE_DIR=${callPackage ./deps.nix { }}
  '';

  buildPhase = ''
    zig build install \
      --system $PACKAGE_DIR \
      --release=${releaseMode} \
      -Dversion-string=${finalAttrs.version} \
      --color off
  '';

  doCheck = true;
  checkPhase = ''
    zig build test \
      --system $PACKAGE_DIR \
      -Dversion-string=${finalAttrs.version} \
      --color off
  '';

  postInstall = ''
    wrapProgram $out/bin/zfs-restore \
      --prefix PATH : ${
        lib.makeBinPath [
          zfs
          coreutils
        ]
      }
  '';

  meta = {
    description = "CLI tool to restore files from ZFS snapshots";
    homepage = "https://github.com/ratakor/zfs-restore";
    license = lib.licenses.eupl12;
    maintainers = [ lib.maintainers.ratakor ];
    mainProgram = "zfs-restore";
  };
})
