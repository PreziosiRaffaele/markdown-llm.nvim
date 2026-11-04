---Regression tests for chat window placement and sizing.

local window = require('markdownllm.window')

local failures = {}
local test_count = 0

---@param actual any
---@param expected any
---@param message string
local function assert_same(actual, expected, message)
    if not vim.deep_equal(actual, expected) then
        error(string.format('%s\nexpected: %s\nactual:   %s', message, vim.inspect(expected), vim.inspect(actual)), 2)
    end
end

---Resize the editor down to a single window filling it.
---@param columns integer
---@return nil
local function resize_editor(columns)
    vim.cmd('silent! only!')
    vim.o.columns = columns
    vim.o.lines = 41
    vim.o.cmdheight = 1
    -- Headless Neovim keeps a lone window's old size until the layout is rebuilt.
    vim.cmd('vsplit | split | only!')
end

---Reset the editor to a single window of a known size.
---@return nil
local function reset_editor()
    resize_editor(100)
end

---@param name string
---@param run function
local function test(name, run)
    test_count = test_count + 1
    reset_editor()
    local ok, err = xpcall(run, debug.traceback)
    if not ok then
        table.insert(failures, name .. '\n' .. err)
    end
end

---Open a scratch buffer with the given options.
---@param options markdownllm.WindowOptions
---@return integer winid
local function open_scratch(options)
    return window.open(vim.api.nvim_create_buf(false, true), options)
end

test('vsplit uses a fractional width of the editor', function()
    local winid = open_scratch({ layout = 'vsplit', width = 0.4 })
    assert_same(vim.api.nvim_win_get_width(winid), 40, 'Fraction must be relative to the editor')
end)

test('vsplit uses an absolute width', function()
    local winid = open_scratch({ layout = 'vsplit', width = 30 })
    assert_same(vim.api.nvim_win_get_width(winid), 30, 'A size above 1 must be columns')
end)

test('vsplit width can exceed half of a narrow source window', function()
    vim.cmd('vsplit')
    vim.api.nvim_win_set_width(0, 20)
    local winid = open_scratch({ layout = 'vsplit', width = 0.5 })
    assert_same(vim.api.nvim_win_get_width(winid), 50, 'Width must stay relative to the editor')
end)

test('fractions round to the nearest cell', function()
    for _, case in ipairs({ { 0.29, 29 }, { 0.57, 57 } }) do
        reset_editor()
        local winid = open_scratch({ layout = 'vsplit', width = case[1] })
        assert_same(vim.api.nvim_win_get_width(winid), case[2], 'Floating-point error must not lose a column')
    end
end)

test('oversized splits are capped and keep the source window', function()
    for _, width in ipairs({ 1, 500 }) do
        reset_editor()
        local source = vim.api.nvim_get_current_win()
        local winid = open_scratch({ layout = 'vsplit', width = width })
        assert_same(vim.api.nvim_win_get_width(winid), 80, 'Vsplit must stop at 80% of the editor')
        assert_same(vim.api.nvim_win_get_width(source), 19, 'Source must keep the rest, minus the separator')
    end

    reset_editor()
    local source = vim.api.nvim_get_current_win()
    local split = open_scratch({ layout = 'split', height = 500 })
    assert_same(vim.api.nvim_win_get_height(split), 32, 'Split must stop at 80% of the editor')
    assert_same(vim.api.nvim_win_get_height(source) >= 5, true, 'Source must stay usable')
end)

test('small editors keep the requested size', function()
    resize_editor(30)
    local winid = open_scratch({ layout = 'vsplit', width = 0.5 })
    assert_same(vim.api.nvim_win_get_width(winid), 15, 'A size under the cap must be honoured')
end)

test('open accepts a bare layout name', function()
    local winid = window.open(vim.api.nvim_create_buf(false, true), 'float')
    assert_same(vim.api.nvim_win_get_config(winid).relative, 'editor', 'A layout name must be honoured')
end)

test('open defaults to the current window without options', function()
    local source = vim.api.nvim_get_current_win()
    assert_same(window.open(vim.api.nvim_create_buf(false, true)), source, 'Missing options must mean current')
end)

test('vsplit without a width stays an even split', function()
    local source_width = vim.api.nvim_win_get_width(0)
    local winid = open_scratch({ layout = 'vsplit' })
    assert_same(vim.api.nvim_win_get_width(winid), math.floor(source_width / 2), 'Default must be an even split')
end)

test('vsplit ignores height', function()
    local source_height = vim.api.nvim_win_get_height(0)
    local winid = open_scratch({ layout = 'vsplit', height = 5 })
    assert_same(vim.api.nvim_win_get_height(winid), source_height, 'Height must not apply to vsplit')
end)

test('split uses height and ignores width', function()
    local winid = open_scratch({ layout = 'split', width = 10, height = 0.25 })
    assert_same(vim.api.nvim_win_get_height(winid), 10, 'Fraction must exclude the command line')
    assert_same(vim.api.nvim_win_get_width(winid), 100, 'Width must not apply to split')
end)

