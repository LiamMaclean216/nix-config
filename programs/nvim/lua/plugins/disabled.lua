return {
  {
    "akinsho/bufferline.nvim",
    enabled = true,
  },
  {
    "folke/flash.nvim",
    enabled = false,
  },
  {
    "nvim-lualine/lualine.nvim",
    enabled = true,
    opts = function(_, opts)
      opts.sections.lualine_z = {}
    end,
  },
}
