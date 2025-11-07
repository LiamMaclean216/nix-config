-- Telescope configuration
local telescope = require("telescope")
local actions = require("telescope.actions")

telescope.setup({
	defaults = {
		mappings = {
			i = {
				["<esc>"] = actions.close,
				["<C-k>"] = actions.cycle_history_prev,
				["<C-j>"] = actions.cycle_history_next,
			},
			n = {
				["<esc>"] = actions.close,
				["<C-k>"] = actions.cycle_history_prev,
				["<C-j>"] = actions.cycle_history_next,
			},
		},
		layout_config = {
			-- width = 0.5,
			-- height = 0.5, -- You can adjust this value (0-1 for percentage of screen)
		},
		file_ignore_patterns = {
			-- Git
			".git/",

			-- Node
			"node_modules",

			-- Python
			"__pycache__",
			".pytest_cache",
			".venv",
			"venv",

			-- Build output
			"dist",
			"build",
			"target",

			-- Cache and temp files
			".cache",
			"%.o",
			"%.a",
			"%.out",
			"%.class",
			"%.pdf",

			-- Editor files
			".vscode",
			".idea",
		},

		vimgrep_arguments = {
			"rg",
			"--color=never",
			"--no-heading",
			"--with-filename",
			"--line-number",
			"--column",
			"--smart-case",
			-- Exclude directories via ripgrep glob patterns
			"--glob=!node_modules/**",
			"--glob=!.git/**",
			"--glob=!**/__pycache__/**",
			"--glob=!**/.pytest_cache/**",
			"--glob=!**/venv/**",
			"--glob=!**/.venv/**",
		},
	},

	extensions = {
		fzf = {
			fuzzy = true,
			override_generic_sorter = true,
			override_file_sorter = true,
			case_mode = "smart_case",
		},
	},
})

-- Load extensions
telescope.load_extension("fzf")

-- Keybindings (these override the ones in init.lua if they conflict)
vim.keymap.set("n", "<C-p>", "<cmd>Telescope find_files<cr>", { desc = "Find files" })
vim.keymap.set("n", "<C-f>", "<cmd>Telescope live_grep<cr>", { desc = "Live grep" })
vim.keymap.set("n", "<leader>fb", "<cmd>Telescope buffers<cr>", { desc = "Find buffers" })
vim.keymap.set("n", "<leader>fh", "<cmd>Telescope help_tags<cr>", { desc = "Help tags" })
vim.keymap.set("n", "<leader>fr", "<cmd>Telescope oldfiles<cr>", { desc = "Recent files" })
vim.keymap.set("n", "<leader>fc", "<cmd>Telescope commands<cr>", { desc = "Commands" })
vim.keymap.set("n", "<leader>fk", "<cmd>Telescope keymaps<cr>", { desc = "Keymaps" })
