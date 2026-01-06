--- MarkdownLLM: markdown-driven chat buffer
---@module 'markdownllm'

local M = {}

local core = require('markdownllm.core')
local config_mod = require('markdownllm.config')
local logger = require('markdownllm.logger')
local util = require('markdownllm.util')

--- Configure MarkdownLLM and register commands + default keymaps.
--- @tparam table|nil opts Configuration overrides merged into defaults.
--- @treturn nil
function M.setup(opts)
    config_mod.update(opts)
    local config = config_mod.config

    logger.configure({
        level = config.log_level,
        log_to_file = config.log_to_file,
        log_file_path = config.log_file_path,
    })

    -- Validate default setup

    local ok, err = pcall(config_mod.get_default_setup)
    if not ok then
        logger.error(err)
        return
    end

    -- Create User Commands

    vim.api.nvim_create_user_command('MarkLLMNewChat', function()
        util.safe_call(core.new_chat_workflow)
    end, { desc = 'New chat' })

    vim.api.nvim_create_user_command('MarkLLMSendChat', function()
        util.safe_call(core.send_current_buffer)
    end, { desc = 'Send chat' })

    vim.api.nvim_create_user_command('MarkLLMRunAction', function()
        util.safe_call(core.action_from_visual)
    end, { range = true, desc = 'Run action' })

    vim.api.nvim_create_user_command('MarkLLMSelectBufferSetup', function()
        util.safe_call(function()
            local buffer = vim.api.nvim_get_current_buf()
            core.select_buffer_setup(buffer)
        end)
    end, { desc = 'Select chat setup' })

    vim.api.nvim_create_user_command('MarkLLMSelectDefaultSetup', function()
        util.safe_call(core.select_default_setup)
    end, { desc = 'Select default setup' })

    vim.api.nvim_create_user_command('MarkLLMSaveChat', function()
        util.safe_call(core.save_current_buffer)
    end, { desc = 'Save chat' })

    vim.api.nvim_create_user_command('MarkLLMResumeChat', function()
        util.safe_call(core.resume_saved_chat)
    end, { desc = 'Resume chat' })

    -- Keymaps

    if config.keymaps and config.keymaps.newChat then
        vim.keymap.set('n', config.keymaps.newChat, ':MarkLLMNewChat<CR>', { desc = 'New chat' })
    end

    if config.keymaps and config.keymaps.sendChat then
        vim.keymap.set('n', config.keymaps.sendChat, ':MarkLLMSendChat<CR>', { desc = 'Send chat' })
    end

    if config.keymaps and config.keymaps.selectChatSetup then
        vim.keymap.set('n', config.keymaps.selectChatSetup, ':MarkLLMSelectBufferSetup<CR>', { desc = 'Select chat setup' })
    end

    if config.keymaps and config.keymaps.selectDefaultSetup then
        vim.keymap.set('n', config.keymaps.selectDefaultSetup, ':MarkLLMSelectDefaultSetup<CR>', { desc = 'Select default setup' })
    end

    if config.keymaps and config.keymaps.actions then
        vim.keymap.set('v', config.keymaps.actions, ":'<,'>MarkLLMRunAction<CR>", { desc = 'Run action' })
    end

    if config.keymaps and config.keymaps.saveChat then
        vim.keymap.set('n', config.keymaps.saveChat, ':MarkLLMSaveChat<CR>', { desc = 'Save chat' })
    end

    if config.keymaps and config.keymaps.resumeChat then
        vim.keymap.set('n', config.keymaps.resumeChat, ':MarkLLMResumeChat<CR>', { desc = 'Resume chat' })
    end
end

return M
