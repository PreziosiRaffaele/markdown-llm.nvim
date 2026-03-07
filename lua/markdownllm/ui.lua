--- UI helpers for MarkdownLLM.
---@module 'markdownllm.ui'

local M = {}

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
        prompt = 'Select prompt preset > ',
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
        prompt = 'Select MarkdownLLM action > ',
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
