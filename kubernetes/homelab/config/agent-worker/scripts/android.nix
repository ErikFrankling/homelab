# The one Android emulator agents get, for `heavy emulator start`. Matches the
# T3 Code fork's emulator image (flake.nix: API 36, google_apis, x86_64).
{ nixpkgsRev }:
let
  pkgs = import (builtins.fetchTarball "https://github.com/NixOS/nixpkgs/archive/${nixpkgsRev}.tar.gz") {
    config = import ./nixpkgs-config.nix;
  };
  android = pkgs.androidenv.composeAndroidPackages {
    platformVersions = [ "36" ];
    includeEmulator = true;
    includeSystemImages = true;
    systemImageTypes = [ "google_apis" ];
    abiVersions = [ "x86_64" ];
    includeNDK = false;
  };
in
android.androidsdk
