-- Set diagnostic sign colors with transparency that fits melange theme
local function setup_diagnostic_colors()
  local bg_hl = vim.api.nvim_get_hl(0, { name = 'Normal' })
  local bg = bg_hl.bg or 0x000000

  -- Blend colors function from gitsigns config
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

  -- Melange-inspired colors
  local colors = {
    error = 0xD47766,  -- Warm red
    warn = 0xEBC06D,   -- Warm yellow
    info = 0x85B5BA,   -- Muted cyan
    hint = 0x89B482,   -- Muted green
  }

  -- Apply blended colors with 50% transparency
  vim.api.nvim_set_hl(0, 'DiagnosticVirtualTextError', {
    fg = string.format('#%06x', blend_colors(colors.error, bg, 0.5)),
  })
  vim.api.nvim_set_hl(0, 'DiagnosticVirtualTextWarn', {
    fg = string.format('#%06x', blend_colors(colors.warn, bg, 0.5)),
  })
  vim.api.nvim_set_hl(0, 'DiagnosticVirtualTextInfo', {
    fg = string.format('#%06x', blend_colors(colors.info, bg, 0.5)),
  })
  vim.api.nvim_set_hl(0, 'DiagnosticVirtualTextHint', {
    fg = string.format('#%06x', blend_colors(colors.hint, bg, 0.5)),
  })
end

-- Setup colors when colorscheme changes
vim.api.nvim_create_autocmd('ColorScheme', {
  pattern = '*',
  callback = setup_diagnostic_colors,
})

-- Trigger immediately
setup_diagnostic_colors()
