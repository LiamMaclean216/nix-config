local Identity = {}

local function prompt(value)
	return vim.trim(tostring(value or ""):gsub("%s+", " "))
end

local function review_prompt(session)
	return prompt(session.initial_prompt):lower() == "/review"
end

local function initial_prompt(session)
	-- /plan with inline text submits that text as the first user message.
	-- The command itself is not included in the saved preview.
	return prompt(session.initial_prompt):gsub("^/plan%s+", "")
end

local function candidate(session, thread)
	return not session.id and not (session.known_ids or {})[thread.id]
		and session.switch_kind ~= "resume"
		and vim.fs.normalize(thread.cwd or "") == vim.fs.normalize(session.cwd)
		and (tonumber(thread.createdAt) or 0) >= (session.switch_started_at or session.started_at) - 3
end

-- /review opens a picker; its saved first prompt is generated from the selected
-- target (or custom instructions). Read the first turn's structural marker so
-- identity does not depend on that generated prose or a conversation title.
function Identity.prepare(sessions, threads, read_thread, callback)
	local claimed, reviews, lookups = {}, {}, {}
	for _, session in pairs(sessions) do
		if session.id then
			claimed[session.id] = true
		elseif review_prompt(session) then
			table.insert(reviews, session)
		end
	end
	for _, thread in ipairs(threads) do
		for _, session in ipairs(reviews) do
			if not claimed[thread.id] and candidate(session, thread) then
				table.insert(lookups, thread)
				break
			end
		end
	end
	local remaining = #lookups
	if remaining == 0 then
		callback()
		return
	end
	for _, thread in ipairs(lookups) do
		read_thread(thread.id, function(err, result)
			local saved = not err and result and (result.thread or result)
			local first = saved and saved.id == thread.id and (saved.turns or {})[1]
			for _, item in ipairs(first and first.items or {}) do
				if item.type == "enteredReviewMode" then
					thread._initial_review = true
					break
				end
			end
			remaining = remaining - 1
			if remaining == 0 then
				callback()
			end
		end)
	end
end

local function same_prompt(session, thread)
	if review_prompt(session) and thread._initial_review then
		return true
	end
	local expected = initial_prompt(session)
	local actual = prompt(thread.preview)
	if expected == "" or actual == "" then
		return false
	end
	if expected == actual then
		return true
	end
	if session.initial_prompt_truncated and #expected >= 16 and actual:sub(1, #expected) == expected then
		return true
	end
	-- The list preview may be truncated. A generated title is never identity.
	return #actual >= 16 and #actual < #expected and expected:sub(1, #actual) == actual
end

function Identity.matches(sessions, threads)
	local claimed, pending, candidates, owners, unresolved = {}, {}, {}, {}, {}
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
			-- A thread can be listed before its first preview is persisted. Keep
			-- its temporary row until there is enough evidence to bind it, even
			-- when interruption means no completion notification will arrive.
			if not claimed[thread.id] and candidate(session, thread)
				and initial_prompt(session) ~= "" and prompt(thread.preview) == ""
			then
				unresolved[thread.id] = true
			end
			if not claimed[thread.id] and not seen[thread.id]
				and candidate(session, thread)
				and same_prompt(session, thread)
			then
				seen[thread.id] = true
				table.insert(matches, thread)
				owners[thread.id] = (owners[thread.id] or 0) + 1
			end
		end
		candidates[session] = matches
	end
	local result = {}
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
