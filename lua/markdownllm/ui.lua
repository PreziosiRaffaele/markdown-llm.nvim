--- UI helpers for MarkdownLLM.
---@module 'markdownllm.ui'

local M = {}

local config_mod = require('markdownllm.config')
local logger = require('markdownllm.logger')
local util = require('markdownllm.util')
local custom_prompt_action = {
    markdownllm_kind = 'custom_prompt',
    name = 'Custom prompt...',
}
local action_kinds = {
    {
        type = 'chat',
        label = 'Chat',
        description = 'Open a chat with the selected text.',
    },
    {
        type = 'replace',
        label = 'Replace',
        description = 'Replace the selection with the model response.',
    },
    {
        type = 'modal',
        label = 'Modal',
        description = 'Show the response in a floating preview.',
    },
}

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
        prompt = 'Select prompt preset > ',
        format_item = function(item)
            local ok, setup = pcall(config_mod.resolve_preset_setup, item)
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
    local items = vim.deepcopy(actions)
    table.insert(items, custom_prompt_action)

    vim.ui.select(items, {
        prompt = 'Select MarkdownLLM action > ',
        format_item = function(item)
            if item.markdownllm_kind == 'custom_prompt' then
                return item.name
            end
            local label = item.name or '(unnamed action)'
            if item.preset then
                label = string.format('%s  [preset: %s]', label, item.preset)
            end
            if item.type then
                local normalized_type = item.type
                if item.type == 'text' or item.type == 'code' then
                    normalized_type = 'chat'
                elseif item.type == 'replace_visual' then
                    normalized_type = 'replace'
                end
                label = string.format('%s  [%s]', label, normalized_type)
            end
            return label
        end,
    }, function(choice)
        util.safe_call(function()
            on_select(choice)
        end)
    end)
end

---Prompt the user for freeform action text.
---@param on_submit fun(input: string|nil): nil
---@return nil
function M.prompt_action_text(on_submit)
    vim.ui.input({
        prompt = 'MarkdownLLM prompt > ',
    }, function(input)
        util.safe_call(function()
            on_submit(input)
        end)
    end)
end

---Prompt the user to select a built-in action kind.
---@param on_select fun(action_kind: table|nil): nil
---@return nil
function M.select_action_kind(on_select)
    vim.ui.select(action_kinds, {
        prompt = 'Select MarkdownLLM action type > ',
        format_item = function(item)
            return string.format('%s  [%s]', item.label, item.description)
        end,
    }, function(choice)
        util.safe_call(function()
            on_select(choice)
        end)
    end)
end

---Open a centered modal preview buffer and window.
---@return integer bufnr
---@return integer winid
function M.open_modal_preview()
    local columns = vim.o.columns
    local lines = vim.o.lines - vim.o.cmdheight
    local width = math.max(40, math.floor(columns * 0.6))
    local height = math.max(4, math.floor(lines * 0.2))

    width = math.min(width, math.max(columns - 4, 1))
    height = math.min(height, math.max(lines - 4, 1))

    local row = math.max(1, math.floor((lines - height) / 2))
    local col = math.max(0, math.floor((columns - width) / 2))

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[bufnr].bufhidden = 'wipe'
    vim.bo[bufnr].buftype = 'nofile'
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].modifiable = true
    vim.bo[bufnr].filetype = 'markdown'

    local winid = vim.api.nvim_open_win(bufnr, true, {
        relative = 'editor',
        row = row,
        col = col,
        width = width,
        height = height,
        style = 'minimal',
        border = 'rounded',
        title = 'MarkdownLLM',
        title_pos = 'center',
    })

    vim.wo[winid].wrap = true
    vim.wo[winid].cursorline = false
    vim.wo[winid].number = false
    vim.wo[winid].relativenumber = false

    local close = function()
        if vim.api.nvim_win_is_valid(winid) then
            vim.api.nvim_win_close(winid, true)
        end
    end

    vim.keymap.set('n', 'q', close, { buffer = bufnr, nowait = true, silent = true })
    vim.keymap.set('n', '<Esc>', close, { buffer = bufnr, nowait = true, silent = true })

    return bufnr, winid
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

    vim.ui.select(names, { prompt = 'Select MarkdownLLM setup > ' }, function(choice)
        util.safe_call(function()
            if choice then
                local setup = config_mod.find_setup(choice)
                on_select(setup)
            end
        end)
    end)
end

return M
