--- Core workflows for MarkdownLLM.
---@module 'markdownllm.core'

local M = {}

local buffer = require('markdownllm.buffer')
local config_mod = require('markdownllm.config')
local fs = require('markdownllm.fs')
local logger = require('markdownllm.logger')
local provider_factory = require('markdownllm.provider_factory')
local ui = require('markdownllm.ui')
local util = require('markdownllm.util')

---@class markdownllm.StreamState
---@field started boolean
---@field finished boolean

---Append text to the end of the buffer.
---@param bufnr integer
---@param text string
---@return nil
local function append_text_at_end(bufnr, text)
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    if line_count == 0 then
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { text })
        return
    end

    local last_line = vim.api.nvim_buf_get_lines(bufnr, line_count - 1, line_count, false)[1] or ''
    local parts = vim.split(text, '\n', { plain = true })

    if #parts == 1 then
        vim.api.nvim_buf_set_lines(bufnr, line_count - 1, line_count, false, { last_line .. parts[1] })
    else
        parts[1] = last_line .. parts[1]
        vim.api.nvim_buf_set_lines(bufnr, line_count - 1, line_count, false, parts)
    end
end

---Ensure the buffer is ready to receive a streamed model response.
---@param bufnr integer
---@return nil
local function prepare_stream_response(bufnr)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local new_block = {}

    if #lines > 0 and lines[#lines]:match('%S') then
        table.insert(new_block, '')
    end

    table.insert(new_block, '## Model')
    table.insert(new_block, '')

    vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, new_block)
end

---Finalize the streamed response by ensuring a model block and adding a new user block.
---@param bufnr integer
---@param started boolean
---@return nil
local function finalize_stream_response(bufnr, started)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end
    if not started then
        prepare_stream_response(bufnr)
    end
    vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { '', '## User', '' })
end

---Build the user message text for an action from a selection.
---@param action table
---@param selection_text string
---@return string
function M.build_action_user_text(action, selection_text)
    local lines = {}
    local pre_text = util.trim(action.pre_text or '')
    if pre_text ~= '' then
        vim.list_extend(lines, vim.split(pre_text, '\n', { plain = true }))
        table.insert(lines, '')
    end

    local kind = action.type or 'text'
    if kind == 'code' then
        local lang = action.language or vim.bo.filetype or ''
        table.insert(lines, '```' .. lang)
        vim.list_extend(lines, vim.split(selection_text, '\n', { plain = true }))
        table.insert(lines, '```')
    else
        vim.list_extend(lines, vim.split(selection_text, '\n', { plain = true }))
    end

    return util.trim(table.concat(lines, '\n'))
end

---Send the current chat buffer to the configured provider.
---@param bufnr integer
---@return nil
function M.send_request(bufnr)
    local setup = vim.b[bufnr].markdownllm_setup

    if not setup then
        logger.error('No active MarkdownLLM setup found.')
        return
    end

    if vim.b[bufnr] and vim.b[bufnr].markdownllm_is_sending then
        logger.warn('A request is already in progress for this buffer.')
        return
    end

    local system_text, messages = buffer.parse_buffer(bufnr)

    if #messages == 0 then
        logger.warn('No messages found in the chat buffer. Add a ## User section with content first.')
        return
    end

    local ok, implementation = pcall(provider_factory.get, setup.provider)
    if not ok then
        logger.error('Failed to get provider implementation: ' .. tostring(implementation))
        return
    end

    buffer.toggle_sending_flag(bufnr)

    logger.info('Sending request to Provider: ' .. setup.provider .. ', Model:' .. setup.model)

    local send_ok, send_err = pcall(function()
        local started = false

        implementation.send(setup, system_text, messages, function(response_text)
            if not vim.api.nvim_buf_is_valid(bufnr) then
                return
            end

            if not started then
                prepare_stream_response(bufnr)
                started = true
            end

            if response_text and response_text ~= '' then
                append_text_at_end(bufnr, response_text)
            end
        end, function()
            finalize_stream_response(bufnr, started)
            buffer.toggle_sending_flag(bufnr)
            logger.info('Response appended to markdownLLM chat.')
        end, function(msg)
            finalize_stream_response(bufnr, started)
            buffer.toggle_sending_flag(bufnr)
            logger.error(msg)
        end)
    end)
    if not send_ok then
        logger.error('MarkdownLLM send failed: ' .. tostring(send_err))
        buffer.toggle_sending_flag(bufnr)
    end
end

