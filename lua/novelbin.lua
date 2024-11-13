--- @type integer|nil
local current_buffer = nil
--- @type integer|nil
local current_win = nil
local current_prev = ""
local current_next = ""

local function parse_url(url)
	local host, path = url:match("https://([^/]+)(/.*)")
	if host then
		host = host or url:match("https://([^/]+)")
		path = path or "/"
		return host, path
	end
	host, path = url:match("http://([^/]+)(/.*)")
	if host then
		host = host or url:match("http://([^/]+)")
		path = path or "/"
		return host, path
	end
end

local function resolve_and_fetch_url(host, path, callback)
	host = host:gsub("^https", "http")

	vim.loop.getaddrinfo(host, nil, {}, function(err, res)
		if err or not res or not res[1] then
			callback("DNS resolution failed: " .. (err or "unknown error"))
			return
		end

		local ip = res[1].addr
		local handle = vim.uv.new_tcp()
		local buffer = ""
		local status_code = nil
		local location_header = nil

		handle:connect(ip, 80, function(err)
			if err then
				callback("Failed to connect: " .. err)
				return
			end

			-- Send the initial HTTP request
			local request = "GET "
				.. path
				.. " HTTP/1.1\r\n"
				.. "Host: "
				.. host
				.. "\r\n"
				.. "Connection: close\r\n\r\n"
			handle:write(request)

			-- Start reading the response
			handle:read_start(function(err, chunk)
				if err then
					callback("Read error: " .. err)
					handle:close()
					return
				end

				if chunk then
					buffer = buffer .. chunk

					-- Check for a 302 redirect status code
					if status_code == nil then
						local status_line = buffer:match("HTTP/1.1 (%d%d%d)")
						if status_line then
							status_code = tonumber(status_line)
						end
					end

					-- If a 302 redirect is detected, check for Location header
					if status_code == 302 then
						local location = buffer:match("Location:%s*(.-)\r")
						if location then
							location_header = location:gsub("^https", "http")
						end
					end
				else
					handle:close()

					-- If there was a 302 redirect, follow the new location
					if status_code == 302 and location_header then
						-- Parse the new URL and fetch the redirected page
						local new_host, new_path = parse_url(location_header)
						resolve_and_fetch_url(new_host, new_path, callback)
					else
						-- No redirect or not a 302, process the content as usual
						callback(buffer)
					end
				end
			end)
		end)
	end)
end

