{ config, pkgs, lib, inputs, ... }:

let
  theme = import ./theme.nix;
  luaValue = value:
    if builtins.isAttrs value then "{ " + lib.concatStringsSep ", "
      (lib.mapAttrsToList (key: item: "${key} = ${luaValue item}") value) + " }"
    else if builtins.isBool value then (if value then "true" else "false")
    else if builtins.isString value && lib.hasPrefix "0x" value then value
    else builtins.toJSON value;

in
{
  # Chromium/Electron may request the selected source multiple times while
  # preparing a screen share. Reuse the first permission instead of showing
  # Hyprland's share picker for every request.
  xdg.configFile."hypr/xdph.conf".text = ''
    screencopy {
        allow_token_by_default = true
    }
  '';

  # Home Manager 25.05 manages packages; native Lua owns configuration/startup.
  wayland.windowManager.hyprland = {
    enable = true;
    package = pkgs.hyprland;
    portalPackage = pkgs.xdg-desktop-portal-hyprland;
    systemd.enable = false;
  };

  # Preserve the standard session target for dictation and other user services,
  # without the older module's Hyprlang-only startup and config generation.
  systemd.user.targets.hyprland-session.Unit = {
    Description = "Hyprland compositor session";
    Documentation = [ "man:systemd.special(7)" ];
    BindsTo = [ "graphical-session.target" ];
    Wants = [ "graphical-session-pre.target" ];
    After = [ "graphical-session-pre.target" ];
  };

  xdg.configFile."hypr/hyprland.lua".text = lib.mkBefore (builtins.replaceStrings
    [ "@GLASS@" "@GLASS_CONFIG@" "@FADE_SPEED@" "@WINDOW_RADIUS@" "@WINDOW_GEOMETRY_ANIMATIONS@" "@SESSION_START@" ]
    [ "${pkgs.hyprglass}/lib/libhyprglass.so" (luaValue theme.glass.compositor) (toString theme.fadeSpeed) (toString theme.windowRadius) (luaValue theme.windowGeometryAnimations)
      "${pkgs.dbus}/bin/dbus-update-activation-environment --systemd --all && systemctl --user stop hyprland-session.target && systemctl --user start hyprland-session.target"
    ]
    (builtins.readFile ./hyprland.lua));
}
