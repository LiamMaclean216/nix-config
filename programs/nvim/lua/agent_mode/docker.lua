local M = {}

function M.supported(project)
	local root = vim.uv.fs_realpath(vim.fn.expand("~/platform"))
	return root ~= nil and project ~= nil and project.common_dir == root .. "/.git"
end

-- Query runtime state without invoking dev.py ps (which also resolves config/env).
function M.refresh(project, cache, changed)
	if not M.supported(project) or cache.pending or (cache.checked and os.time() - cache.checked < 5) then
		return
	end
	cache.pending = true
	local function done(result)
		vim.schedule(function()
			cache.pending, cache.checked = false, os.time()
			cache.error = result.code ~= 0 and "unavailable" or nil
			cache.worktrees = {}
			if not cache.error then
				for line in (result.stdout or ""):gmatch("[^\r\n]+") do
					local ok, container = pcall(vim.json.decode, line)
					if not ok or type(container) ~= "table" then
						cache.error = "unavailable"
						break
					end
					local path = container.directory
					if path and (container.files or ""):find("docker-compose.override.yml", 1, true) then
						local status = cache.worktrees[path] or { running = 0, total = 0 }
						cache.worktrees[path] = status
						-- Successful one-shot services (e.g. djangosetup) finish normally.
						local completed = container.state == "exited" and (container.status or ""):match("^Exited %(0%)")
						if not completed then status.total = status.total + 1 end
						if container.state == "running" then
							status.running = status.running + 1
							if (container.status or ""):find("(unhealthy)", 1, true) then status.unhealthy = true end
							if container.service == "web" then
								status.port = (container.ports or ""):match(":(%d+)%->8000/tcp")
							end
						end
					end
				end
			end
			changed()
		end)
	end
	local format = '{"directory":{{json (.Label "com.docker.compose.project.working_dir")}},'
		.. '"files":{{json (.Label "com.docker.compose.project.config_files")}},'
		.. '"service":{{json (.Label "com.docker.compose.service")}},'
		.. '"state":{{json .State}},"status":{{json .Status}},"ports":{{json .Ports}}}'
	local ok, err = pcall(vim.system, { "docker", "ps", "-a", "--filter", "label=com.docker.compose.project",
		"--format", format }, { text = true, timeout = 4000 }, done)
	if not ok then done({ code = 1, stderr = tostring(err) }) end
end

function M.label(cache, path)
	if cache.actions and cache.actions[path] then return cache.actions[path] .. "…" end
	if cache.error then return "Docker " .. cache.error end
	if not cache.checked then return "Docker checking…" end
	local status = cache.worktrees and cache.worktrees[path]
	if not status or status.running == 0 then return "Docker down" end
	local label = status.running == status.total and "Docker running" or "Docker partial"
	if status.unhealthy then label = "Docker unhealthy" end
	return label .. (status.port and " · localhost:" .. status.port or "")
end

function M.run(path, action, cache, changed, report)
	cache.actions = cache.actions or {}
	if cache.actions[path] then return end
	if vim.fn.filereadable(path .. "/scripts/dev.py") ~= 1 then
		report("This worktree does not have scripts/dev.py", vim.log.levels.ERROR)
		return
	end
	cache.actions[path] = action == "restart" and "Docker restarting"
		or (action == "up" and "Docker starting" or "Docker stopping")
	changed()
	local function done(result)
		vim.schedule(function()
			cache.actions[path], cache.checked = nil, nil
			if result.code ~= 0 then
				report("Docker " .. action .. " failed: " .. vim.trim(result.stderr or result.stdout or ""), vim.log.levels.ERROR)
			end
			changed()
		end)
	end
	local function execute(command, complete)
		local ok, err = pcall(vim.system, { "python3", "scripts/dev.py", command }, { cwd = path, text = true }, complete)
		if not ok then complete({ code = 1, stderr = tostring(err) }) end
	end
	if action == "restart" then
		-- Reuse the worktree launcher and its saved ports; down preserves volumes.
		execute("down", function(result)
			vim.schedule(function()
				if result.code ~= 0 then done(result) else execute("up", done) end
			end)
		end)
	else
		execute(action, done)
	end
