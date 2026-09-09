local History = {}

History.__index = History

local function stop_timer(timer)
	if not timer then
		return
	end
	pcall(timer.stop, timer)
	pcall(timer.close, timer)
end

local function usable_text(text)
	if type(text) ~= "string" then
		return nil
	end
	text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
	if not text:find("%S") then
		return nil
	end
	return text
end

local function normalized_text(text)
	if type(text) ~= "string" then
		return ""
	end
	return text:gsub("\r\n", "\n"):gsub("\r", "\n")
end

local function starts_with(text, prefix)
	return #prefix <= #text and text:sub(1, #prefix) == prefix
end

function History.new(opts)
	opts = opts or {}
	local self = setmetatable({}, History)
	self.limit = math.max(1, tonumber(opts.limit) or 100)
	self.write_delay = math.max(0, tonumber(opts.write_delay) or 0)
	self.path = opts.path or vim.fs.joinpath(vim.fn.stdpath("state"), "agent-mode", "prompt-history.json")
	self.on_error = opts.on_error
	self.entries = {}
	self.dirty = false
	self.timer = nil
	self.last_error = nil
	self.active_index = nil
	self.active_text = nil
	self.observed_text = ""
	self:_load()
	return self
end

function History:_report_error(message)
	message = tostring(message)
	if message == self.last_error then
		return
	end
	self.last_error = message
	if type(self.on_error) == "function" then
		self.on_error(message)
	end
end

function History:_trim()
	while #self.entries > self.limit do
		table.remove(self.entries, 1)
	end
end

function History:_load()
	if vim.fn.filereadable(self.path) ~= 1 then
		return
	end
	local read_ok, lines = pcall(vim.fn.readfile, self.path, "b")
	if not read_ok then
		self:_report_error("Could not read prompt history: " .. tostring(lines))
		return
	end
	local decode_ok, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
	if not decode_ok or type(decoded) ~= "table" then
		self:_report_error("Could not decode prompt history; the existing file was left untouched")
		return
	end
	local source = type(decoded.entries) == "table" and decoded.entries or decoded
	local seen = {}
	for _, value in ipairs(source) do
		local text = usable_text(value)
		if text and not seen[text] then
			table.insert(self.entries, text)
			seen[text] = true
		end
	end
	self:_trim()
end

function History:_persist()
	if not self.dirty then
		return true
	end
	local parent = vim.fs.dirname(self.path)
	local mkdir_ok, mkdir_result = pcall(vim.fn.mkdir, parent, "p")
	if not mkdir_ok or vim.fn.isdirectory(parent) ~= 1 then
		self:_report_error("Could not create prompt history directory: " .. tostring(mkdir_result))
		return false
	end
	local encode_ok, encoded = pcall(vim.json.encode, { version = 1, entries = self.entries })
	if not encode_ok then
		self:_report_error("Could not encode prompt history: " .. tostring(encoded))
		return false
	end
	local temporary = string.format("%s.tmp.%d", self.path, vim.fn.getpid())
	local write_ok, write_result = pcall(vim.fn.writefile, { encoded }, temporary, "b")
	if not write_ok or write_result ~= 0 then
		self:_report_error("Could not write prompt history: " .. tostring(write_result))
		return false
	end
	pcall((vim.uv or vim.loop).fs_chmod, temporary, 384) -- 0600
	local rename_ok, rename_error = (vim.uv or vim.loop).fs_rename(temporary, self.path)
	if not rename_ok then
		pcall(vim.fn.delete, temporary)
		self:_report_error("Could not replace prompt history: " .. tostring(rename_error))
		return false
	end
	self.dirty = false
	self.last_error = nil
	return true
end

function History:_schedule_write()
	if self.write_delay == 0 then
		self:_persist()
		return
	end
	if not self.timer then
		self.timer = (vim.uv or vim.loop).new_timer()
	end
	self.timer:stop()
	self.timer:start(self.write_delay, 0, vim.schedule_wrap(function()
		self:_persist()
	end))
end

function History:_changed()
	self:_trim()
	self.dirty = true
	self:_schedule_write()
end

function History:_remove_duplicate(text)
	for index = #self.entries, 1, -1 do
		if self.entries[index] == text then
			table.remove(self.entries, index)
			return true
		end
	end
	return false
end

function History:begin()
	self.active_index = nil
	self.active_text = nil
	self.observed_text = ""
end

function History:_append_active(text)
	self:_remove_duplicate(text)
	table.insert(self.entries, text)
	self:_changed()
	self.active_index = #self.entries
	self.active_text = text
	self.observed_text = text
end

-- Continuously recording each keystroke would otherwise leave "h", "he", and
-- "hel" as separate entries. Grow the newest prefix in place. When text is
-- deleted, retain the fuller snapshot; if typing then diverges, a new entry is
-- appended and both recoverable versions survive.
function History:record(text)
	text = normalized_text(text)
	if not text:find("%S") then
		self.observed_text = text
		return false
	end
	if not self.active_index or self.entries[self.active_index] ~= self.active_text then
		self:_append_active(text)
		return true
	end
	if self.observed_text == text then
		return false
	end
	if starts_with(text, self.observed_text) and starts_with(text, self.active_text) then
		-- Growing a draft can reach an older saved prompt exactly. Deduplicate
		-- that entry too, rather than keeping a second copy of the full prompt.
		table.remove(self.entries, self.active_index)
		self:_append_active(text)
		return true
	end
	if starts_with(self.observed_text, text) then
		self.observed_text = text
		return false
	end
	self:_append_active(text)
	return true
end

-- Submission is a semantic boundary. Keep it even when the final prompt is a
-- shorter prefix of a prior draft, while still keeping exact duplicates out.
function History:record_final(text)
	text = usable_text(text)
	if not text then
		self:begin()
		return false
	end
	if self.active_index and self.entries[self.active_index] == text then
		self:begin()
		return false
	end
	self:_remove_duplicate(text)
	table.insert(self.entries, text)
	self:_changed()
	self:begin()
	return true
end

function History:items()
	return vim.deepcopy(self.entries)
end

function History:flush()
	if self.timer then
		self.timer:stop()
	end
	return self:_persist()
end

function History:close()
	self:flush()
	stop_timer(self.timer)
	self.timer = nil
end

return History
