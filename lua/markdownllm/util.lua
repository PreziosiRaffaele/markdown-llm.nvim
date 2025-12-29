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

---Read the current visual selection as text.
---@return string
function M.get_visual_selection_text()
    local start_pos = vim.api.nvim_buf_get_mark(0, '<')
    local end_pos = vim.api.nvim_buf_get_mark(0, '>')
    if not start_pos or not end_pos then
        return ''
    end

    local start_row, start_col = start_pos[1] - 1, start_pos[2]
    local end_row, end_col = end_pos[1] - 1, end_pos[2]
    if end_row < start_row or (end_row == start_row and end_col < start_col) then
        start_row, end_row = end_row, start_row
        start_col, end_col = end_col, start_col
    end

    local mode = vim.fn.visualmode()
    if mode == 'V' then
        local lines = vim.api.nvim_buf_get_lines(0, start_row, end_row + 1, false)
        return table.concat(lines, '\n')
    end

    local text = vim.api.nvim_buf_get_text(0, start_row, start_col, end_row, end_col + 1, {})
    return table.concat(text, '\n')
end

return M
