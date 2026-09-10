{ pkgs, ... }:
{
  home.packages = [ (import ./wofi-glass/launcher.nix { inherit pkgs; }) ];
}
