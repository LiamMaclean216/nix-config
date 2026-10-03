{ config, lib, pkgs, ... }:
let
  theme = import ./theme.nix;
  themeJson = pkgs.writeText "desktop-theme.json" (builtins.toJSON themeData);
  themeData = { inherit (theme) colors radius font qt glass; };
  qtTheme = pkgs.runCommand "liquid-glass-qt-theme" {
    nativeBuildInputs = [pkgs.python3];
  } ''
    python ${./qt/render-theme.py} \
      ${pkgs.kdePackages.qtstyleplugin-kvantum}/share/Kvantum/KvMojave \
      ${themeJson} $out
  '';
in {
  qt = {
    enable = true;
    platformTheme = {
      name = "kde6";
      # Hyprland has no KDE application-chooser portal. Keep KDE's palette and
      # use KIO's native, styled Open With dialog for application selection.
      package = pkgs.kdePackages.plasma-integration.overrideAttrs (old: {
        patches = (old.patches or []) ++ [./qt/native-open-with.patch];
      });
    };
    style.name = "kvantum";
  };
  home.packages = [pkgs.kdePackages.breeze-icons];

  xdg.configFile = {
    "Kvantum/kvantum.kvconfig".text = ''
      [General]
      theme=${theme.qt.name}
    '';
    "Kvantum/${theme.qt.name}/${theme.qt.name}.kvconfig".source = "${qtTheme}/${theme.qt.name}.kvconfig";
    "Kvantum/${theme.qt.name}/${theme.qt.name}.svg".source = "${qtTheme}/${theme.qt.name}.svg";
    "hypr/hyprland.lua".text = ''
      -- Apply Qt integration to applications launched by the compositor too.
      hl.env("QT_QPA_PLATFORMTHEME", "kde")
      hl.env("QT_STYLE_OVERRIDE", "kvantum")
      hl.env("QT_PLUGIN_PATH", "${lib.concatStringsSep ":" config.home.sessionSearchVariables.QT_PLUGIN_PATH}")
    '';
  };

  # KDE writes settings here at runtime. Merge only the owned appearance keys,
  # rather than making the entire file an immutable Home Manager symlink.
  home.activation.desktopAppearance = lib.hm.dag.entryAfter ["linkGeneration"] ''
    run ${pkgs.python3}/bin/python ${./qt/apply-settings.py} \
      ${themeJson} "${config.xdg.configHome}/kdeglobals" "${config.xdg.configHome}/dolphinrc"
    run ${pkgs.python3}/bin/python ${./qt/remove-music-place.py} \
      "${config.xdg.dataHome}/user-places.xbel" \
      "$(XDG_CONFIG_HOME=${lib.escapeShellArg config.xdg.configHome} ${pkgs.xdg-user-dirs}/bin/xdg-user-dir MUSIC)"
  '';
}
