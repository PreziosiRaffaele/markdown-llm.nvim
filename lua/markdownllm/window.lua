--- Window placement for MarkdownLLM chat buffers.
--- Opens an existing buffer in the current window, a split, a vertical split, or a centered float,
--- and sizes the new window from its options.
---@module 'markdownllm.window'

local M = {}

local logger = require('markdownllm.logger')

---@alias markdownllm.WindowLayout 'current'|'split'|'vsplit'|'float'

---A size up to 1 is a fraction of the editor; a larger one is columns or rows.
---`width` applies to `vsplit` and `float`, `height` to `split` and `float`, and
---layouts ignore the other value, so changing `layout` needs no other edits.
---Split sizes are capped at `split_max_ratio` of the editor, and floats are
---capped to fit on screen with their border.
---@class markdownllm.WindowOptions
---@field layout markdownllm.WindowLayout|nil defaults to `current`
---@field width number|nil
---@field height number|nil

---@alias markdownllm.WindowPlacement markdownllm.WindowLayout|markdownllm.WindowOptions

local layouts = {
    current = true,
    split = true,
    vsplit = true,
    float = true,
}

-- Fraction of the editor area covered by a float without a configured size.
local float_ratio = 0.8

-- Cells taken by the float's border along each dimension.
local float_border_cells = 2

-- Largest fraction of the editor a sized split can cover, so an oversized width
-- or height leaves room for other windows.
local split_max_ratio = 0.8

-- ============================================================================
-- Local helpers
-- ============================================================================

---Return the editor's rows, excluding the command line.
---@return integer
local function get_editor_height()
    return vim.o.lines - vim.o.cmdheight
end

---Convert a placement into its options table.
---Falsy placements mean "unset", so `window = cond and 'vsplit'` stays usable.
---@param placement markdownllm.WindowPlacement|nil
---@return markdownllm.WindowOptions
local function to_options(placement)
    if type(placement) == 'table' then
        return placement
    end
    if not placement then
        return {}
    end
    return { layout = placement }
end

---Return a configured size if it is valid, warning about invalid values.
---@param size any
---@return number|nil
local function usable_size(size)
    if size == nil then
        return nil
    end
    if type(size) ~= 'number' or size <= 0 then
        logger.warn(string.format('Ignoring invalid window size "%s".', tostring(size)))
        return nil
    end
    return size
end

---Convert a valid size into a cell count.
---Rounds to nearest because `0.29 * 100` is slightly below 29 in floating point.
---@param size number fraction of `total` when <= 1, cell count otherwise
---@param total integer cells in the editor along this dimension
---@param max_cells integer largest allowed result
---@return integer cells between 1 and `max_cells`, or 1 when `max_cells` is smaller
local function to_cells(size, total, max_cells)
    local cells = size <= 1 and size * total or size
    return math.max(1, math.min(math.floor(cells + 0.5), max_cells))
end

---Resize the current window when a usable size is configured.
---Resizing after the split, instead of `:{N}vsplit`, lets the window grow past
---the window it was split from, so sizes stay relative to the editor.
---@param set_size fun(winid: integer, cells: integer)
---@param size number|nil
---@param total integer cells in the editor along this dimension
---@return nil
local function resize_current_window(set_size, size, total)
    local valid_size = usable_size(size)
    if valid_size then
        set_size(0, to_cells(valid_size, total, math.floor(total * split_max_ratio)))
    end
end

---Compute one dimension of a float, leaving room for its border.
---@param size number|nil
---@param total integer cells in the editor along this dimension
---@return integer
local function float_cells(size, total)
    return to_cells(usable_size(size) or float_ratio, total, total - float_border_cells)
end

---Compute the offset that centers a float, border included.
---@param cells integer size of the float's content
---@param total integer cells in the editor along this dimension
---@return integer
local function float_offset(cells, total)
    return math.max(0, math.floor((total - cells - float_border_cells) / 2))
end

