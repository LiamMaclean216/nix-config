{ pkgs, ... }:

{
  fonts.packages = with pkgs; [
    # FiraCode patched with Nerd Font glyphs
    nerd-fonts.fira-code
  ];

  # optional: keep some default font packages
  fonts.enableDefaultPackages = true;
}
