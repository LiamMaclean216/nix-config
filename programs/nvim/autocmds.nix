{ lib, ... }:

{
  programs.nvf.settings.vim = {
    # ============================================
    # Autocommands
    # ============================================
    augroups = {
      UserConfig = {
        clear = true;
      };
    };

    autocmds = [
      # Don't continue comments automatically
      {
        event = ["BufEnter"];
        pattern = ["*"];
        group = "UserConfig";
        desc = "Disable automatic comment continuation";
        callback = lib.generators.mkLuaInline ''
          function()
            vim.opt.formatoptions:remove("o")
          end
        '';
      }

      # Pyright Python path configuration
      {
        event = ["LspAttach"];
        group = "UserConfig";
        desc = "Set Pyright Python path to venv";
        callback = lib.generators.mkLuaInline ''
          function(args)
            local client = vim.lsp.get_client_by_id(args.data.client_id)
            if client and client.name == "pyright" then
              vim.schedule(function()
                vim.cmd("PyrightSetPythonPath ~/.venv/bin/python")
              end)
            end
          end
        '';
      }
    ];
  };
}
