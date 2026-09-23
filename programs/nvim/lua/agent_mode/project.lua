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
			elseif entry and key == "locked" then
				entry.locked = value ~= "" and value or true
			end
		end
	end
	finish_entry()

	return worktrees
end

local function default_branch(cwd, worktrees)
	local remote_head = run({ "git", "-C", cwd, "symbolic-ref", "--quiet", "refs/remotes/origin/HEAD" })
	if remote_head then
		return remote_head:match("^refs/remotes/origin/(.+)$")
	end
	-- Repositories without a remote HEAD commonly use main or master.
	for _, branch in ipairs({ "main", "master" }) do
		if run({ "git", "-C", cwd, "show-ref", "--verify", "--quiet", "refs/heads/" .. branch }) then
			return branch
		end
	end
	return worktrees[1] and worktrees[1].branch or nil
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
		default_branch = default_branch(current_worktree, worktrees),
		worktrees = worktrees,
	}
end

function M.refresh_worktrees(project, callback)
	if not project or not project.common_dir then callback(nil); return end
	local function done(result)
		vim.schedule(function()
			if result.code ~= 0 then
				callback(nil, vim.trim(result.stderr or "git worktree list failed"))
			else
				callback(parse_worktrees(result.stdout or "", project.current_worktree))
			end
		end)
	end
	-- The common directory remains usable if the launch worktree was removed.
	local ok, err = pcall(vim.system,
		{ "git", "--git-dir", project.common_dir, "worktree", "list", "--porcelain" },
		{ text = true, timeout = 4000 }, done)
	if not ok then done({ code = 1, stderr = tostring(err) }) end
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

function M.remove_worktree(project, worktree, callback, before_remove)
	if not project or not project.common_dir then
		callback_later(callback, "This is not a Git worktree")
		return
	end
	M.refresh_worktrees(project, function(worktrees, err)
		if err then callback(err); return end
		local current
		for index, candidate in ipairs(worktrees or {}) do
			if candidate.path == worktree.path then
				if index == 1 then callback("The main worktree cannot be removed"); return end
				current = candidate
			end
		end
		if not current or current.head ~= worktree.head or current.branch ~= worktree.branch then
			callback("The worktree changed; review it and try again")
			return
		end
		if current.locked then callback("The worktree is locked"); return end
		local status, status_err = run({ "git", "-C", current.path, "status", "--porcelain", "--untracked-files=normal" })
		if not status then callback(status_err); return end
		if status ~= "" then callback("The worktree has uncommitted or untracked files"); return end
		local function command(args, done)
			local argv = vim.list_extend({ "git", "--git-dir", project.common_dir }, args)
			local ok, process = pcall(vim.system, argv, { text = true }, function(result)
				vim.schedule(function()
					local detail = vim.trim(result.stderr or "")
					done(result.code ~= 0 and (detail ~= "" and detail or "Git command failed") or nil,
						vim.trim(result.stdout or ""))
				end)
			end)
			if not ok then callback_later(done, tostring(process)) end
		end
		local branch = current.branch
		local function remove()
			local function finish(cleanup_err)
				if cleanup_err then callback(cleanup_err, branch); return end
				-- Never force removal or delete a branch.
				command({ "worktree", "remove", "--", current.path }, function(remove_err)
					callback(remove_err, branch)
				end)
			end
			if before_remove then before_remove(finish) else finish() end
		end
		if branch then remove(); return end
		-- Agent Mode creates detached worktrees. Keep their commits reachable too.
		branch = "worktree/" .. sanitize(basename(current.path)) .. "-" .. current.head:sub(1, 12)
		command({ "show-ref", "--verify", "--hash", "refs/heads/" .. branch }, function(ref_err, head)
			if not ref_err then
				if head ~= current.head then callback("Preservation branch already exists: " .. branch); return end
				remove()
			else
				command({ "branch", "--", branch, current.head }, function(branch_err)
					if branch_err then callback(branch_err); return end
					remove()
				end)
			end
		end)
	end)
end

function M.rename_worktree(project, worktree, name, callback)
	if not project or not project.common_dir then
		callback_later(callback, "This is not a Git worktree")
		return
	end
	if type(name) ~= "string" or name == "" then
		callback_later(callback, "Enter a branch name")
		return
	end
	local checked, check_err = run({ "git", "-C", worktree.path, "check-ref-format", "--branch", name })
	if checked ~= name then
		callback_later(callback, check_err or "Enter a literal branch name")
		return
	end
	M.refresh_worktrees(project, function(worktrees, err)
		if err then callback(err); return end
		local current
		for _, tree in ipairs(worktrees or {}) do
			if tree.path == worktree.path then current = tree; break end
		end
		if not current or current.branch ~= worktree.branch then
			callback("The worktree branch changed; review it and try again")
			return
		end
		if current.branch == name then callback(nil, name); return end
		-- Rename the branch, keeping the checkout path stable for runs and Docker.
		-- Detached worktrees get a branch at their current HEAD without changing files.
		local args = current.branch and { "branch", "-m", "--", current.branch, name }
			or { "switch", "-c", name }
		local function done(result)
			vim.schedule(function()
				if result.code ~= 0 then
					local detail = vim.trim(result.stderr or "")
					callback(detail ~= "" and detail or "Could not rename the branch")
				else
					callback(nil, name)
				end
			end)
		end
		local ok, process = pcall(vim.system, vim.list_extend({ "git", "-C", current.path }, args), { text = true }, done)
		if not ok then callback_later(callback, tostring(process)) end
	end)
end

function M.worktree_name_error(name)
	if type(name) ~= "string" or not name:match("^[%w_-][%w._-]*$") then
		return "Use letters, numbers, dots, underscores or hyphens; names cannot start with a dot"
	end
end

function M.create_worktree(project, base_path, callback, name)
	callback = type(callback) == "function" and callback or function() end
	if name ~= nil then
		local err = M.worktree_name_error(name)
		if err then
			callback_later(callback, err, nil)
			return nil
		end
	end
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

	local path
	if name then
		path = vim.fs.joinpath(parent, name)
		if uv.fs_lstat(path) then
			callback_later(callback, "Worktree path already exists: " .. path, nil)
			return nil
		end
	else
		local timestamp = os.date("!%Y%m%dT%H%M%SZ")
		local pid = vim.fn.getpid()
		repeat
			worktree_counter = worktree_counter + 1
			path = vim.fs.joinpath(parent, string.format("%s-%s-%d", timestamp, pid, worktree_counter))
		until not uv.fs_lstat(path)
	end

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
