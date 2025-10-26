-- Neo-tree configuration
local neotree = require("neo-tree")

neotree.setup({
	close_if_last_window = true,
	popup_border_style = "rounded",
	enable_git_status = true,
	enable_diagnostics = true,
	window = {
		position = "left",
		width = 30,
	},
	filesystem = {
		follow_current_file = {
			enabled = true,
		},
		use_libuv_file_watcher = true,
	},
})

-- Function to focus neo-tree
function ToggleNeotree()
	local manager = require("neo-tree.sources.manager")
	local state = manager.get_state("filesystem")

	-- If neo-tree window exists and is visible
	if state.winid and vim.api.nvim_win_is_valid(state.winid) then
		-- Always focus neo-tree
		vim.api.nvim_set_current_win(state.winid)
	else
		-- If neo-tree is not open, open it and focus
		vim.cmd("Neotree")
	end
end
