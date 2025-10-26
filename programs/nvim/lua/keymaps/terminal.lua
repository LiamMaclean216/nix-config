-- Terminal keymaps
package.loaded["keymaps.funcs"] = nil
Funcs = require("config.keymaps.funcs")

local all_modes = { "n", "i", "v", "t", "c", "s" }
local opts = { noremap = true, silent = true }

-- Lazygit
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

-- Lazydocker
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

-- Claude Code terminal
vim.keymap.set("n", "<C-c>", function()
	Funcs.OpenClaudeTerminal()
end, { desc = "Claude Code" })

-- Claude Code terminal with current file reference
vim.keymap.set("n", "<C-S-c>", function()
	Funcs.OpenClaudeTerminal(vim.fn.expand("%"))
end, { desc = "Claude Code with current file" })

-- Bottom terminal
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
