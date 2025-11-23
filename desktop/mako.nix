{ config, pkgs, lib, ... }:

{
  services.mako = {
    enable = true;

    settings = {
      # Font settings
      font = "Sans 16";

      # Size and spacing
      width = 420;
      margin = "16";
      padding = "20";
      border-size = 2;
      border-radius = 8;

      # Icon settings
      icon-path = "${pkgs.adwaita-icon-theme}/share/icons/Adwaita";
      icons = true;
      max-icon-size = 64;

      # Behavior - persistent notifications until dismissed
      default-timeout = 0;
      ignore-timeout = 1;

      # Melange theme colors
      background-color = "#292522";  # Melange dark brown background
      text-color = "#ECE1D7";        # Melange light cream foreground
      border-color = "#85B5BA";      # Melange muted cyan
      progress-color = "over #85B5BA";

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
