{lib, stdenvNoCC, python3, wrapGAppsHook3, gtk3, gtk-layer-shell, gobject-introspection, pipewire, wl-clipboard, hyprland, libnotify}:
let
  python = python3.withPackages (ps: [ps.pygobject3 ps.websockets]);
in stdenvNoCC.mkDerivation {
  pname = "voice-input";
  version = "1.0.0";
  src = ./.;
  nativeBuildInputs = [wrapGAppsHook3 gobject-introspection];
  buildInputs = [gtk3 gtk-layer-shell];
  dontBuild = true;
  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin $out/share/voice-input
    cp voice_input.py $out/share/voice-input/
    makeWrapper ${python}/bin/python $out/bin/voice-input \
      --add-flags "$out/share/voice-input/voice_input.py" \
      --prefix PATH : ${lib.makeBinPath [pipewire wl-clipboard hyprland libnotify]} \
      --set GDK_BACKEND wayland
    runHook postInstall
  '';
  meta.mainProgram = "voice-input";
}
