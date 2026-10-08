{ lib, stdenvNoCC, python3, wrapGAppsHook3, gtk3, gtk-layer-shell,
  gobject-introspection, hyprland, adwaita-icon-theme }:
let
  theme = import ../theme.nix;
  python = python3.withPackages (ps: [ ps.pygobject3 ps.pulsectl ]);
in stdenvNoCC.mkDerivation {
  pname = "audio-popup";
  version = "1.0.0";
  src = ./.;
  nativeBuildInputs = [ wrapGAppsHook3 gobject-introspection ];
  buildInputs = [ gtk3 gtk-layer-shell adwaita-icon-theme ];
  dontBuild = true;
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    ${python}/bin/python -m unittest -v test_volume_memory
    runHook postCheck
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin $out/share/audio-popup
    cp popup.py volume_memory.py $out/share/audio-popup/
    cp ${builtins.toFile "audio-popup.css" (theme.renderCss (builtins.readFile ./style.css))} $out/share/audio-popup/style.css
    makeWrapper ${python}/bin/python $out/bin/audio-popup \
      --add-flags "$out/share/audio-popup/popup.py" \
      --prefix PATH : ${lib.makeBinPath [ hyprland ]} \
      --unset LD_LIBRARY_PATH --set GDK_BACKEND wayland
    makeWrapper ${python}/bin/python $out/bin/audio-volume-memory \
      --add-flags "$out/share/audio-popup/volume_memory.py" \
      --unset LD_LIBRARY_PATH
    runHook postInstall
  '';
  meta.mainProgram = "audio-popup";
}
