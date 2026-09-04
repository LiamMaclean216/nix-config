local Identity = {}

local function prompt(value)
	return vim.trim(tostring(value or ""):gsub("%s+", " "))
end

local function same_prompt(session, thread)
	local expected = prompt(session.initial_prompt)
	local actual = prompt(thread.preview)
	if expected == "" or actual == "" then
		return false
	end
	if expected == actual then
		return true
	end
	-- The list preview may be truncated. A generated title is never identity.
	return #actual >= 16 and #actual < #expected and expected:sub(1, #actual) == actual
end

function Identity.matches(sessions, threads)
	local claimed, pending, candidates, owners = {}, {}, {}, {}
	for _, session in pairs(sessions) do
		if session.id then
			claimed[session.id] = true
		else
			table.insert(pending, session)
		end
	end
	-- Build the whole candidate graph before assigning anything. Mutating keys
	-- while iterating used to allow one terminal to claim several different IDs.
	for _, session in ipairs(pending) do
		local matches, seen = {}, {}
		for _, thread in ipairs(threads) do
			if not claimed[thread.id] and not seen[thread.id]
				and not (session.known_ids or {})[thread.id]
				and session.switch_kind ~= "resume"
				and vim.fs.normalize(thread.cwd or "") == vim.fs.normalize(session.cwd)
				and (tonumber(thread.createdAt) or 0) >= (session.switch_started_at or session.started_at) - 3
				and same_prompt(session, thread)
			then
				seen[thread.id] = true
				table.insert(matches, thread)
				owners[thread.id] = (owners[thread.id] or 0) + 1
			end
		end
		candidates[session] = matches
	end
	local result, unresolved = {}, {}
	for _, session in ipairs(pending) do
		local matches = candidates[session]
		if #matches == 1 and owners[matches[1].id] == 1 then
			table.insert(result, { session = session, thread = matches[1] })
		else
			for _, thread in ipairs(matches) do
				unresolved[thread.id] = true
			end
		end
	end
	-- Keep the local rows while identical prompts are ambiguous. Publishing
	-- their candidate saved rows as well would show each conversation twice.
	return result, unresolved
end

return Identity
