{ config, pkgs, lib, ... }:

{
  services.mako = {
    enable = true;

    # Font settings
    font = "Sans 16";

    # Size and spacing
    width = 420;
    margin = "16";
    padding = "20";
    borderSize = 2;
    borderRadius = 8;

    # Icon settings
    iconPath = "${pkgs.adwaita-icon-theme}/share/icons/Adwaita";
    icons = true;
    maxIconSize = 64;

    # Behavior - persistent notifications until dismissed
    defaultTimeout = 0;
    ignoreTimeout = true;

    # Fallback colors (Catppuccin Mocha theme)
    backgroundColor = "#1e1e2e";
    textColor = "#cdd6f4";
    borderColor = "#89b4fa";
    progressColor = "over #89b4fa";

    # Extra configuration for pywal colors and urgency
    extraConfig = ''
      # Source pywal colors (will override fallback colors above)
      source=~/.cache/wal/colors-mako

      # Click behavior
      on-button-left=exec sh -c 'makoctl invoke -n "$id" >/dev/null 2>&1 || true; makoctl dismiss -n "$id"'

      # High urgency notifications
      [urgency=high]
      border-color=#f38ba8
    '';
  };
}