---Open a new chat buffer for a preset.
---@param preset table
---@return integer
function M.open_chat(preset)
    vim.cmd('enew')
    local bufnr = vim.api.nvim_get_current_buf()

    vim.bo[bufnr].filetype = 'markdown'
    vim.bo[bufnr].buftype = 'nofile'
    vim.bo[bufnr].bufhidden = 'hide'
    vim.bo[bufnr].swapfile = false

    local setup = config_mod.resolve_preset_setup_name(preset)

    buffer.apply_setup_to_buffer(bufnr, setup)

    vim.api.nvim_buf_set_name(bufnr, buffer.next_chat_name())

    local existing_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local has_content = #existing_lines > 1 or (#existing_lines == 1 and existing_lines[1] ~= '')
    if not has_content then
        local template = buffer.chat_template(preset and preset.instruction)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, template)
        vim.api.nvim_win_set_cursor(0, { #template, 0 })
    end

    return bufnr
end

---Send the current buffer as a chat request.
---@return nil
function M.send_current_buffer()
    local bufnr = vim.api.nvim_get_current_buf()
    M.send_request(bufnr)
end

---Save the current chat buffer to disk.
---@return nil
function M.save_current_buffer()
    local bufnr = vim.api.nvim_get_current_buf()
    local save_dir, err = fs.ensure_chat_save_dir(config_mod.config.chat_save_dir)
    if not save_dir then
        logger.error(err)
        return
    end

    local input_name = vim.fn.input('Chat name: ')
    local filename = fs.sanitize_chat_filename(input_name)
    if not filename then
        logger.info('Chat save cancelled.')
        return
    end

    local path = save_dir .. '/' .. filename
    if vim.loop.fs_stat(path) then
        logger.error('Chat file already exists: ' .. path)
        return
    end

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local ok, write_err = pcall(vim.fn.writefile, lines, path)
    if not ok then
        logger.error('Failed to save chat: ' .. tostring(write_err))
        return
    end
    logger.info('Chat saved to ' .. path)
end

---Resume a saved MarkdownLLM chat file and apply the default setup.
---@return nil
function M.resume_saved_chat()
    local save_dir, err = fs.ensure_chat_save_dir(config_mod.config.chat_save_dir)
    if not save_dir then
        logger.error(err)
        return
    end

    local files, list_err = fs.list_saved_chats(save_dir)
    if not files then
        logger.error(list_err)
        return
    end

    if #files == 0 then
        logger.info('No saved chats found in ' .. save_dir)
        return
    end

    local items = {}
    for _, path in ipairs(files) do
        table.insert(items, { path = path, label = vim.fn.fnamemodify(path, ':t') })
    end

    vim.ui.select(items, {
        prompt = 'Select MarkdownLLM chat to resume',
        format_item = function(item)
            return item.label
        end,
    }, function(choice)
        util.safe_call(function()
            if not choice then
                return
            end

            local setup = config_mod.get_default_setup()

            vim.cmd('edit ' .. vim.fn.fnameescape(choice.path))
            local bufnr = vim.api.nvim_get_current_buf()
            vim.bo[bufnr].filetype = 'markdown'
            buffer.apply_setup_to_buffer(bufnr, setup)
            logger.info('Resumed MarkdownLLM chat: ' .. choice.label)
        end)
    end)
end

---Create a chat from the visual selection and send it.
---@return nil
function M.action_from_visual()
    local selection_text = util.get_visual_selection_text()
    logger.trace('Visual selection text: ' .. tostring(selection_text))
    if not selection_text or util.trim(selection_text) == '' then
        logger.warn('No visual selection found.')
        return
    end

    ui.select_action(function(action)
        if not action then
            return
        end

        local preset = config_mod.find_preset(action.preset) or
            (config_mod.config.presets and config_mod.config.presets[1])
            or nil
        if not preset then
            logger.error('No presets configured. Add at least one preset first.')
            return
        end

        if action.preset and not config_mod.find_preset(action.preset) then
            logger.error('Preset "' .. tostring(action.preset) .. '" not found.')
            return
        end

        local user_text = M.build_action_user_text(action, selection_text)
        local bufnr = M.open_chat(preset)
        buffer.replace_last_user_block(bufnr, user_text)

        M.send_request(bufnr)
    end)
end

---Select and apply a MarkdownLLM setup for the current buffer.
---@param bufnr integer|nil
---@return nil
function M.select_buffer_setup(bufnr)
    if not bufnr then
        return
    end
    ui.select_setup(function(setup)
        buffer.apply_setup_to_buffer(bufnr, setup)
        logger.info(
            string.format('MarkdownLLM buffer using setup "%s" (%s / %s)', setup.name, setup.provider, setup.model)
        )
    end)
end

---Select and apply the default setup name.
---@return nil
function M.select_default_setup()
    ui.select_setup(function(setup)
        config_mod.config.default_setup_name = setup.name
        logger.info(string.format('Default setup set to "%s"', setup.name))
    end)
end

---Prompt for a preset and open a new chat.
---@return nil
function M.new_chat_workflow()
    ui.select_preset(function(preset)
        if not preset then
            return
        end
        M.open_chat(preset)
    end)
end

return M
