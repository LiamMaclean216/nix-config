{ config, pkgs, lib, ... }:

{
  imports = [
    ./options.nix
    ./languages.nix
    ./ui.nix
    ./plugins.nix
    ./telescope.nix
    ./autocmds.nix
    ./keymaps.nix
    ./functions.nix
  ];

  programs.nvf = {
    enable = true;

    settings = {
      vim = {
        viAlias = true;
        vimAlias = true;
        preventJunkFiles = true;
      };
    };
  };

  # Extra packages needed for formatters and LSPs
  home.packages = with pkgs; [
    python312Packages.debugpy
    nodePackages.stylelint
    nodePackages.svelte-language-server
    nodePackages.prettier
    hadolint
  ];
}
