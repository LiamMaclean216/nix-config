# nvf Migration Complete

## Summary
Successfully migrated from LazyVim to nvf (NixOS neovim framework) with a modular structure.

## Backups
- Original LazyVim config: `programs/nvim.nix.lazyvim-backup`
- Monolithic nvf config: `programs/nvim.nix.backup`

## New Modular Structure
```
programs/nvim/
├── nvim.nix          # Main entry (imports all modules)
├── options.nix       # Vim options & Neovide settings
├── languages.nix     # LSP, treesitter, formatters
├── ui.nix           # Lualine, bufferline, neo-tree, etc.
├── plugins.nix      # Custom lazy-loaded plugins
├── telescope.nix    # Telescope configuration
├── autocmds.nix     # Autocommands
├── keymaps.nix      # All keybindings
├── functions.nix    # Custom Lua functions
└── README.md        # Documentation
```

## All Keymaps Preserved ✅

### Navigation & Movement
- `n` / `N` - Search forward/backward (centered with zzzv)
- `<C-u>` - Scroll up half page (centered)
- `<C-a>` - Select all
- `<leader>p` - Paste without yanking deleted text
- `v` mode `u` - Disabled (prevent accidental undo)
- `<A-up>` / `<A-down>` - Move lines up/down (normal & visual)

### Telescope (Fuzzy Finding)
- `<C-p>` - Find files
- `<C-f>` - Live grep (search in files)
- ESC closes telescope in both insert and normal mode

### Terminal Management (Snacks)
- `<C-g>` - Open lazygit (floating, 80% size)
- `<C-e>` - Open codex (floating, 80% size)
- `<C-v>` - Open lazydocker (floating, 80% size)
- `<C-c>` - Open Claude Code terminal (right split, 33% width)
- `<C-S-c>` - Open Claude Code with current file reference
- `<C-/>` - Toggle bottom terminal (30% height)
- Works in all modes: normal, insert, visual, terminal, command, select

### Buffer & Window Management
- `<C-l>` / `<C-h>` - Next/previous buffer
- `<C-w>` - Close current buffer
- `<C-k>` - Close all non-code windows
- `<C-S-k>` - Close all windows except current
- `<C-S-w>` - Close all hidden buffers
- `<C-1>` - Select first code window
- `<C-2>` - Open vertical split to the right

### LSP & Code Actions
- `<F2>` - Rename symbol (LSP)
- `<A-S-f>` - Format current buffer (LSP)

### Comments
- `<C-Q>` - Toggle comment (normal, visual, insert)
- `q` - Toggle comment (visual mode only)

### Neovide Font Size
- `<C-+>` - Increase font size
- `<C-->` - Decrease font size

### Paste (Multi-mode)
- `<C-S-v>` - Smart paste:
  - Insert mode: paste from clipboard
  - Terminal mode: paste into terminal
  - Normal/visual: paste after cursor

## Language Support Enabled

All configured with LSP, treesitter, and formatters:
- Python (pyright, ruff, debugpy)
- TypeScript/JavaScript (tsserver, prettier, eslint)
- Lua (lua-ls)
- HTML, CSS, Tailwind
- Docker (dockerfile-ls, hadolint)
- JSON, YAML, Markdown
- Nix (nixd, alejandra)
- Django templates (djlsp, htmldjango treesitter)

## Plugins

### Built-in (via nvf modules)
- Telescope (fuzzy finder)
- Lualine (statusline)
- Bufferline (buffer tabs)
- Neo-tree (file explorer)
- Gitsigns (git integration)
- Which-key (keybind hints)
- nvim-cmp (completion)
- LuaSnip (snippets)
- Comment.nvim (commenting)

### Custom (lazy-loaded)
- **supermaven-nvim** - AI completion
- **melange** - Colorscheme (set as default)
- **git-blame.nvim** - Git blame annotations
- **lazygit.nvim** - Lazygit integration + telescope extension
- **grug-far.nvim** - Search and replace
- **snacks.nvim** - Terminal manager
- **noice.nvim** - Better UI for messages/cmdline/popups
- **nvim-notify** - Notification system

## Editor Options
- No swap files
- Global statusline (laststatus=3)
- Relative line numbers
- System clipboard integration
- 300ms timeout for key sequences
- FiraCode Nerd Font h10

## Neovide Settings
- No cursor animation
- No cursor trail
- No scroll animation
- 144Hz refresh rate

## Custom Functions Preserved
All your custom Lua functions are embedded in the config:
- `Funcs.CloseAllNonCode()` - Close non-code windows
- `Funcs.CloseAllExceptCurrent()` - Close all except current
- `Funcs.CloseHiddenBuffers()` - Close hidden buffers
- `Funcs.OpenClaudeTerminal(file_ref)` - Open Claude terminal
- `SelectFirstWindow()` - Focus first code window
- `OpenVSplitRight()` - Smart vertical split
- `adjust_font_size(delta)` - Font size adjustment

## To Build
```bash
# Update flake inputs
nix flake update nvf

# Switch to new config
home-manager switch --flake .#liam

# Or rebuild full system
sudo nixos-rebuild switch --flake .#nixos
```

## Benefits
- ✅ Fully declarative - no lazy-lock.json to manage
- ✅ Reproducible across machines
- ✅ No Mason - all tools through Nix
- ✅ Faster startup with nvf optimizations
- ✅ All existing functionality preserved
- ✅ Better Nix integration