end

function M.destroy(path, cache, changed, callback)
	cache.actions = cache.actions or {}
	if cache.actions[path] then callback("Wait for the current Docker action to finish"); return end
	local root = vim.uv.fs_realpath(path) or path
	local saved = {}
	local state_file = root .. "/.env.worktree"
	if vim.fn.filereadable(state_file) == 1 then
		for _, line in ipairs(vim.fn.readfile(state_file)) do
			local key, value = line:match("^([%w_]+)=(.*)$")
			if key then saved[key] = value end
		end
	end
	if saved.DEV_WORKTREE_ROOT and saved.DEV_WORKTREE_ROOT ~= root then
		callback("Docker state belongs to another checkout"); return
	end
	-- Match platform's dev.py naming even if the worktree never finished starting.
	local slug = vim.fs.basename(root):lower():gsub("[^a-z0-9_-]+", "-"):gsub("^[-_]+", ""):gsub("[-_]+$", "")
	local project = saved.COMPOSE_PROJECT_NAME or ((slug ~= "" and slug or "platform") .. "-" .. vim.fn.sha256(root):sub(1, 8))
	if not project:match("^[a-z0-9][a-z0-9_-]*$") then callback("Invalid Docker project name"); return end
	cache.actions[path] = "Docker wiping"
	changed()
	local function finish(err)
		cache.actions[path], cache.checked = nil, nil
		changed()
		callback(err)
	end
	local function command(args, done)
		local ok, err = pcall(vim.system, vim.list_extend({ "docker" }, args), { text = true }, function(result)
			vim.schedule(function()
				if result.code ~= 0 then
					finish("Docker cleanup failed: " .. vim.trim(result.stderr or ""))
				else
					done(result.stdout or "")
				end
			end)
		end)
		if not ok then finish(tostring(err)) end
	end
	local filter = "label=com.docker.compose.project=" .. project
	local image_names = { [project .. "-app:dev"] = true, [project .. "-jupyter:dev"] = true }
	local stages = {
		{ query = { "ps", "-a", "--filter", filter, "--format",
			'{"id":{{json .ID}},"directory":{{json (.Label "com.docker.compose.project.working_dir")}}}' },
			remove = { "rm", "--force", "--volumes" }, containers = true },
		{ query = { "volume", "ls", "--filter", filter, "--format", "{{.Name}}" }, remove = { "volume", "rm" } },
		{ query = { "network", "ls", "--filter", filter, "--format", "{{.ID}}" }, remove = { "network", "rm" } },
		{ query = { "image", "ls", "--filter", "reference=" .. project .. "-app:dev",
			"--filter", "reference=" .. project .. "-jupyter:dev", "--format", "{{.Repository}}:{{.Tag}}" },
			remove = { "image", "rm" }, images = true },
	}
	local function step(index)
		local stage = stages[index]
		if not stage then finish(); return end
		command(stage.query, function(output)
			local names, seen = {}, {}
			for line in output:gmatch("[^\r\n]+") do
				local name = line
				if stage.containers then
					local ok, container = pcall(vim.json.decode, line)
					if not ok or type(container) ~= "table" or container.directory ~= root or type(container.id) ~= "string" then
						finish("Docker project belongs to another checkout"); return
					end
					name = container.id
				end
				if name ~= "" and not seen[name] and (not stage.images or image_names[name]) then
					table.insert(names, name); seen[name] = true
				end
			end
			if #names == 0 then step(index + 1); return end
			command(vim.list_extend(vim.deepcopy(stage.remove), names), function() step(index + 1) end)
		end)
	end
	local function local_context(host)
		if not host:match("^unix://") and not host:match("^npipe://") then
			finish("Docker cleanup requires a local socket/context"); return
		end
		step(1)
	end
	local context, host = vim.env.DOCKER_CONTEXT, vim.env.DOCKER_HOST
	if (context and context ~= "") or not host or host == "" then
		command({ "context", "inspect", "--format", "{{.Endpoints.docker.Host}}" }, function(host) local_context(vim.trim(host)) end)
	else
		local_context(host)
	end
end

return M
