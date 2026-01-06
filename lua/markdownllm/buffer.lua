--- Buffer operations for MarkdownLLM.
---@module 'markdownllm.buffer'

local M = {}

local config_mod = require('markdownllm.config')
local logger = require('markdownllm.logger')
local util = require('markdownllm.util')
local ns_loading = vim.api.nvim_create_namespace('markdownllm_loading')

local setup_field_order = {
    'provider',
    'model',
    'api_key_name',
    'base_url',
    'timeout',
    'temperature',
    'max_tokens',
    'top_p',
    'stop',
    'frequency_penalty',
    'presence_penalty',
    'seed',
    'web_search',
}

local setup_fields = {}
for _, key in ipairs(setup_field_order) do
    setup_fields[key] = true
end

---Return true when a line is empty or whitespace-only.
---@param line string|nil
---@return boolean
local function is_blank(line)
    return line == nil or line:match('^%s*$') ~= nil
end

---Return true when a line is a YAML frontmatter delimiter.
---@param line string|nil
---@return boolean
local function is_frontmatter_delimiter(line)
    return line ~= nil and line:match('^%s*%-%-%-%s*$') ~= nil
end

---Find the start/end indices for YAML frontmatter in a buffer.
---@param lines string[]
---@return integer|nil
---@return integer|nil
---@return string|nil
local function find_frontmatter_range(lines)
    local idx = 1
    while idx <= #lines and is_blank(lines[idx]) do
        idx = idx + 1
    end

    if idx > #lines or not is_frontmatter_delimiter(lines[idx]) then
        return nil, nil, nil
    end

    local start_idx = idx
    idx = idx + 1

    while idx <= #lines do
        if is_frontmatter_delimiter(lines[idx]) then
            return start_idx, idx, nil
        end
        idx = idx + 1
    end

    return start_idx, nil, 'Unterminated YAML frontmatter.'
end

---Strip inline comments while honoring quoted segments.
---@param value string
---@return string
local function strip_inline_comment(value)
    local in_single = false
    local in_double = false
    local buf = {}

    for i = 1, #value do
        local ch = value:sub(i, i)
        if ch == "'" and not in_double then
            in_single = not in_single
        elseif ch == '"' and not in_single then
            in_double = not in_double
        elseif ch == '#' and not in_single and not in_double then
            break
        end
        table.insert(buf, ch)
    end

    return util.trim(table.concat(buf))
end

---Unquote a YAML string and unescape known sequences.
---@param value string
---@return string
local function unquote_string(value)
    local quote = value:sub(1, 1)
    local inner = value:sub(2, -2)
    if quote == '"' then
        inner = inner:gsub('\\"', '"')
        inner = inner:gsub('\\\\', '\\')
    elseif quote == "'" then
        inner = inner:gsub("''", "'")
    end
    return inner
end

---Split a YAML inline list into raw item strings.
---@param value string
---@return string[]
local function split_inline_list(value)
    local items = {}
    local buf = {}
    local in_single = false
    local in_double = false

    for i = 1, #value do
        local ch = value:sub(i, i)
        if ch == "'" and not in_double then
            in_single = not in_single
        elseif ch == '"' and not in_single then
            in_double = not in_double
        elseif ch == ',' and not in_single and not in_double then
            table.insert(items, util.trim(table.concat(buf)))
            buf = {}
        else
            table.insert(buf, ch)
        end
    end

    if #buf > 0 then
        table.insert(items, util.trim(table.concat(buf)))
    end

    return items
end

---Parse a YAML scalar or inline list value.
---@param raw string
---@return any
local function parse_yaml_value(raw)
    if raw == nil then
        return nil
    end

    local value = strip_inline_comment(raw)
    if value == '' or value == 'null' or value == '~' then
        return nil
    end

    if value:sub(1, 1) == '[' and value:sub(-1) == ']' then
        local inner = value:sub(2, -2)
        if util.trim(inner) == '' then
            return {}
        end
        local items = split_inline_list(inner)
        local parsed = {}
        for _, item in ipairs(items) do
            table.insert(parsed, parse_yaml_value(item))
        end
        return parsed
    end

    if value:sub(1, 1) == '"' and value:sub(-1) == '"' then
        return unquote_string(value)
    end

    if value:sub(1, 1) == "'" and value:sub(-1) == "'" then
        return unquote_string(value)
    end

    local lowered = value:lower()
    if lowered == 'true' then
        return true
    end
    if lowered == 'false' then
        return false
    end

    if value:match('^%-?%d+$') then
        return tonumber(value)
    end
    if value:match('^%-?%d+%.%d+$') then
        return tonumber(value)
    end

    return value
