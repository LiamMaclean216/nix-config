{
  config,
  pkgs,
  ...
}: let
  dir = "${config.home.homeDirectory}/nix-config";
in {
  programs.hyprlock.enable = true;

  home.file.".config/hypr/hyprlock.conf".source = config.lib.file.mkOutOfStoreSymlink (dir + "/desktop/hyprlock.conf");
}
