require('bufferline').setup({
  options = {
    name_formatter = function(buf)
      -- Get the full path
      local path = buf.path

      -- Extract parent directory and filename
      local parent = vim.fn.fnamemodify(path, ':h:t')
      local filename = vim.fn.fnamemodify(path, ':t')

      -- Return formatted name
      if parent ~= '' and parent ~= '.' then
        return parent .. '/' .. filename
      else
        return filename
      end
    end,
    enforce_regular_tabs = false,  -- Allow variable width tabs
    max_name_length = 30,          -- Increase max name length
  }
})
