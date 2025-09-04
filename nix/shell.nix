{
  mkShellNoCC,
  zig_0_15,
  zls_0_15,
  zon2nix,
  gnutar,
  xz,
  p7zip,
}:
mkShellNoCC {
  packages = [
    zig_0_15
    zls_0_15
    zon2nix

    # `zig build release` dependencies
    gnutar
    xz
    p7zip
  ];
}
