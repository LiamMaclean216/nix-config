{ config, pkgs, lib, ... }:

{
  programs.neovim = {
    enable = true;
    viAlias = true;
    vimAlias = true;

    # If you need extra plugins on top of LazyVim
    plugins = with pkgs.vimPlugins; [
      lazy-nvim
      nvim-treesitter.withAllGrammars
    ];

    extraPackages = with pkgs; [
      # Core
      lua-language-server
      stylua
      ripgrep
      fd

      # Python / Django
      pyright
      ruff
      python312Packages.debugpy

      # Web (HTML/CSS/JS/TS)
      nodePackages.typescript
      nodePackages.typescript-language-server
      nodePackages.vscode-langservers-extracted
      nodePackages."@tailwindcss/language-server"

      nodePackages.eslint              # linting JS/TS
      nodePackages.prettier            # formatting JS/TS/HTML/CSS
      nodePackages.stylelint           # CSS / Tailwind linting
      nodePackages.svelte-language-server # if you use Svelte

      # Docker
      nodePackages.dockerfile-language-server-nodejs
      hadolint

      # JSON / YAML / Misc
      nodePackages.yaml-language-server
      nodePackages.jsonlint
    ];


    extraLuaConfig =
      let
        plugins = with pkgs.vimPlugins; [
          LazyVim
          bufferline-nvim
          cmp-buffer
          cmp-nvim-lsp
          cmp-path
          cmp_luasnip
          conform-nvim
          dashboard-nvim
          dressing-nvim
          flash-nvim
          friendly-snippets
          gitsigns-nvim
          indent-blankline-nvim
          lualine-nvim
          neo-tree-nvim
          neoconf-nvim
          neodev-nvim
          noice-nvim
          nui-nvim
          nvim-cmp
          nvim-lint
          nvim-lspconfig
          nvim-notify
          nvim-spectre
          nvim-treesitter
          nvim-treesitter-context
          vim-commentary
          nvim-treesitter-textobjects
          nvim-ts-autotag
          nvim-ts-context-commentstring
          nvim-web-devicons
          persistence-nvim
          plenary-nvim
          telescope-fzf-native-nvim
          telescope-nvim
          todo-comments-nvim
          tokyonight-nvim
          trouble-nvim
          vim-illuminate
          vim-startuptime
          which-key-nvim
          { name = "LuaSnip"; path = luasnip; }
          { name = "catppuccin"; path = catppuccin-nvim; }
          { name = "mini.ai"; path = mini-nvim; }
          { name = "mini.bufremove"; path = mini-nvim; }
          { name = "mini.comment"; path = mini-nvim; }
          { name = "mini.indentscope"; path = mini-nvim; }
          { name = "mini.pairs"; path = mini-nvim; }
          { name = "mini.surround"; path = mini-nvim; }
          { name = "Commentary"; path = pkgs.vimPlugins.vim-commentary; } 
        ];
        mkEntryFromDrv = drv:
          if lib.isDerivation drv then
            { name = "${lib.getName drv}"; path = drv; }
          else
            drv;
        lazyPath = pkgs.linkFarm "lazy-plugins" (builtins.map mkEntryFromDrv plugins);
      in
      ''
        vim.g.neovide_cursor_animation_length = 0
        vim.g.neovide_cursor_trail_length = 0
        vim.g.neovide_scroll_animation_length = 0
        vim.g.neovide_refresh_rate = 144

        vim.opt.swapfile = false
        vim.opt.laststatus = 3
        vim.opt.relativenumber = true

        vim.g.autoformat = false
        vim.opt.clipboard = "unnamedplus"


        require("lazy").setup({
          defaults = {
            lazy = true,
          },
          dev = {
            -- reuse files from pkgs.vimPlugins.*
            path = "${lazyPath}",
            patterns = { "" },
            -- fallback to download
            fallback = true,
          },
          spec = {
            { "LazyVim/LazyVim", import = "lazyvim.plugins" },
            -- The following configs are needed for fixing lazyvim on nix
            -- force enable telescope-fzf-native.nvim
            { "nvim-telescope/telescope-fzf-native.nvim", enabled = true },
            -- disable mason.nvim, use programs.neovim.extraPackages
            { "williamboman/mason-lspconfig.nvim", enabled = false },
            { "williamboman/mason.nvim", enabled = false },
            -- import/override with your plugins
            { import = "plugins" },
            -- treesitter handled by xdg.configFile."nvim/parser", put this line at the end of spec to clear ensure_installed
            { "nvim-treesitter/nvim-treesitter", opts = { ensure_installed = {} } },
          },
        })

      '';

  };

  # https://github.com/nvim-treesitter/nvim-treesitter#i-get-query-error-invalid-node-type-at-position
  xdg.configFile."nvim/parser".source =
  let
    ts = pkgs.vimPlugins.nvim-treesitter;

    # try withAllGrammars if available, otherwise fall back to withPlugins + allGrammars
    maybeWithAll = builtins.tryEval (ts.withAllGrammars);

    parsers = pkgs.symlinkJoin {
      name = "treesitter-parsers";
      paths = (if maybeWithAll.success
              then maybeWithAll.value
              else (ts.withPlugins (plugins: with plugins; [ ts.allGrammars ]))
              ).dependencies;
    };
  in
    "${parsers}/parser";

  # Normal LazyVim config here, see https://github.com/LazyVim/starter/tree/main/lua
  xdg.configFile."nvim/lua".source = ./nvim/lua;
}
