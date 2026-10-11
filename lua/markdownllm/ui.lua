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
}

-- ============================================================================
-- Local helpers
-- ============================================================================

---Create a scratch buffer whose writes are intercepted instead of hitting disk.
---@return integer bufnr
local function create_prompt_buffer()
    local bufnr = vim.api.nvim_create_buf(false, true)
    -- `acwrite` lets `:w` succeed without a file, routing writes to BufWriteCmd.
    vim.bo[bufnr].buftype = 'acwrite'
    vim.bo[bufnr].bufhidden = 'wipe'
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].filetype = 'markdown'
    vim.api.nvim_buf_set_name(bufnr, string.format('markdownllm://prompt/%d', bufnr))
    return bufnr
end

---Open a focused floating window centered in the editor, clamped to fit the screen.
---@param bufnr integer
---@param title string
---@return integer winid
local function open_centered_float(bufnr, title)
    -- Reserve two cells per axis for the border.
    local max_width = math.max(1, vim.o.columns - 2)
    local max_height = math.max(1, vim.o.lines - vim.o.cmdheight - 2)
    local width = math.min(max_width, math.max(40, math.floor(vim.o.columns * 0.6)))
    local height = math.min(max_height, math.max(5, math.floor(vim.o.lines * 0.4)))
    return vim.api.nvim_open_win(bufnr, true, {
        relative = 'editor',
        width = width,
        height = height,
        row = math.max(0, math.floor((max_height - height) / 2)),
        col = math.max(0, math.floor((max_width - width) / 2)),
        style = 'minimal',
        border = 'rounded',
        title = title,
        title_pos = 'center',
    })
end

---Wire the submit/cancel lifecycle of a prompt buffer shown in `winid`.
---
---`on_submit` fires exactly once, when the buffer is wiped: with the written text
---if the window was closed with no unsaved changes, otherwise with `nil`.
---@param bufnr integer
---@param winid integer
---@param on_submit fun(input: string|nil): nil
---@return nil
local function attach_prompt_lifecycle(bufnr, winid, on_submit)
    local written_text = nil
    local left_window = false
    vim.api.nvim_create_autocmd('BufWriteCmd', {
        buffer = bufnr,
        callback = function()
            written_text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
            vim.bo[bufnr].modified = false
        end,
    })
    -- A float left behind would keep the prompt pending indefinitely, so leaving
    -- it is treated as closing it.
    vim.api.nvim_create_autocmd('WinLeave', {
        buffer = bufnr,
        callback = function()
            vim.schedule(function()
                -- Still open here means focus moved away rather than the window closing.
                if vim.api.nvim_win_is_valid(winid) then
                    left_window = true
                    vim.api.nvim_win_close(winid, true)
                end
            end)
        end,
    })
    vim.api.nvim_create_autocmd('BufWipeout', {
        buffer = bufnr,
        once = true,
        callback = function()
            -- Unsaved changes mean the user discarded the buffer (e.g. `:q!`).
            local input = nil
            if not left_window and not vim.bo[bufnr].modified then
                input = written_text
            end
            -- Defer so the callback runs after the float is gone and focus is back
            -- on the originating window.
            vim.schedule(function()
                util.safe_call(function()
                    on_submit(input)
                end)
            end)
        end,
    })
end

-- ============================================================================
-- Public API
-- ============================================================================

---Prompt the user to select a preset.
---@param on_select fun(preset: table|nil): nil
---@return nil
function M.select_preset(on_select)
    local presets = config_mod.config.presets or {}
    if not presets or #presets == 0 then
        local ok, default_setup_or_err = pcall(config_mod.get_default_setup)
        if not ok then
            logger.error(default_setup_or_err)
            return
        end
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
    local items = {
        custom_prompt_action,
    }
    vim.list_extend(items, vim.deepcopy(actions))

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

---Open a floating scratch window for freeform action text.
---
---The text is submitted when the window closes with no unsaved changes
---(`:wq`, `:x`, or `:w` followed by `:q`). Closing with unsaved changes (`:q!`)
---or moving focus out of the window cancels with `nil`.
---@param on_submit fun(input: string|nil): nil
---@return nil
function M.prompt_action_text(on_submit)
    local bufnr = create_prompt_buffer()
    local winid = open_centered_float(bufnr, ' MarkdownLLM prompt (:wq to send, :q! to cancel) ')
    attach_prompt_lifecycle(bufnr, winid, on_submit)
    vim.cmd('startinsert')
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