test('current ignores sizes', function()
    local source = vim.api.nvim_get_current_win()
    local width = vim.api.nvim_win_get_width(source)
    local winid = open_scratch({ layout = 'current', width = 10, height = 5 })
    assert_same(winid, source, 'Current layout must reuse the window')
    assert_same(vim.api.nvim_win_get_width(winid), width, 'Current layout must not resize')
end)

test('float defaults to 80 percent and stays centered', function()
    local config = vim.api.nvim_win_get_config(open_scratch({ layout = 'float' }))
    assert_same({ config.width, config.height }, { 80, 32 }, 'Default float must cover 80% of the editor')
    assert_same({ config.row, config.col }, { 3, 9 }, 'Float must be centered with its border')
end)

test('float uses configured sizes and defaults the missing one', function()
    local config = vim.api.nvim_win_get_config(open_scratch({ layout = 'float', width = 60 }))
    assert_same({ config.width, config.height }, { 60, 32 }, 'Height must keep its default')
end)

test('float leaves room for its border', function()
    local config = vim.api.nvim_win_get_config(open_scratch({ layout = 'float', width = 500, height = 1 }))
    assert_same({ config.width, config.height }, { 98, 38 }, 'Float must fit with its border')
    assert_same({ config.row, config.col }, { 0, 0 }, 'A maximum-size float must not cover the command line')
end)

test('invalid sizes keep the default size', function()
    local vsplit = open_scratch({ layout = 'vsplit', width = -1 })
    assert_same(vim.api.nvim_win_get_width(vsplit), 50, 'Negative width must be ignored')

    reset_editor()
    local float = open_scratch({ layout = 'float', height = '30%' })
    assert_same(vim.api.nvim_win_get_config(float).height, 32, 'String height must be ignored')
end)

test('unknown layouts fall back to the current window', function()
    local source = vim.api.nvim_get_current_win()
    assert_same(open_scratch({ layout = 'sideways' }), source, 'Unknown layout must use the current window')
end)

test('resolve inherits sizes for the same layout', function()
    local options = window.resolve('vsplit', { layout = 'vsplit', width = 0.4, height = 0.3 })
    assert_same(options, { layout = 'vsplit', width = 0.4, height = 0.3 }, 'Same layout must keep sizes')
end)

test('resolve drops sizes meant for another layout', function()
    local options = window.resolve('vsplit', { layout = 'float', width = 0.9, height = 0.9 })
    assert_same(options, { layout = 'vsplit' }, 'A different layout must not inherit sizes')

    local sized = window.resolve({ layout = 'split', height = 5 }, { layout = 'float', width = 0.9 })
    assert_same(sized, { layout = 'split', height = 5 }, 'Only the placement sizes must remain')
end)

test('resolve treats false as unset', function()
    assert_same(window.resolve(false, 'float'), { layout = 'float' }, 'False must fall back')
    assert_same(window.resolve({ layout = false }, 'float'), { layout = 'float' }, 'False layout must fall back')
end)

test('action picker labels show the layout of table placements', function()
    local config = require('markdownllm.config')
    local ui = require('markdownllm.ui')
    local original_select = vim.ui.select
    local labels = {}

    config.update({
        actions = {
            { name = 'Sized', window = { layout = 'vsplit', width = 0.4 } },
            { name = 'Named', window = 'float' },
            { name = 'Plain' },
        },
    })
    vim.ui.select = function(items, opts)
        for _, item in ipairs(items) do
            table.insert(labels, opts.format_item(item))
        end
    end
    local ok, err = pcall(ui.select_action, function() end)
    vim.ui.select = original_select
    config.update()

    assert_same(ok, true, tostring(err))
    assert_same(labels[2], 'Sized  [window: vsplit]', 'Table placements must show their layout')
    assert_same(labels[3], 'Named  [window: float]', 'Bare names must show as before')
    assert_same(labels[4], 'Plain', 'Actions without a window must have no tag')
end)

test('resolve merges a table placement over the fallback', function()
    local options = window.resolve({ width = 80 }, { layout = 'vsplit', width = 0.4 })
    assert_same(options, { layout = 'vsplit', width = 80 }, 'Fields must merge one by one')
end)

test('resolve accepts bare names and missing placements', function()
    assert_same(window.resolve(nil, 'float'), { layout = 'float' }, 'Fallback name must be used')
    assert_same(window.resolve(nil, nil), {}, 'Missing placements must resolve to no options')
end)

test('resolve does not mutate the configured fallback', function()
    local fallback = { layout = 'vsplit', width = 0.4 }
    window.resolve({ width = 80 }, fallback)
    assert_same(fallback, { layout = 'vsplit', width = 0.4 }, 'Fallback must stay unchanged')
end)

if #failures > 0 then
    error(table.concat(failures, '\n\n'))
end

print(string.format('%d window tests passed', test_count))