end

---Parse YAML key/value lines into a Lua table.
---@param lines string[]
---@return table|nil
---@return string|nil
local function parse_yaml_lines(lines)
    local data = {}
    local idx = 1

    while idx <= #lines do
        local line = lines[idx]
        if is_blank(line) or line:match('^%s*#') then
            idx = idx + 1
        else
            local key, rest = line:match('^%s*([%w_%-]+)%s*:%s*(.*)$')
            if not key then
                return nil, 'Invalid YAML line: ' .. line
            end

            if rest == '' then
                local items = {}
                local j = idx + 1
                while j <= #lines do
                    local next_line = lines[j]
                    if is_blank(next_line) or next_line:match('^%s*#') then
                        j = j + 1
                    elseif next_line:match('^%s*-%s+') then
                        local item = next_line:gsub('^%s*-%s+', '')
                        table.insert(items, parse_yaml_value(item))
                        j = j + 1
                    elseif next_line:match('^%s*[%w_%-]+%s*:') then
                        break
                    else
                        break
                    end
                end

                if #items > 0 then
                    data[key] = items
                    idx = j
                else
                    data[key] = nil
                    idx = idx + 1
                end
            else
                data[key] = parse_yaml_value(rest)
                idx = idx + 1
            end
        end
    end

    return data, nil
end

---Escape and quote a YAML string value.
---@param value string
---@return string
local function escape_string(value)
    local escaped = value:gsub('\\', '\\\\'):gsub('"', '\\"')
    return '"' .. escaped .. '"'
end

---Format a Lua scalar as YAML.
---@param value any
---@return string
local function format_yaml_scalar(value)
    if type(value) == 'boolean' then
        return value and 'true' or 'false'
    end
    if type(value) == 'number' then
        return tostring(value)
    end
    if type(value) == 'string' then
        if value == '' then
            return '""'
        end
        if value:match('^[%w%._/%-]+$') then
            return value
        end
        -- Quote strings with spaces or YAML-sensitive characters.
        return escape_string(value)
    end
    return escape_string(tostring(value))
end

---Format a Lua value as YAML, supporting inline lists.
---@param value any
---@return string
local function format_yaml_value(value)
    if type(value) == 'table' then
        local items = {}
        for _, item in ipairs(value) do
            table.insert(items, format_yaml_scalar(item))
        end
        return '[' .. table.concat(items, ', ') .. ']'
    end
    return format_yaml_scalar(value)
end

---Build a new chat buffer template.
---@param instruction_text string|nil
---@return string[]
function M.chat_template(instruction_text)
    local template = {
        '# System',
    }

    if instruction_text and instruction_text ~= '' then
        local lines = vim.split(instruction_text, '\n', { plain = true })
        vim.list_extend(template, lines)
    end

    table.insert(template, '')
    table.insert(template, '# Conversation')
    table.insert(template, '## User')
    table.insert(template, '')

    return template
end

---Extract and parse YAML frontmatter from a chat buffer.
---@param bufnr integer
---@return table|nil
---@return string|nil
function M.parse_setup_from_buffer(bufnr)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local start_idx, end_idx, err = find_frontmatter_range(lines)
    if err then
        return nil, err
    end
    if not start_idx or not end_idx then
        return nil, nil
    end

    local frontmatter = {}
    for i = start_idx + 1, end_idx - 1 do
        table.insert(frontmatter, lines[i])
    end

    local data, parse_err = parse_yaml_lines(frontmatter)
    if not data then
        return nil, parse_err
    end

    local setup = {}
    for key, value in pairs(data) do
        if setup_fields[key] then
            setup[key] = value
        end
    end

    return setup, nil
end