---Compute a centered float config from the window options.
---@param options markdownllm.WindowOptions
---@return table
local function centered_float_config(options)
    local editor_width = vim.o.columns
    local editor_height = get_editor_height()
    local width = float_cells(options.width, editor_width)
    local height = float_cells(options.height, editor_height)

    return {
        relative = 'editor',
        width = width,
        height = height,
        row = float_offset(height, editor_height),
        col = float_offset(width, editor_width),
        style = 'minimal',
        border = 'rounded',
        title = ' MarkdownLLM ',
        title_pos = 'center',
    }
end

---Return the buffer-local normal-mode `q` mapping of `bufnr`, if any.
---@param bufnr integer
---@return table|nil mapping a `maparg()` dict, restorable with `mapset()`
local function get_buffer_q_mapping(bufnr)
    local mapping = vim.api.nvim_buf_call(bufnr, function()
        return vim.fn.maparg('q', 'n', false, true)
    end)
    if mapping.buffer == 1 then
        return mapping
    end
    return nil
end

---Open a buffer in a centered float and enter it.
---@param bufnr integer
---@param options markdownllm.WindowOptions
---@return integer winid
local function open_float(bufnr, options)
    local winid = vim.api.nvim_open_win(bufnr, true, centered_float_config(options))
    -- Chat responses are prose; wrap long lines instead of scrolling horizontally.
    vim.wo[winid].wrap = true
    vim.wo[winid].linebreak = true
    return winid
end

-- ============================================================================
-- Public API
-- ============================================================================

---Fill in a placement from a fallback placement.
---A missing layout comes from the fallback. The fallback's sizes apply only when
---both use the same layout, because a size chosen for one layout rarely suits
---another: a 90% float would be an oversized vsplit.
---@param placement markdownllm.WindowPlacement|nil
---@param fallback markdownllm.WindowPlacement|nil
---@return markdownllm.WindowOptions
function M.resolve(placement, fallback)
    local options = to_options(placement)
    local fallback_options = to_options(fallback)
    local layout = options.layout or fallback_options.layout
    local inherited = layout == fallback_options.layout and fallback_options or {}

    local resolved = vim.tbl_extend('force', inherited, options)
    resolved.layout = layout
    return resolved
end

---Open `bufnr` according to `placement` and make it the current window.
---Unknown layouts fall back to `current` with a warning.
---@param bufnr integer
---@param placement markdownllm.WindowPlacement|nil defaults to the `current` layout
---@return integer winid window now showing the buffer
function M.open(bufnr, placement)
    local options = to_options(placement)
    local layout = options.layout or 'current'
    if not layouts[layout] then
        logger.warn(string.format('Unknown window layout "%s"; using "current".', tostring(layout)))
        layout = 'current'
    end

    if layout == 'float' then
        return open_float(bufnr, options)
    end

    if layout == 'split' then
        vim.cmd('split')
        resize_current_window(vim.api.nvim_win_set_height, options.height, get_editor_height())
    elseif layout == 'vsplit' then
        vim.cmd('vsplit')
        resize_current_window(vim.api.nvim_win_set_width, options.width, vim.o.columns)
    end

    local winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(winid, bufnr)
    return winid
end

---Map `q` in `bufnr` to close `winid` for as long as that window is open.
---Call it after the buffer's filetype is set, so filetype callbacks cannot
---replace it. A buffer-local `q` mapping it shadows is restored when the
---window closes, so the buffer behaves normally if shown elsewhere later.
---@param bufnr integer
---@param winid integer
---@return nil
function M.map_close_key(bufnr, winid)
    local shadowed_mapping = get_buffer_q_mapping(bufnr)

    vim.keymap.set('n', 'q', function()
        if vim.api.nvim_win_is_valid(winid) then
            vim.api.nvim_win_close(winid, false)
        end
    end, { buffer = bufnr, nowait = true, desc = 'Close MarkdownLLM window' })

    vim.api.nvim_create_autocmd('WinClosed', {
        pattern = tostring(winid),
        once = true,
        callback = function()
            if not vim.api.nvim_buf_is_valid(bufnr) then
                return
            end
            pcall(vim.keymap.del, 'n', 'q', { buffer = bufnr })
            if shadowed_mapping then
                -- mapset() restores buffer-local mappings into the current buffer.
                vim.api.nvim_buf_call(bufnr, function()
                    vim.fn.mapset(shadowed_mapping)
                end)
            end
        end,
    })
end

return M
