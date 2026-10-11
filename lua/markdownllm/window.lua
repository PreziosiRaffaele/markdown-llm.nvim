--- Window placement for MarkdownLLM chat buffers.
--- Opens an existing buffer in the current window, a split, a vertical split, or a centered float.
---@module 'markdownllm.window'

local M = {}

local logger = require('markdownllm.logger')

---@alias markdownllm.WindowPlacement 'current'|'split'|'vsplit'|'float'

local placements = {
    current = true,
    split = true,
    vsplit = true,
    float = true,
}

-- Fraction of the editor area covered by a float.
local float_ratio = 0.8

-- ============================================================================
-- Local helpers
-- ============================================================================

---Compute a centered float config covering `float_ratio` of the editor.
---@return table
local function centered_float_config()
    local editor_width = vim.o.columns
    local editor_height = vim.o.lines - vim.o.cmdheight
    local width = math.max(1, math.floor(editor_width * float_ratio))
    local height = math.max(1, math.floor(editor_height * float_ratio))

    return {
        relative = 'editor',
        width = width,
        height = height,
        row = math.floor((editor_height - height) / 2),
        col = math.floor((editor_width - width) / 2),
        style = 'minimal',
        border = 'rounded',
        title = ' MarkdownLLM ',
        title_pos = 'center',
    }
end

---Map `q` to close the float, and drop the mapping once the float closes
---so the buffer behaves normally if it is later shown in a regular window.
---@param bufnr integer
---@param winid integer
---@return nil
local function set_float_close_keymap(bufnr, winid)
    vim.keymap.set('n', 'q', function()
        if vim.api.nvim_win_is_valid(winid) then
            vim.api.nvim_win_close(winid, false)
        end
    end, { buffer = bufnr, nowait = true, desc = 'Close MarkdownLLM float' })

    vim.api.nvim_create_autocmd('WinClosed', {
        pattern = tostring(winid),
        once = true,
        callback = function()
            if vim.api.nvim_buf_is_valid(bufnr) then
                pcall(vim.keymap.del, 'n', 'q', { buffer = bufnr })
            end
        end,
    })
end

---Open a buffer in a centered float and enter it.
---@param bufnr integer
---@return integer winid
local function open_float(bufnr)
    local winid = vim.api.nvim_open_win(bufnr, true, centered_float_config())
    -- Chat responses are prose; wrap long lines instead of scrolling horizontally.
    vim.wo[winid].wrap = true
    vim.wo[winid].linebreak = true
    set_float_close_keymap(bufnr, winid)
    return winid
end

-- ============================================================================
-- Public API
-- ============================================================================

---Open `bufnr` according to `placement` and make it the current window.
---Unknown placements fall back to `current` with a warning.
---@param bufnr integer
---@param placement markdownllm.WindowPlacement|nil defaults to `current`
---@return integer winid window now showing the buffer
function M.open(bufnr, placement)
    placement = placement or 'current'
    if not placements[placement] then
        logger.warn(string.format('Unknown window placement "%s"; using "current".', tostring(placement)))
        placement = 'current'
    end

    if placement == 'float' then
        return open_float(bufnr)
    end

    if placement == 'split' then
        vim.cmd('split')
    elseif placement == 'vsplit' then
        vim.cmd('vsplit')
    end

    local winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(winid, bufnr)
    return winid
end

return M
