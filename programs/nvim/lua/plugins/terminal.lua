return {
  {
    "folke/snacks.nvim",
    priority = 1000,
    lazy     = false,
    opts     = {
      terminal = {
        win = {
          -- position = "bottom",
          height   = 0.30,
          keys = {
            term_normal = {
              "<Esc>",
              function(self)
                self:hide()
                vim.cmd("stopinsert")
                vim.schedule(function()
                  SelectFirstWindow()
                end)
              end,
              mode = "t",
              desc = "Close terminal",
            },
          },
        },
      },
    },
  },
}
