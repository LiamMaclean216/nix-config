-- Configure gitsigns to always show current line blame
require('gitsigns').setup({
  current_line_blame = true,
  current_line_blame_opts = {
    delay = 300,
    virt_text = true,
    virt_text_pos = 'eol', -- 'eol' | 'overlay' | 'right_align'
  },
  current_line_blame_formatter = '<author>, <author_time:%Y-%m-%d> - <summary>',
})

-- Set git blame to match comment color but more transparent
-- Link to Comment highlight group first, then make it more subtle
vim.api.nvim_set_hl(0, 'GitSignsCurrentLineBlame', {
  link = 'Comment'
})

-- Create an autocmd to set a more transparent version after colorscheme loads
vim.api.nvim_create_autocmd('ColorScheme', {
  pattern = '*',
  callback = function()
    local comment_hl = vim.api.nvim_get_hl(0, { name = 'Comment' })
    local comment_fg = comment_hl.fg

    if comment_fg then
      -- Mix comment color with background to create transparency effect
      local bg_hl = vim.api.nvim_get_hl(0, { name = 'Normal' })
      local bg = bg_hl.bg or 0x000000

      -- Blend comment color with background (70% comment, 30% background)
      local function blend_colors(fg, bg, alpha)
        local r1 = bit.rshift(bit.band(fg, 0xFF0000), 16)
        local g1 = bit.rshift(bit.band(fg, 0x00FF00), 8)
        local b1 = bit.band(fg, 0x0000FF)

        local r2 = bit.rshift(bit.band(bg, 0xFF0000), 16)
        local g2 = bit.rshift(bit.band(bg, 0x00FF00), 8)
        local b2 = bit.band(bg, 0x0000FF)

        local r = math.floor(r1 * alpha + r2 * (1 - alpha))
        local g = math.floor(g1 * alpha + g2 * (1 - alpha))
        local b = math.floor(b1 * alpha + b2 * (1 - alpha))

        return bit.bor(bit.lshift(r, 16), bit.lshift(g, 8), b)
      end

      local blended = blend_colors(comment_fg, bg, 0.5)

      vim.api.nvim_set_hl(0, 'GitSignsCurrentLineBlame', {
        fg = string.format('#%06x', blended),
        italic = true,
      })
    end
  end,
})

-- Trigger it immediately
vim.cmd('doautocmd ColorScheme')
