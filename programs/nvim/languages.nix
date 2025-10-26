{ pkgs, ... }:

{
  programs.nvf.settings.vim = {
    # ============================================
    # Language Support
    # ============================================
    languages = {
      enableFormat = true;
      enableTreesitter = true;
      enableLSP = true;
      enableExtraDiagnostics = true;

      # Python
      python = {
        enable = true;
        lsp = {
          enable = true;
          server = "pyright";
        };
        format = {
          enable = true;
          type = "ruff";
        };
        treesitter.enable = true;
      };

      # TypeScript/JavaScript
      ts = {
        enable = true;
        lsp = {
          enable = true;
          server = "ts_ls";
        };
        format.enable = false;  # prettier not available in nvf
        treesitter.enable = true;
      };

      # Lua
      lua = {
        enable = true;
        lsp = {
          enable = true;
        };
        format.enable = true;
        treesitter.enable = true;
      };

      # HTML
      html = {
        enable = true;
        treesitter.enable = true;
      };

      # CSS
      css = {
        enable = true;
        lsp.enable = true;
        treesitter.enable = true;
        format.enable = false;  # prettier not available in nvf
      };

      # Tailwind
      tailwind.enable = true;

      # Nix
      nix = {
        enable = true;
        lsp.enable = true;
        format.enable = true;
        treesitter.enable = true;
      };

      # Markdown
      markdown = {
        enable = true;
        treesitter.enable = true;
      };

      # Docker
      docker = {
        enable = true;
      };

      # JSON
      json = {
        enable = true;
        treesitter.enable = true;
      };

      # YAML
      yaml = {
        enable = true;
        treesitter.enable = true;
      };
    };

    # ============================================
    # Treesitter Configuration
    # ============================================
    treesitter = {
      enable = true;
      fold = false;
      grammars = [
        pkgs.vimPlugins.nvim-treesitter.builtGrammars.htmldjango
      ];
    };

    # ============================================
    # LSP Configuration
    # ============================================
    lsp = {
      enable = true;
      formatOnSave = false;
      lspSignature.enable = false;
    };

    # ============================================
    # Completion
    # ============================================
    autocomplete = {
      enable = true;
      type = "nvim-cmp";
    };

    # ============================================
    # Snippets
    # ============================================
    snippets = {
      luasnip.enable = true;
    };

    # Django LSP setup
    luaConfigRC.django-lsp = {
      order = 60;
      value = ''
        -- Configure djlsp for Django templates
        require('lspconfig').djlsp.setup({
          filetypes = { "htmldjango", "django" },
          root_dir = function(fname)
            return require('lspconfig.util').root_pattern("manage.py", ".git")(fname)
          end,
        })
      '';
    };
  };
}
