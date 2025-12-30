--- Buffer operations for MarkdownLLM.
---@module 'markdownllm.buffer'

local M = {}

local util = require('markdownllm.util')

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

---Toggle the sending flag for a chat buffer.
---@param bufnr integer
---@return nil
function M.toggle_sending_flag(bufnr)
    if vim.api.nvim_buf_is_valid(bufnr) then
        vim.b[bufnr].markdownllm_is_sending = not vim.b[bufnr].markdownllm_is_sending
    end
end

return M
