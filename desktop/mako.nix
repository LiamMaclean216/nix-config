{ config, pkgs, lib, ... }:
let
  theme = import ./theme.nix;
in {
  services.mako = {
    enable = true;

    settings = {
      # Font settings
      font = "${theme.font} 16";

      # Size and spacing
      width = 420;
      margin = "16";
      padding = "20";
      border-size = 0;
      border-radius = theme.radius;

      # Icon settings
      icon-path = "${pkgs.adwaita-icon-theme}/share/icons/Adwaita";
      icons = true;
      max-icon-size = 64;

      # Behavior - persistent notifications until dismissed
      default-timeout = 0;
      ignore-timeout = 1;

      background-color = "#${theme.colors.background}";
      text-color = "#${theme.colors.foreground}";
      progress-color = "over #${theme.colors.accent}";

      # Click behavior
      on-button-left = "exec sh -c 'makoctl invoke -n \"$id\" >/dev/null 2>&1 || true; makoctl dismiss -n \"$id\"'";

      # Hide all notifications by default
      invisible = 1;

      # Criteria sections for app filtering
      "app-name=vesktop" = {
        invisible = 0;
      };
    };
  };
}
