{
  config,
  pkgs,
  ...
}: let
  dir = "${config.home.homeDirectory}/nix-config";
in {
  home.packages = [
    pkgs.hyprpaper
  ];

  # Hyprpaper: set wallpaper to the repository image
  home.file.".config/hypr/hyprpaper.conf".text = ''
    preload = /home/liam/nix-config/desktop/background.webp
    wallpaper = ,/home/liam/nix-config/desktop/background.webp
  '';
}