---Serialize a setup table into YAML frontmatter lines.
---@param setup table
---@return string[]
function M.serialize_setup_to_yaml(setup)
    local lines = { '---' }

    local function add_field(key, value, allow_empty)
        if value == nil then
            if allow_empty then
                table.insert(lines, key .. ':')
            end
            return
        end
        if type(value) == 'string' and value == '' and not allow_empty then
            return
        end
        if type(value) == 'table' and #value == 0 then
            return
        end
        table.insert(lines, key .. ': ' .. format_yaml_value(value))
    end

    add_field('provider', setup.provider, true)
    add_field('model', setup.model, true)
    add_field('api_key_name', setup.api_key_name, false)
    add_field('base_url', setup.base_url, false)
    add_field('timeout', setup.timeout, false)
    add_field('temperature', setup.temperature, false)
    add_field('max_tokens', setup.max_tokens, false)
    add_field('top_p', setup.top_p, false)
    add_field('stop', setup.stop, false)
    add_field('frequency_penalty', setup.frequency_penalty, false)
    add_field('presence_penalty', setup.presence_penalty, false)
    add_field('seed', setup.seed, false)
    if setup.web_search == true then
        add_field('web_search', true, false)
    end

    table.insert(lines, '---')
    return lines
end

---Get the chat setup from YAML frontmatter or fall back to the default setup.
---@param bufnr integer
---@return table
function M.get_setup_from_buffer(bufnr)
    local setup, err = M.parse_setup_from_buffer(bufnr)
    if setup then
        return setup
    end

    if err then
        logger.warn('Invalid YAML frontmatter: ' .. err)
    end

    local default_setup = config_mod.get_default_setup()
    local buffer_setup = vim.deepcopy(default_setup)
    buffer_setup.name = nil
    buffer_setup.opts = nil
    return buffer_setup
end

---Update or insert YAML frontmatter representing the setup.
---@param bufnr integer
---@param setup table
---@return nil
---@return string|nil
function M.update_setup_in_buffer(bufnr, setup)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local start_idx, end_idx, err = find_frontmatter_range(lines)
    if err then
        return nil, err
    end

    local yaml_lines = M.serialize_setup_to_yaml(setup)
    local new_lines = {}

    if start_idx and end_idx then
        for i = 1, start_idx - 1 do
            table.insert(new_lines, lines[i])
        end
        vim.list_extend(new_lines, yaml_lines)
        local after_line = lines[end_idx + 1]
        if after_line and not is_blank(after_line) then
            table.insert(new_lines, '')
        end
        for i = end_idx + 1, #lines do
            table.insert(new_lines, lines[i])
        end
    else
        vim.list_extend(new_lines, yaml_lines)
        if #lines > 0 and not is_blank(lines[1]) then
            table.insert(new_lines, '')
        end
        vim.list_extend(new_lines, lines)
    end

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
    return nil, nil
end

---Parse a chat buffer into system text and message list.
---@param bufnr integer
---@return string
---@return table[]
function M.parse_buffer(bufnr)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local system_lines = {}
    local messages = {}
    local mode = 'system'
    local current_role = nil
    local accumulator = {}

    local function flush()
        if current_role and #accumulator > 0 then
            local text = util.trim(table.concat(accumulator, '\n'))
            if text ~= '' then
                table.insert(messages, { role = current_role, text = text })
            end
        end
        accumulator = {}
    end

    for _, line in ipairs(lines) do
        if line:match('^#%s+System') then
            flush()
            mode = 'system'
            current_role = nil
        elseif line:match('^#%s+Conversation') then
            flush()
            mode = 'conversation'
            current_role = nil
        elseif line:match('^##%s+User') then
            flush()
            mode = 'conversation'
            current_role = 'user'
        elseif line:match('^##%s+Model') or line:match('^##%s+Assistant') then
            flush()
            mode = 'conversation'
            current_role = 'model'
        else
            if mode == 'system' then
                table.insert(system_lines, line)
            elseif mode == 'conversation' and current_role then
                table.insert(accumulator, line)
            end
        end
    end

    flush()

    local system_text = util.trim(table.concat(system_lines, '\n'))
    return system_text, messages
end

---Check if a buffer name already exists.
---@param name string
---@return boolean
function M.buffer_name_exists(name)
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) or vim.fn.buflisted(buf) == 1 then
            local bufname = vim.api.nvim_buf_get_name(buf)
            if bufname:match(vim.pesc(name) .. '$') then
                return true
            end
        end
    end
    return false
