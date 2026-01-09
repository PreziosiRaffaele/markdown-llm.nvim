--- Utility helpers for MarkdownLLM.
---@module 'markdownllm.util'

local M = {}

local logger = require('markdownllm.logger')

---Trim leading and trailing whitespace.
---@param text string
---@return string
function M.trim(text)
    return (text:gsub('^%s+', ''):gsub('%s+$', ''))
end

---Execute a function safely, logging errors with stack traces.
---@param fn fun(): any
---@return boolean ok, any result_or_error
function M.safe_call(fn)
    return xpcall(fn, function(err)
        local msg = tostring(err)
        local trace = debug.traceback(msg, 2)
        logger.error(trace)
        return msg
    end)
end

---Read the current visual selection as text and range coordinates.
---@return string selection_text
---@return table|nil selection_range
function M.get_visual_selection_text()
    local start_pos = vim.api.nvim_buf_get_mark(0, '<')
    local end_pos = vim.api.nvim_buf_get_mark(0, '>')
    if not start_pos or not end_pos then
        return '', nil
    end

    local start_row, start_col = start_pos[1] - 1, start_pos[2]
    local end_row, end_col = end_pos[1] - 1, end_pos[2]
    if end_row < start_row or (end_row == start_row and end_col < start_col) then
        start_row, end_row = end_row, start_row
        start_col, end_col = end_col, start_col
    end

    local mode = vim.fn.visualmode()
    if mode == 'V' then
        local line_count = vim.api.nvim_buf_line_count(0)
        local last_row = math.min(end_row, math.max(line_count - 1, 0))
        local lines = vim.api.nvim_buf_get_lines(0, start_row, last_row + 1, false)
        local last_line = lines[#lines] or ''
        local range = {
            start_row = start_row,
            start_col = 0,
            end_row = last_row,
            end_col = #last_line,
            mode = mode,
        }
        return table.concat(lines, '\n'), range
    end

    local text = vim.api.nvim_buf_get_text(0, start_row, start_col, end_row, end_col + 1, {})
    local range = {
        start_row = start_row,
        start_col = start_col,
        end_row = end_row,
        end_col = end_col + 1,
        mode = mode,
    }
    return table.concat(text, '\n'), range
end

---Truncate text for compact display.
---@param text string
---@param max_len integer
---@return string
function M.truncate_text(text, max_len)
    if max_len <= 0 then
        return ''
    end

    if #text <= max_len then
        return text
    end

    if max_len <= 3 then
        return string.rep('.', max_len)
    end

    return text:sub(1, max_len - 3) .. '...'
end

return M
