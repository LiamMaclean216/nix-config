{ ... }:

{
  programs.nvf.settings.vim = {
    # ============================================
    # Keymaps
    # ============================================
    maps = {
      normal = {
        # Navigation
        "n" = {
          action = "nzzzv";
          silent = true;
        };
        "N" = {
          action = "Nzzzv";
          silent = true;
        };
        "<C-u>" = {
          action = "<C-u>zz";
          silent = true;
        };
        "<leader>p" = {
          action = "\"_dp";
          silent = true;
        };
        "<C-a>" = {
          action = "ggVG";
          silent = true;
        };

        # Telescope
        "<C-p>" = {
          action = "<Cmd>Telescope find_files<CR>";
          silent = true;
        };
        "<C-f>" = {
          action = "<Cmd>Telescope live_grep<CR>";
          silent = true;
        };

        # Font size
        "<C-+>" = {
          lua = true;
          action = "adjust_font_size(1)";
          desc = "Increase font size";
        };
        "<C-->" = {
          lua = true;
          action = "adjust_font_size(-1)";
          desc = "Decrease font size";
        };

        # Buffer navigation
        "<C-l>" = {
          action = ":bnext<CR>";
          silent = true;
        };
        "<C-h>" = {
          action = ":bprevious<CR>";
          silent = true;
        };

        # LSP
        "<F2>" = {
          action = "<cmd>lua vim.lsp.buf.rename()<CR>";
          silent = true;
        };
        "<A-S-f>" = {
          action = ":lua vim.lsp.buf.format()<CR>";
          silent = true;
        };

        # Move lines
        "<A-up>" = {
          action = ":m .-2<cr>==";
          silent = true;
        };
        "<A-down>" = {
          action = ":m .+1<cr>==";
          silent = true;
        };

        # Comments (handled by commentary plugin now)
        "<C-Q>" = {
          action = ":Commentary<CR>";
          silent = true;
        };
      };

      visual = {
        # Disable undo in visual mode
        "u" = {
          action = "<Nop>";
          silent = true;
        };

        # Move lines
        "<A-up>" = {
          action = ":m '<-2<cr>gv=gv";
          silent = true;
        };
        "<A-down>" = {
          action = ":m '>+1<cr>gv=gv";
          silent = true;
        };

        # Comments
        "<C-Q>" = {
          action = ":Commentary<CR>";
          silent = true;
        };
        "q" = {
          action = ":Commentary<CR>";
          silent = true;
        };
      };

      insert = {
        # Comments
        "<C-Q>" = {
          action = "<Esc>:Commentary<CR>";
          silent = true;
        };
      };
    };

    # Complex keymaps that require Lua functions
    luaConfigRC.complex-keymaps = {
      order = 90;
      value = ''
        -- Terminal keymaps (using Snacks)
        vim.keymap.set("n", "<C-g>", function()
          Snacks.terminal("lazygit", {
            esc_esc = true,
            ctrl_hjkl = false,
            win = {
              position = "float",
              width = 0.8,
              height = 0.8,
            },
          })
        end, { desc = "Lazygit" })

        vim.keymap.set("n", "<C-e>", function()
          Snacks.terminal("codex", {
            esc_esc = true,
            ctrl_hjkl = false,
            win = {
              position = "float",
              width = 0.8,
              height = 0.8,
            },
          })
        end, { desc = "Codex" })

        vim.keymap.set("n", "<C-v>", function()
          Snacks.terminal("lazydocker", {
            esc_esc = true,
            ctrl_hjkl = false,
            win = {
              position = "float",
              width = 0.8,
              height = 0.8,
            },
          })
        end, { desc = "Lazydocker" })

        -- Claude Code terminal keymaps
        vim.keymap.set("n", "<C-c>", function()
          Funcs.OpenClaudeTerminal()
        end, { desc = "Claude Code" })

        vim.keymap.set("n", "<C-S-c>", function()
          Funcs.OpenClaudeTerminal(vim.fn.expand("%"))
        end, { desc = "Claude Code with current file" })

        -- Terminal toggle (all modes)
        local all_modes = { "n", "i", "v", "t", "c", "s" }

        vim.keymap.set(all_modes, "<C-/>", function()
          Snacks.terminal(nil, {
            esc_esc = true,
            ctrl_hjkl = false,
            win = {
              position = "bottom",
              height = 0.30,
            },
          })
        end, { desc = "Terminal Bottom" })

        -- Window/buffer management keymaps
        local opts = { noremap = true, silent = true }

        vim.keymap.set(all_modes, "<C-k>", "<Esc><Cmd>lua Funcs.CloseAllNonCode()<CR>", opts)
        vim.keymap.set(all_modes, "<C-S-k>", "<Esc><Cmd>lua Funcs.CloseAllExceptCurrent()<CR>", opts)
        vim.keymap.set(all_modes, "<C-w>", ":bdelete<CR>", vim.tbl_extend("force", opts, { nowait = true }))
        vim.keymap.set(all_modes, "<C-S-w>", "<Esc><Cmd>lua Funcs.CloseHiddenBuffers()<CR>", opts)

        vim.keymap.set(all_modes, "<C-1>", "<Esc><Cmd>lua SelectFirstWindow()<CR>", opts)
        vim.keymap.set(all_modes, "<C-2>", "<Esc><Cmd>lua OpenVSplitRight()<CR>", opts)

        -- Smart paste in different modes
        vim.keymap.set(all_modes, "<C-S-v>", function()
          local mode = vim.fn.mode()
          if mode == "i" then
            vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-r>+", true, false, true), "n", false)
          elseif mode == "t" then
            vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<C-\\><C-n>"+pi', true, false, true), "n", false)
          else
            vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('"+p', true, false, true), "n", false)
          end
        end, opts)
      '';
    };
  };
}
