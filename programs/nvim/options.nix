{ ... }:

{
  programs.nvf.settings.vim = {
    # ============================================
    # Core Editor Options
    # ============================================
    options = {
      swapfile = false;
      laststatus = 3;
      relativenumber = true;
      number = true;
      clipboard = "unnamedplus";
      timeoutlen = 300;
      guifont = "FiraCode Nerd Font:h10";
    };

    # ============================================
    # Custom Lua Configuration for Options
    # ============================================
    luaConfigRC = {
      # Neovide settings
      neovide-settings = {
        order = 1;
        value = ''
          -- Neovide specific settings
          vim.g.neovide_cursor_animation_length = 0
          vim.g.neovide_cursor_trail_length = 0
          vim.g.neovide_scroll_animation_length = 0
          vim.g.neovide_refresh_rate = 144
        '';
      };
    };
  };
}
