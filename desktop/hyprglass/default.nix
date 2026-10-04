{ lib, pkg-config, hyprland, src, rustc, cargo, libGL, glslang, python3, mesa }:
# Hyprland's private C++ ABI requires its own compiler and dependency versions.
let theme = import ../theme.nix; in
hyprland.stdenv.mkDerivation {
  pname = "hyprglass";
  version = "0.8.0-liquid-rust-0.3.0";
  inherit src;
  nativeBuildInputs = [ pkg-config rustc cargo glslang python3 ];
  buildInputs = [ hyprland libGL ] ++ hyprland.buildInputs;
  patches = [ ./rust-renderer.patch ./live-scene.patch ];
  postPatch = ''
    cp -r ${./rust} liquid-rust
    chmod -R u+w liquid-rust
    cp liquid-rust/liquid_glass.h src/
    substituteInPlace src/liquid_glass.h \
      --replace-fail 'LIQUID_GLASS_RADIUS = 28.0f' 'LIQUID_GLASS_RADIUS = ${toString theme.radius}.0f'
    cp ${./tests/live-scene.cpp} liquid-rust/tests/live-scene.cpp
  '';
  preBuild = ''
    export CARGO_HOME="$TMPDIR/cargo-home"
    export LIQUID_GLASS_SURFACE_OPACITY=${toString theme.glass.surfaceOpacity}
    cargo build --manifest-path liquid-rust/Cargo.toml --release --offline --frozen
    export LIQUID_GLASS_LIB="$PWD/liquid-rust/target/release/libliquid_glass.a"
  '';
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    export MESA_SHADER_CACHE_DISABLE=true
    $CXX -std=c++23 -Wall -Wextra -Werror -Isrc liquid-rust/tests/live-scene.cpp -o live-scene-check
    ./live-scene-check
    cargo test --manifest-path liquid-rust/Cargo.toml --offline --frozen
    glslangValidator -S frag liquid-rust/src/liquid.frag
    LIBGL_ALWAYS_SOFTWARE=1 \
      __EGL_VENDOR_LIBRARY_FILENAMES=${mesa}/share/glvnd/egl_vendor.d/50_mesa.json \
      python3 liquid-rust/tests/render.py \
        ${lib.getLib libGL}/lib/libEGL.so.1 \
        ${lib.getLib libGL}/lib/libGLESv2.so.2 \
        liquid-rust/target/release/libliquid_glass.so
    runHook postCheck
  '';
  enableParallelBuilding = true;
  dontUseCmakeConfigure = true;
  installPhase = ''
    runHook preInstall
    install -Dm755 hyprglass.so $out/lib/libhyprglass.so
    runHook postInstall
  '';
  passthru = { inherit hyprland; };
  meta = {
    description = "Rust-driven liquid glass GPU material with live Hyprland backdrops";
    homepage = "https://github.com/hyprnux/hyprglass";
    license = lib.licenses.bsd3;
    platforms = lib.platforms.linux;
  };
}
