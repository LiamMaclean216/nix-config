local M = {}

local uv = vim.uv or vim.loop
local worktree_counter = 0

local function normalize_path(path)
	local absolute = vim.fn.fnamemodify(path, ":p")
	absolute = vim.fs.normalize(absolute)
	if #absolute > 1 then
		absolute = absolute:gsub("/+$", "")
	end

	local real_path = uv.fs_realpath(absolute)
	return vim.fs.normalize(real_path or absolute)
end

local function resolve_path(base, path)
	if path:sub(1, 1) == "/" then
		return normalize_path(path)
	end
	return normalize_path(vim.fs.joinpath(base, path))
end

local function run(argv)
	local ok, process = pcall(vim.system, argv, { text = true })
	if not ok then
		return nil, tostring(process)
	end

	local waited, result = pcall(process.wait, process)
	if not waited then
		return nil, tostring(result)
	end
	if result.code ~= 0 then
		local message = vim.trim(result.stderr or "")
		if message == "" then
			message = vim.trim(result.stdout or "")
		end
		return nil, message
	end

	return (result.stdout or ""):gsub("[\r\n]+$", "")
end

local function basename(path)
	local name = vim.fs.basename(path)
	if not name or name == "" then
		return path
	end
	return name
end

local function pseudo_project(launch_cwd)
	local name = basename(launch_cwd)
	return {
		launch_cwd = launch_cwd,
		current_worktree = launch_cwd,
		common_dir = nil,
		repo_name = name,
		worktrees = {
			{
				path = launch_cwd,
				head = nil,
				branch = nil,
				label = name,
				is_current = true,
			},
		},
	}
end

local function parse_worktrees(output, current_worktree)
	local worktrees = {}
	local entry = nil

	local function finish_entry()
		if not entry or not entry.path then
			entry = nil
			return
		end

		entry.path = normalize_path(entry.path)
		entry.label = entry.branch or basename(entry.path)
		entry.is_current = entry.path == current_worktree
		table.insert(worktrees, entry)
		entry = nil
	end

	output = output:gsub("\r\n", "\n")
	for line in (output .. "\n"):gmatch("(.-)\n") do
		if line == "" then
			finish_entry()
		else
			local key, value = line:match("^(%S+)%s*(.*)$")
			if key == "worktree" then
				finish_entry()
				entry = { path = value }
			elseif entry and key == "HEAD" then
				entry.head = value
			elseif entry and key == "branch" then
				entry.branch = value:gsub("^refs/heads/", "")
			end
		end
	end
	finish_entry()

	return worktrees
end

function M.discover(start_dir)
	local launch_cwd = normalize_path(start_dir or vim.fn.getcwd())
	if vim.fn.filereadable(launch_cwd) == 1 then
		launch_cwd = normalize_path(vim.fs.dirname(launch_cwd))
	end

	local top_level = run({ "git", "-C", launch_cwd, "rev-parse", "--show-toplevel" })
	if not top_level or top_level == "" then
		return pseudo_project(launch_cwd)
	end

	local current_worktree = resolve_path(launch_cwd, top_level)
	local common_dir_output = run({ "git", "-C", current_worktree, "rev-parse", "--git-common-dir" })
	local common_dir = nil
	if common_dir_output and common_dir_output ~= "" then
		common_dir = resolve_path(current_worktree, common_dir_output)
	end

	local list_output = run({ "git", "-C", current_worktree, "worktree", "list", "--porcelain" })
	local worktrees = parse_worktrees(list_output or "", current_worktree)
	if #worktrees == 0 then
		worktrees = {
			{
				path = current_worktree,
				head = nil,
				branch = nil,
				label = basename(current_worktree),
				is_current = true,
			},
		}
	end

	return {
		launch_cwd = launch_cwd,
		current_worktree = current_worktree,
		common_dir = common_dir,
		repo_name = basename(worktrees[1].path),
		worktrees = worktrees,
	}
end

local function is_within(path, root)
	if path == root then
		return true
	end
	if root == "/" then
		return path:sub(1, 1) == "/"
	end
	return path:sub(1, #root + 1) == root .. "/"
end

function M.worktree_for(project, cwd)
	if not project or type(project.worktrees) ~= "table" then
		return nil
	end
	if not cwd or cwd == "" then
		return nil
	end

	local path = normalize_path(cwd)
	local best = nil
	for _, worktree in ipairs(project.worktrees) do
		if worktree.path then
			local root = normalize_path(worktree.path)
			if is_within(path, root) and (not best or #root > #best.path) then
				best = worktree
			end
		end
	end
	return best
end

function M.contains(project, cwd)
	return M.worktree_for(project, cwd) ~= nil
end

local function sanitize(value)
	local sanitized = (value or ""):gsub("[^%w._-]+", "-")
	sanitized = sanitized:gsub("^[-.]+", ""):gsub("[-.]+$", "")
	if sanitized == "" then
		return "project"
	end
	return sanitized
end

local function callback_later(callback, err, path)
	vim.schedule(function()
		callback(err, path)
	end)
end

function M.create_worktree(project, base_path, callback)
	callback = type(callback) == "function" and callback or function() end
	if not project then
		callback_later(callback, "missing project", nil)
		return nil
	end

	base_path = base_path or project.current_worktree or project.launch_cwd
	if not base_path or base_path == "" then
		callback_later(callback, "missing base worktree path", nil)
		return nil
	end
	base_path = normalize_path(base_path)

	local parent = vim.fs.joinpath(vim.fn.expand("~"), ".codex", "worktrees", sanitize(project.repo_name))
	local made_parent, mkdir_result = pcall(vim.fn.mkdir, parent, "p")
	if not made_parent or vim.fn.isdirectory(parent) ~= 1 then
		local detail = made_parent and tostring(mkdir_result) or tostring(mkdir_result)
		callback_later(callback, "could not create worktree directory: " .. detail, nil)
		return nil
	end

	local timestamp = os.date("!%Y%m%dT%H%M%SZ")
	local pid = vim.fn.getpid()
	local path
	repeat
		worktree_counter = worktree_counter + 1
		path = vim.fs.joinpath(parent, string.format("%s-%s-%d", timestamp, pid, worktree_counter))
	until not uv.fs_stat(path)

	return vim.system(
		{ "git", "-C", base_path, "worktree", "add", "--detach", path, "HEAD" },
		{ text = true },
		function(result)
			vim.schedule(function()
				if result.code == 0 then
					callback(nil, path)
					return
				end

				local detail = vim.trim(result.stderr or "")
				if detail == "" then
					detail = vim.trim(result.stdout or "")
				end
				local message = string.format("git worktree add failed (exit %d)", result.code)
				if detail ~= "" then
					message = message .. ": " .. detail
				end
				callback(message, nil)
			end)
		end
	)
end

return M
