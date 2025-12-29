--- UI helpers for MarkdownLLM.
---@module 'markdownllm.ui'

local M = {}

local buffer = require('markdownllm.buffer')
local config_mod = require('markdownllm.config')
local logger = require('markdownllm.logger')
local util = require('markdownllm.util')

---Prompt the user to select a preset.
---@param on_select fun(preset: table|nil): nil
---@return nil
function M.select_preset(on_select)
    local presets = config_mod.config.presets or {}
    if not presets or #presets == 0 then
        on_select(nil)
        return
    end

    vim.ui.select(presets, {
        prompt = 'Select prompt preset',
        format_item = function(item)
            local ok, setup = pcall(config_mod.resolve_preset_setup_name, item)
            if ok then
                return string.format('%s  [setup: %s]', item.name, setup.name)
            end
            local target = item.setup or config_mod.config.default_setup_name or 'unknown'
            return string.format('%s  [❌ INVALID SETUP: %s]', item.name, target)
        end,
    }, function(choice)
        util.safe_call(function()
            on_select(choice)
        end)
    end)
end

---Prompt the user to select an action.
---@param on_select fun(action: table|nil): nil
---@return nil
function M.select_action(on_select)
    local actions = config_mod.config.actions or {}
    if not actions or #actions == 0 then
        logger.warn(
            'No MarkdownLLM actions configured. Add actions in `require("markdownllm").setup({ actions = { ... } })`.'
        )
        on_select(nil)
        return
    end

    vim.ui.select(actions, {
        prompt = 'Select MarkdownLLM action',
        format_item = function(item)
            local label = item.name or '(unnamed action)'
            if item.preset then
                label = string.format('%s  [preset: %s]', label, item.preset)
            end
            if item.type then
                label = string.format('%s  [%s]', label, item.type)
            end
            return label
        end,
    }, function(choice)
        on_select(choice)
    end)
end

---Prompt the user to select a setup.
---@param on_select fun(setup: table): nil
---@return nil
function M.select_setup(on_select)
    local names = config_mod.setup_names()
    if #names == 0 then
        logger.error('No setups configured.')
        return
    end

    vim.ui.select(names, { prompt = 'Select MarkdownLLM setup' }, function(choice)
        util.safe_call(function()
            if choice then
                local setup = config_mod.find_setup(choice)
                on_select(setup)
            end
        end)
    end)
end

---@param setup table
---@return string[]
function M.format_setup_for_edit(setup)
    local header = {
        '-- MarkdownLLM buffer setup',
        '-- Edit the table and :write to apply changes to the original buffer.',
        '',
    }

    local body = 'return ' .. vim.inspect(setup)
    local lines = vim.split(body, '\n', { plain = true })
    vim.list_extend(header, lines)
    return header
end

---@param lines string[]
---@return table|nil
---@return string|nil
function M.parse_setup_from_lines(lines)
    local chunk = table.concat(lines, '\n')
    local fn, err = load(chunk, '=(markdownllm-setup)')
    if not fn then
        return nil, err
    end
    local ok, result = pcall(fn)
    if not ok then
        return nil, result
    end
    if type(result) ~= 'table' then
        return nil, 'Setup must return a table.'
    end
    return result, nil
end

---@param target_bufnr integer
---@return nil
function M.open_setup_editor(target_bufnr)
    if not target_bufnr or not vim.api.nvim_buf_is_valid(target_bufnr) then
        logger.error('Target buffer is not valid.')
        return
    end

    local setup = vim.b[target_bufnr].markdownllm_setup
    if not setup then
        logger.error('No MarkdownLLM setup found for the current buffer.')
        return
    end

    local editor_bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[editor_bufnr].filetype = 'lua'
    vim.bo[editor_bufnr].buftype = 'acwrite'
    vim.bo[editor_bufnr].bufhidden = 'wipe'
    vim.bo[editor_bufnr].swapfile = false
    vim.api.nvim_buf_set_name(editor_bufnr, string.format('markdownLLM-setup-%d.lua', target_bufnr))

    vim.api.nvim_buf_set_lines(editor_bufnr, 0, -1, false, M.format_setup_for_edit(setup))

    local width = math.max(60, math.floor(vim.o.columns * 0.7))
    local height = math.max(12, math.floor(vim.o.lines * 0.6))
    local row = math.floor((vim.o.lines - height) * 0.5)
    local col = math.floor((vim.o.columns - width) * 0.5)

    local winid = vim.api.nvim_open_win(editor_bufnr, true, {
        relative = 'editor',
        width = width,
        height = height,
        row = row,
        col = col,
        style = 'minimal',
        border = 'rounded',
    })

    vim.api.nvim_win_set_option(winid, 'wrap', false)

    local group = vim.api.nvim_create_augroup('MarkdownLLMSetupEditor', { clear = false })

    vim.api.nvim_create_autocmd('BufWriteCmd', {
        group = group,
        buffer = editor_bufnr,
        callback = function()
            local lines = vim.api.nvim_buf_get_lines(editor_bufnr, 0, -1, false)
            local updated, err = M.parse_setup_from_lines(lines)
            if not updated then
                logger.error('Failed to parse setup: ' .. tostring(err))
                return
            end
            if not vim.api.nvim_buf_is_valid(target_bufnr) then
                logger.error('MarkdownLLM buffer no longer exists.')
                return
            end
            buffer.apply_setup_to_buffer(target_bufnr, updated)
            vim.bo[editor_bufnr].modified = false
            logger.info('MarkdownLLM setup updated for the buffer.')
        end,
    })
end

return M