local function extract_content(html)
	current_prev = html:match('<a%s+class="btn btn%-success"%s+href="(.-)"%s+title=.-%s+id="prev_chap"')
	current_next = html:match('<a%s+title="[^"]-"%s+href="(.-)"%s+class="btn btn%-success"%s+id="next_chap"')

	local content = ""
	-- Pattern to locate the opening <div> with class "chr-c"
	local start_tag_pattern = '<div[^>]*class="chr%-c"[^>]*>'
	local end_tag = "</div>"

	-- Find the starting position of the div with class "chr-c"
	local start_pos, start_end_pos = html:find(start_tag_pattern)
	if start_pos then
	else
		return content
	end

	-- Start iterating from the opening tag to find the matching closing tag
	local depth = 1 -- Track the depth of nested divs
	local search_pos = start_end_pos + 1
	while depth > 0 do
		local next_open, next_close = html:find("<div", search_pos), html:find(end_tag, search_pos)
		if not next_close then
			return content
		elseif not next_open or next_close < next_open then
			-- Found a closing tag before another opening tag, decrease depth
			depth = depth - 1
			search_pos = next_close + #end_tag
		else
			-- Found an opening tag, increase depth
			depth = depth + 1
			search_pos = next_open + 4 -- Move past `<div`
		end
	end

	-- Extract the full content now that we've found the matching closing tag
	content = html:sub(start_end_pos + 1, search_pos - #end_tag)
	local p_contents = {}

	-- Capture the main content inside the <span class="chr-text">
	table.insert(p_contents, " # " .. html:match('<span%s+class="chr%-text"%s*>(.-)</span>'):gsub("^%s*(.-)%s*$", "%1"))

	for p_content in content:gmatch("<p.->(.-)</p>") do
		p_content = p_content
			:gsub("&nbsp;", " ")
			:gsub("&amp;", "&")
			:gsub("&#39;", "'")
			:gsub("“([^”]*)”", "``%1``") -- Replace matched quotes with backticks
			:gsub("“([^”]*)$", "``%1``") -- Handle cases with unclosed quotes
			:gsub("<i>(.-)</i>", "*%1*")
			:gsub("``[^*]*%*([^*]+)%*[^`]*``", "*``%1``*")

		-- Split multiline paragraphs into separate lines
		for line in p_content:gmatch("[^\r\n]+") do
			table.insert(p_contents, line)
		end
	end

	-- Remove any remaining HTML tags from each line
	for i, line in ipairs(p_contents) do
		p_contents[i] = line:gsub("<[^>]+>", "") -- Remove any HTML tags
	end

	return p_contents
end

local function fetch_url(url, callback)
	local host, path = parse_url(url)
	if not host then
		callback("Invalid URL")
		return
	end
	resolve_and_fetch_url(host, path, function(html)
		local p_content = extract_content(html)
		callback(p_content)
	end)
end

local function setup()
	---@diagnostic disable-next-line: unused-local
	vim.api.nvim_create_user_command("NovelNext", function(opts)
		if current_buffer and vim.api.nvim_buf_is_valid(current_buffer) then
			vim.api.nvim_buf_delete(current_buffer, {})
		end
		vim.cmd(vim.cmd.NovelLoad(current_next))
	end, {})
	---@diagnostic disable-next-line: unused-local
	vim.api.nvim_create_user_command("NovelPrevious", function(opts)
		if current_buffer and vim.api.nvim_buf_is_valid(current_buffer) then
			vim.api.nvim_buf_delete(current_buffer, {})
		end
		vim.cmd(vim.cmd.NovelLoad(current_prev))
	end, {})
	vim.api.nvim_create_user_command("NovelLoad", function(opts)
		local url = opts.args
		fetch_url(url, function(paragraphs)
			vim.schedule(function()
				local content = table.concat(paragraphs, "\n")
				print(current_buffer)
				if not (current_buffer and vim.api.nvim_buf_is_valid(current_buffer)) then
					current_buffer = vim.api.nvim_create_buf(false, true) -- Don't list this buffer
				end

				print(current_buffer)
				vim.api.nvim_buf_set_lines(current_buffer, 0, -1, false, vim.split(content, "\n"))
				if current_win and vim.api.nvim_win_is_valid(current_win) then
					vim.api.nvim_win_set_buf(current_win, current_buffer)
				else
					current_win = vim.api.nvim_open_win(current_buffer, true, {
						relative = "editor", -- Relative to the editor
						width = math.floor(vim.o.columns * 0.8),
						height = math.floor(vim.o.lines * 0.8),
						col = math.floor(vim.o.columns * 0.1),
						row = math.floor(vim.o.lines * 0.1),
						border = "single", -- Optional: add a border for style
					})
				end
				vim.api.nvim_buf_call(current_buffer, function()
					vim.wo.conceallevel = 3
				end)
				vim.api.nvim_set_option_value("filetype", "markdown", { buf = current_buffer })
				vim.api.nvim_set_option_value("buftype", "nofile", { buf = current_buffer })
				vim.api.nvim_set_option_value("swapfile", false, { buf = current_buffer })
				vim.api.nvim_buf_set_keymap(
					current_buffer,
					"n",
					"<Left>",
					":lua vim.cmd.NovelPrevious()<CR>",
					{ noremap = true, silent = true }
				)
				vim.api.nvim_buf_set_keymap(
					current_buffer,
					"n",
					"<Right>",
					":lua vim.cmd.NovelNext()<CR>",
					{ noremap = true, silent = true }
				)
			end)
		end)
	end, { nargs = 1 })
end

return { setup = setup }
