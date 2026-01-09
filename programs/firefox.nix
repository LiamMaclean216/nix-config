{ pkgs, ... }:

{
  programs.firefox = {
    enable = true;
    preferences = {
      "ui.systemUsesDarkTheme" = 1;
      "browser.theme.content-theme" = 0;
      "browser.theme.toolbar-theme" = 0;
    };
    # policies = {
      # Install Tridactyl for vim-like keybindings including tab navigation
      # ExtensionSettings = {
      #   "tridactyl.vim@cmcaine.co.uk" = {
      #     installation_mode = "normal_installed";
      #     install_url = "https://addons.mozilla.org/firefox/downloads/latest/tridactyl-vim/latest.xpi";
      #   };
      # };
    # };
  };
}
