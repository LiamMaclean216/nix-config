-- nvim --headless -u NONE -i NONE -l programs/nvim/tests/agent_mode_docker_cleanup.lua
local Docker = dofile(vim.fn.getcwd() .. "/programs/nvim/lua/agent_mode/docker.lua")
local directory = vim.fn.tempname()
vim.fn.mkdir(directory, "p")
local state_file = directory .. "/.env.worktree"
local function saved(root)
	vim.fn.writefile({ "COMPOSE_PROJECT_NAME=feature-abcd", "DEV_WORKTREE_ROOT=" .. (root or directory) }, state_file)
end
local system, host, context = vim.system, vim.env.DOCKER_HOST, vim.env.DOCKER_CONTEXT
vim.env.DOCKER_HOST, vim.env.DOCKER_CONTEXT = nil, nil
local count = 0
local function test(name, fn) fn(); count = count + 1; print("ok " .. count .. " - " .. name) end
local function cleanup(scenario)
	scenario = scenario or {}
	local calls, finished, error, cache = {}, false, nil, {}
	local project = scenario.project or "feature-abcd"
	vim.system = function(argv, _, callback)
		table.insert(calls, vim.deepcopy(argv))
		assert(argv[1] == "docker")
		local result = { code = 0, stdout = "" }
		local cmd = argv[2] .. " " .. (argv[3] or "")
		if cmd == "context inspect" then
			result.stdout = scenario.remote and "tcp://remote:2375" or "unix:///var/run/docker.sock"
		elseif argv[2] == "ps" then
			assert(vim.tbl_contains(argv, "label=com.docker.compose.project=" .. project))
			result.stdout = scenario.empty and "" or vim.json.encode({ id = "container-id", directory = scenario.foreign and "/other" or directory })
		elseif cmd == "volume ls" or cmd == "network ls" then
			assert(vim.tbl_contains(argv, "label=com.docker.compose.project=" .. project))
			result.stdout = scenario.empty and "" or (cmd == "volume ls" and "project-volume\n" or "project-network\n")
		elseif cmd == "image ls" then
			assert(vim.tbl_contains(argv, "reference=" .. project .. "-app:dev"))
			assert(vim.tbl_contains(argv, "reference=" .. project .. "-jupyter:dev"))
			result.stdout = scenario.empty and "" or (project .. "-app:dev\n" .. project .. "-jupyter:dev\npostgres:16\n")
		elseif argv[2] == "rm" then
			assert(vim.deep_equal(argv, { "docker", "rm", "--force", "--volumes", "container-id" }))
		elseif cmd == "volume rm" then
			assert(vim.deep_equal(argv, { "docker", "volume", "rm", "project-volume" }))
		elseif cmd == "network rm" then
			assert(vim.deep_equal(argv, { "docker", "network", "rm", "project-network" }))
		elseif cmd == "image rm" then
			assert(vim.deep_equal(argv, { "docker", "image", "rm", project .. "-app:dev", project .. "-jupyter:dev" }))
		else assert(false, "unexpected Docker command") end
		if scenario.fail == cmd then result = { code = 1, stderr = "resource still in use" } end
		callback(result)
	end
	Docker.destroy(directory, cache, function() end, function(err) finished, error = true, err end)
	assert(vim.wait(1000, function() return finished end))
	assert(not cache.actions[directory] and not cache.checked)
	return error, calls
end
local ok, err = pcall(function()
	saved()
	test("wipe targets only the worktree project and includes named and anonymous volumes", function()
		local error, calls = cleanup()
		assert(not error, error)
		assert(#calls == 9)
		assert(calls[3][2] == "rm" and calls[5][2] == "volume" and calls[7][2] == "network" and calls[9][2] == "image")
	end)
	test("failed cleanup stops the sequence and returns the error for retry", function()
		local error, calls = cleanup({ fail = "volume rm" })
		assert(error:find("resource still in use", 1, true) and #calls == 5)
	end)
	test("another checkout's containers are never removed", function()
		local error, calls = cleanup({ foreign = true })
		assert(error:find("another checkout", 1, true) and #calls == 2)
	end)
	test("remote Docker contexts are rejected before querying resources", function()
		local error, calls = cleanup({ remote = true })
		assert(error:find("local socket", 1, true) and #calls == 1)
	end)
	test("missing saved state uses platform's deterministic project name", function()
		vim.fn.delete(state_file)
		local slug = vim.fs.basename(directory):lower():gsub("[^a-z0-9_-]+", "-"):gsub("^[-_]+", ""):gsub("[-_]+$", "")
		local project = (slug ~= "" and slug or "platform") .. "-" .. vim.fn.sha256(directory):sub(1, 8)
		local error, calls = cleanup({ empty = true, project = project })
		assert(not error and #calls == 5)
	end)
	test("copied Docker state cannot wipe another worktree's project", function()
		saved("/other")
		local calls, error = 0
		vim.system = function() calls = calls + 1 end
		Docker.destroy(directory, {}, function() end, function(err) error = err end)
		assert(error:find("another checkout", 1, true) and calls == 0)
	end)
end)
vim.system, vim.env.DOCKER_HOST, vim.env.DOCKER_CONTEXT = system, host, context
vim.fn.delete(directory, "rf")
assert(ok, err)
print("Passed " .. count .. " Docker cleanup regression tests")
