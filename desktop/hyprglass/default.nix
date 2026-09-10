{ lib, pkg-config, hyprland, src }:
# Hyprland's private C++ ABI requires its own compiler and dependency versions.
hyprland.stdenv.mkDerivation {
  pname = "hyprglass";
  version = "0.8.0";
  inherit src;
  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ hyprland ] ++ hyprland.buildInputs;
  enableParallelBuilding = true;
  dontUseCmakeConfigure = true;
  installPhase = ''
    runHook preInstall
    install -Dm755 hyprglass.so $out/lib/libhyprglass.so
    runHook postInstall
  '';
  passthru = { inherit hyprland; };
  meta = {
    description = "Live refractive glass for Hyprland windows and layer surfaces";
    homepage = "https://github.com/hyprnux/hyprglass";
    license = lib.licenses.bsd3;
    platforms = lib.platforms.linux;
  };
}
