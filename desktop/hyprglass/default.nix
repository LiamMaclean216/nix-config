{ lib, pkg-config, hyprland, src, rustc, cargo, libGL, glslang, python3, mesa }:
# Hyprland's private C++ ABI requires its own compiler and dependency versions.
hyprland.stdenv.mkDerivation {
  pname = "hyprglass";
  version = "0.8.0-liquid-rust-0.1.0";
  inherit src;
  nativeBuildInputs = [ pkg-config rustc cargo glslang python3 ];
  buildInputs = [ hyprland libGL ] ++ hyprland.buildInputs;
  patches = [ ./rust-renderer.patch ];
  postPatch = ''
    cp -r ${./rust} liquid-rust
    chmod -R u+w liquid-rust
    cp liquid-rust/liquid_glass.h src/
  '';
  preBuild = ''
    export CARGO_HOME="$TMPDIR/cargo-home"
    cargo build --manifest-path liquid-rust/Cargo.toml --release --offline --frozen
    export LIQUID_GLASS_LIB="$PWD/liquid-rust/target/release/libliquid_glass.a"
  '';
  doCheck = true;
  checkPhase = ''
    runHook preCheck
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
