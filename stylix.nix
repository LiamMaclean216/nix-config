{
  inputs,
  config,
  pkgs,
  lib,
  ...
}: {
  # Stylix configuration
  stylix.enable = true;

  # Option 1: Use a scheme from stylix's included themes
  stylix.base16Scheme = "${inputs.stylix.inputs.tinted-schemes}/base16/gruvbox-dark-hard.yaml";

  # Option 2: Or generate colors from a wallpaper (comment out base16Scheme if using this)
  # stylix.image = ./path/to/your/wallpaper.png;

  # Set the polarity
  stylix.polarity = "dark";  # or "light"

  # Optional: Configure fonts
  # stylix.fonts = {
  #   monospace = {
  #     package = pkgs.nerdfonts.override { fonts = [ "FiraCode" ]; };
  #     name = "FiraCode Nerd Font Mono";
  #   };
  #   sansSerif = {
  #     package = pkgs.dejavu_fonts;
  #     name = "DejaVu Sans";
  #   };
  #   serif = {
  #     package = pkgs.dejavu_fonts;
  #     name = "DejaVu Serif";
  #   };
  # };
}
