--
require("project_nvim").setup {
  detection_methods = { "lsp", "pattern" },
  -- All the patterns used to detect root dir, when **"pattern"** is in
  -- detection_methods
  patterns = {".gitignore"},
}

