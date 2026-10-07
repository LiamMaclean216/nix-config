# Upstream proposal: https://www.spinics.net/lists/linux-bluetooth/msg129361.html
# Remove once the configured kernel includes the MT7925 ISO padding fix.
{ lib, stdenv, kernel }:
stdenv.mkDerivation {
  pname = "mt7925-iso-padding-modules";
  version = kernel.version;
  src = kernel.src;
  nativeBuildInputs = kernel.moduleBuildDependencies;
  hardeningDisable = [ "pic" "format" ];
  dontPatchELF = true;
  unpackPhase = ''
    mkdir source
    tar -xf "$src" --strip-components=3 -C source linux-${kernel.version}/drivers/bluetooth
    sourceRoot=source
  '';
  patchPhase = ''
    patch --fuzz=0 -p3 < ${./mt7925-iso-padding.patch}
    printf 'obj-m := btmtk.o btusb.o\n' > Makefile
  '';
  buildPhase = ''
    make -C ${kernel.dev}/lib/modules/${kernel.modDirVersion}/build M="$PWD" -j "$NIX_BUILD_CORES" modules
  '';
  installPhase = ''
    # depmod prioritizes updates over the kernel/ tree.
    mkdir -p "$out/lib/modules/${kernel.modDirVersion}/updates"
    cp btmtk.ko btusb.ko "$out/lib/modules/${kernel.modDirVersion}/updates/"
  '';
  meta = {
    description = "Matched btmtk/btusb with upstream MT7925 ISO zero-padding fix";
    license = lib.licenses.gpl2Only;
    platforms = lib.platforms.linux;
    priority = 1;
  };
}
