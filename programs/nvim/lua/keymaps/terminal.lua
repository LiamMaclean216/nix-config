-- Terminal keymaps
package.loaded["keymaps.funcs"] = nil
Funcs = require("config.keymaps.funcs")

local all_modes = { "n", "i", "v", "t", "c", "s" }
local opts = { noremap = true, silent = true }

-- Setup toggleterm terminals
local Terminal = require("toggleterm.terminal").Terminal

-- Lazydocker
local lazydocker = Terminal:new({
	cmd = "lazydocker",
	direction = "float",
	float_opts = {
		width = function()
			return math.floor(vim.o.columns * 0.8)
		end,
		height = function()
			return math.floor(vim.o.lines * 0.8)
		end,
	},
	hidden = true,
	on_open = function(term)
		vim.keymap.set("t", "q", function()
			term:close()
		end, { buffer = term.bufnr, noremap = true, silent = true })
	end,
})

vim.keymap.set("n", "<C-v>", function()
	lazydocker:toggle()
end, { desc = "Lazydocker" })

-- Claude Code terminal
vim.keymap.set("n", "<C-c>", function()
	Funcs.OpenClaudeTerminal()
end, { desc = "Claude Code" })

-- Claude Code terminal with current file reference
vim.keymap.set("n", "<C-S-c>", function()
	Funcs.OpenClaudeTerminal(vim.fn.expand("%"))
end, { desc = "Claude Code with current file" })

-- Bottom terminal
local bottom_terminal = Terminal:new({
	direction = "horizontal",
	hidden = true,
})

vim.keymap.set(all_modes, "<C-/>", function()
	bottom_terminal:toggle()
end, { desc = "Terminal Float" })

-- System paste in all modes
vim.keymap.set(all_modes, "<C-S-v>", function()
	local mode = vim.fn.mode()
	if mode == "i" then
		-- Insert mode: use Ctrl+R to insert from clipboard
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-r>+", true, false, true), "n", false)
	elseif mode == "t" then
		-- Terminal mode: paste directly
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<C-\\><C-n>"+pi', true, false, true), "n", false)
	else
		-- Normal/visual mode: paste after cursor
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('"+p', true, false, true), "n", false)
	end
end, opts)