end

---Generate the next available chat buffer name.
---@return string
function M.next_chat_name()
    local base = 'markdownLLM.md'
    if not M.buffer_name_exists(base) then
        return base
    end

    local idx = 1
    while true do
        local candidate = string.format('markdownLLM-%d.md', idx)
        if not M.buffer_name_exists(candidate) then
            return candidate
        end
        idx = idx + 1
    end
end

---@param bufnr integer
---@param setup table
---@return nil
function M.apply_setup_to_buffer(bufnr, setup)
    local buffer_setup = vim.deepcopy(setup)
    buffer_setup.name = nil
    vim.b[bufnr].markdownllm_setup = buffer_setup
end

---Replace the last user block in a chat buffer.
---@param bufnr integer
---@param user_text string|nil
---@return boolean
function M.replace_last_user_block(bufnr, user_text)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local user_idx = nil
    for i = #lines, 1, -1 do
        if lines[i] == '## User' then
            user_idx = i
            break
        end
    end

    if not user_idx then
        return false
    end

    local new_lines = vim.split(user_text or '', '\n', { plain = true })
    table.insert(new_lines, '')
    vim.api.nvim_buf_set_lines(bufnr, user_idx, -1, false, new_lines)
    return true
end

---Append a model response to the chat buffer.
---@param bufnr integer
---@param response_text string
---@return nil
function M.append_response(bufnr, response_text)
    local winid = vim.fn.bufwinid(bufnr)
    local cursor = nil
    if winid ~= -1 then
        cursor = vim.api.nvim_win_get_cursor(winid)
    end

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local new_block = {}

    if #lines > 0 and lines[#lines]:match('%S') then
        table.insert(new_block, '')
    end

    table.insert(new_block, '## Model')
    local response_lines = vim.split(response_text, '\n', { plain = true })
    vim.list_extend(new_block, response_lines)
    table.insert(new_block, '')
    table.insert(new_block, '## User')
    table.insert(new_block, '')

    vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, new_block)
    if winid ~= -1 and cursor then
        vim.api.nvim_win_set_cursor(winid, cursor)
    end
end

---Append a model header ready for streaming.
---@param bufnr integer
---@return integer
function M.append_loading_model_block(bufnr)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local new_block = {}
    local line_count = #lines

    if line_count > 0 and lines[line_count]:match('%S') then
        table.insert(new_block, '')
    end

    table.insert(new_block, '## Model')
    table.insert(new_block, '')

    vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, new_block)

    return line_count + (#new_block - 1)
end

---Set virtual loading text on a given line.
---@param bufnr integer
---@param line_idx integer
---@param text string
---@return integer
function M.set_loading_virtual_text(bufnr, line_idx, text)
    return vim.api.nvim_buf_set_extmark(bufnr, ns_loading, line_idx, 0, {
        virt_text = { { text, 'Comment' } },
        virt_text_pos = 'eol',
        hl_mode = 'combine',
    })
end

---Clear a loading virtual text extmark.
---@param bufnr integer
---@param mark_id integer|nil
---@return nil
function M.clear_loading_virtual_text(bufnr, mark_id)
    if mark_id and vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_del_extmark(bufnr, ns_loading, mark_id)
    end
end

---Replace a line with the provided text, split on newlines.
---@param bufnr integer
---@param line_idx integer
---@param text string
---@return nil
function M.replace_line_with_text(bufnr, line_idx, text)
    local replacement = vim.split(text or '', '\n', { plain = true })
    vim.api.nvim_buf_set_lines(bufnr, line_idx, line_idx + 1, false, replacement)
end

---Remove a line from the buffer.
---@param bufnr integer
---@param line_idx integer
---@return nil
function M.remove_line(bufnr, line_idx)
    vim.api.nvim_buf_set_lines(bufnr, line_idx, line_idx + 1, false, {})
end

---Toggle the sending flag for a chat buffer.
---@param bufnr integer
---@return nil
function M.toggle_sending_flag(bufnr)
    if vim.api.nvim_buf_is_valid(bufnr) then
        vim.b[bufnr].markdownllm_is_sending = not vim.b[bufnr].markdownllm_is_sending
    end
end

return M
