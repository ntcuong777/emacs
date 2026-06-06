# nix-shell for interactive Emacs compilation from local source.
# Provides all build deps for the forked-igc variant (MPS + native-comp).
# Does NOT run the nixpkgs elisp/bootstrap phases — just supplies the env.
#
# Usage:
#   nix-shell /etc/nix-darwin/fork/shell.nix
#   # then inside the shell, from custom-emacs/:
#
#   # IMPORTANT: custom patches modify configure.ac (--with-poll, --with-mps,
#   # --with-file-notification=fsevents).  Regenerate configure first:
#   ./autogen.sh
#
#   ./configure $CONFIGURE_FLAGS
#   make -j$(sysctl -n hw.logicalcpu) -C src emacs      # binary only
#   make -j$(sysctl -n hw.logicalcpu) install           # + Emacs.app in nextstep/
{
  variant ? "forked-master",
}:
let
  lock = builtins.fromJSON (builtins.readFile /etc/nix-darwin/flake.lock);
  nixpkgsLock = lock.nodes.nixpkgs.locked;
  emacsOverlayLock = lock.nodes.emacs-overlay.locked;

  nixpkgs = fetchTarball {
    url = "https://github.com/${nixpkgsLock.owner}/${nixpkgsLock.repo}/archive/${nixpkgsLock.rev}.tar.gz";
    sha256 = nixpkgsLock.narHash;
  };

  emacs-overlay = fetchTarball {
    url = "https://github.com/${emacsOverlayLock.owner}/${emacsOverlayLock.repo}/archive/${emacsOverlayLock.rev}.tar.gz";
    sha256 = emacsOverlayLock.narHash;
  };

  system = "aarch64-darwin";

  pkgs = import nixpkgs {
    inherit system;
    overlays = [
      (import "${emacs-overlay}/overlays/default.nix")
    ];
  };

  inherit (pkgs) lib stdenv;

  commonConfigureFlags = [
    "--with-file-notification=fsevents"
    "--with-threads=yes"
    "--with-poll=yes"
    "--disable-gc-mark-trace"
  ];

  variantConfig = {
    forked-igc = {
      extraBuildInputs = [ pkgs.mps ];
      extraConfigureFlags = [ "--with-mps=yes" ];
    };
    forked-master = {
      extraBuildInputs = [ ];
      extraConfigureFlags = [ ];
    };
  };

  config = variantConfig.${variant}
    or (throw "Unknown variant '${variant}'. Available: ${builtins.concatStringsSep ", " (builtins.attrNames variantConfig)}");

  extraEnv = oa: {
    NATIVE_FULL_AOT = "1";
    NIX_CFLAGS_COMPILE =
      (oa.env.NIX_CFLAGS_COMPILE or "")
      + " -DNTCUONG_CACHE_EXEC_PATH -DNTCUONG_NO_DUPLICATE_SIGPROF -DNTCUONG_EVENTLOOP_CALLPROC"
      + " -DNTCUONG_POSIX_SPAWN_DARWIN -DNTCUONG_POSIX_SPAWN_PTY -DNTCUONG_NS_PARTIAL_IOSURFACE"
      + " -DUSE_NS_YIELD -DNTCUONG_NS_MOUSEDOWN_DPYINFO_GUARD"
      + " -DFD_SETSIZE=40960 -DDARWIN_UNLIMITED_SELECT -O2 -mcpu=native"
      + " -flto=thin";
    NIX_LDFLAGS =
      (oa.env.NIX_LDFLAGS or "")
      + " -lto_library ${pkgs.llvmPackages.libllvm.lib}/lib/libLTO.dylib";
  };

  base = (pkgs.emacs.override {
    srcRepo = true;
    withXwidgets = false;
    withNativeCompilation = true;
    apple-sdk = pkgs.apple-sdk_26;
  }).overrideAttrs (oa: {
    name = "emacs-local-${variant}-shell";
    version = "31.0.50";
    __intentionallyOverridingVersion = true;

    buildInputs = oa.buildInputs ++ config.extraBuildInputs;
    configureFlags =
      oa.configureFlags
      ++ commonConfigureFlags
      ++ config.extraConfigureFlags;

    env = (oa.env or {}) // (extraEnv oa);
  });

  # Flags as a single string for easy copy-paste
  configureFlagsStr = builtins.concatStringsSep " " base.configureFlags;

  # Env vars for mkShell: call extraEnv with empty base so there's no
  # nixpkgs env prefix to inherit (the shell doesn't need it).
  shellEnv = extraEnv { env = {}; };

in pkgs.mkShell {
  inputsFrom = [ base ];

  inherit (shellEnv) NIX_CFLAGS_COMPILE NIX_LDFLAGS NATIVE_FULL_AOT;

  shellHook = ''
    echo ""
    echo "=== Emacs dev shell (${variant}) ==="
    echo ""
    echo "Configure flags (also in \$CONFIGURE_FLAGS):"
    echo "  ${configureFlagsStr}"
    echo ""
    echo "Quick build (from custom-emacs/):"
    echo "  ./autogen.sh                                   # regenerate configure from patched configure.ac"
    echo "  ./configure \$CONFIGURE_FLAGS"
    echo "  make -j\$(sysctl -n hw.logicalcpu) -C src emacs # binary only"
    echo "  make -j\$(sysctl -n hw.logicalcpu) install     # + Emacs.app in nextstep/"
    echo ""
    export CONFIGURE_FLAGS="${configureFlagsStr} --prefix=$(pwd)/build"
  '';
}
