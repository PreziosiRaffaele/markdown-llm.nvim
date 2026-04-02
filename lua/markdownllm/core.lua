--- Core workflows for MarkdownLLM.
---@module 'markdownllm.core'

local M = {}

local buffer = require('markdownllm.buffer')
local config_mod = require('markdownllm.config')
local fs = require('markdownllm.fs')
local llm = require('markdownllm.llm')
local logger = require('markdownllm.logger')
local ui = require('markdownllm.ui')
local util = require('markdownllm.util')
local ns_action = vim.api.nvim_create_namespace('markdownllm_action')

-- ============================================================================
-- Local helpers
-- ============================================================================

---Append text to the end of the buffer.
---@param bufnr integer
---@param text string
---@return nil
local function append_text_at_end(bufnr, text)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end

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

---Finalize the streamed response by clearing the loading placeholder and adding a new user block.
---@param bufnr integer
---@return nil
local function finalize_stream_response(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end

    vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { '', '## User', '' })
end

---Map legacy action config to the current action type for compatibility.
---@param action_type string
---@return string normalized_action_type normalized action type
local function normalize_action_type(action_type)
    action_type = action_type or 'chat'

    if action_type == 'text' then
        action_type = 'chat'
    elseif action_type == 'code' then
        action_type = 'chat'
    elseif action_type == 'replace_visual' then
        action_type = 'replace'
    end

    if action_type ~= 'chat' and action_type ~= 'replace' and action_type ~= 'modal' then
        action_type = 'chat'
    end

    return action_type
end

---Render the selected text exactly as it will be embedded in the final user prompt.
---@param action table
---@param selection_text string
---@param filetype string|nil
---@return string rendered_selection markdown fragment appended below `pre_text`
local function render_action_selection(action, selection_text, filetype)
    local selection_lines = vim.split(selection_text or '', '\n', { plain = true })

    if action.type == 'chat' then
        local fence_language = (action and action.language) or filetype or vim.bo.filetype or ''
        local lines = { '```' .. fence_language }
        vim.list_extend(lines, selection_lines)
        table.insert(lines, '```')
        return table.concat(lines, '\n')
    else
        return table.concat(selection_lines, '\n')
    end
end

---Build the full user prompt text for an action by combining `pre_text` and the rendered selection payload.
---@param action table
---@param selection_text string
---@param filetype string|nil
---@return string user_text markdown user message sent to the provider
local function build_action_user_text(action, selection_text, filetype)
    local lines = {}
    local pre_text = util.trim(action.pre_text or '')
    if pre_text ~= '' then
        vim.list_extend(lines, vim.split(pre_text, '\n', { plain = true }))
        table.insert(lines, '')
    end

    local rendered_selection = render_action_selection(action, selection_text, filetype)
    if rendered_selection ~= '' then
        vim.list_extend(lines, vim.split(rendered_selection, '\n', { plain = true }))
    end

    return util.trim(table.concat(lines, '\n'))
end

---Cleanup the request state.
---@param bufnr integer
---@param loading_mark integer|nil
---@return nil
local function cleanup_request_state(bufnr, loading_mark)
    finalize_stream_response(bufnr)
    buffer.clear_loading_virtual_text(bufnr, loading_mark)
    buffer.toggle_sending_flag(bufnr)
end

---Extract provider options from a flattened setup table.
---@param setup table|nil
---@return table|nil
local function extract_options_from_setup(setup)
    if type(setup) ~= 'table' then
        return nil
    end

    local options = {}

    local function add_option(key, value)
        if value ~= nil then
            options[key] = value
        end
    end

    add_option('temperature', setup.temperature)
    add_option('max_tokens', setup.max_tokens)
    add_option('top_p', setup.top_p)
    add_option('stop', setup.stop)
    add_option('frequency_penalty', setup.frequency_penalty)
    add_option('presence_penalty', setup.presence_penalty)
    add_option('seed', setup.seed)
    add_option('reasoning_effort', setup.reasoning_effort)
    add_option('web_search', setup.web_search)

    if next(options) == nil then
        return nil
    end

    return options
end

---Build a provider-neutral request from setup and buffer messages.
---@param setup table
---@param system_text string
---@param messages table[]
---@return markdownllm.LLMRequest
local function build_request(setup, system_text, messages)
    local request_messages = {}

    if system_text and system_text ~= '' then
        table.insert(request_messages, { role = 'system', content = system_text })
    end

    for _, message in ipairs(messages or {}) do
        local role = message.role == 'model' and 'assistant' or message.role
        table.insert(request_messages, { role = role, content = message.text })
    end

    return {
        context = {
            provider = setup.provider,
            model = setup.model,
            stream = true,
            timeout = setup.timeout,
            api_key_name = setup.api_key_name,
            base_url = setup.base_url,
        },
        messages = request_messages,
        options = extract_options_from_setup(setup),
    }
end

---Build the system instruction to use for a non-chat action.
---@param action_type string
---@return string
local function build_action_instruction(action_type)
    if action_type == 'replace' then
        return table.concat({
            'Return only the replacement text for the selected content.',
            'Do not add explanations, comments, code fences, or surrounding prose.',
            'The response will directly replace the selected text in the editor.',
        }, ' ')
    end

    return ''
end

---Return the preset that should execute the action.
---@param action table
---@return table|nil preset configured or synthesized preset used to execute the action
---@return string|nil err human-readable resolution error when the action cannot be executed
local function resolve_action_preset(action)
    local preset = nil

    if action.preset and action.preset ~= '' then
        preset = config_mod.find_preset(action.preset)
        if not preset then
            return nil, 'Preset "' .. tostring(action.preset) .. '" not found.'
        end
    end

    if preset then
        return preset, nil
    end

    local ok, default_setup_or_err = pcall(config_mod.get_default_setup)
    if not ok then
        return nil, tostring(default_setup_or_err)
    end

    return {
        name = 'Default (' .. tostring(default_setup_or_err.provider) .. ')',
        setup = default_setup_or_err.name,
        instruction = build_action_instruction(action.type)
    }, nil
end


---Capture the current visual selection and the buffer metadata needed to execute an action later.
---@return table|nil execution table containing `bufnr`, current `filetype`, selected text, and selected range
local function get_visual_selection_context()
    local selection_text, selection_range = util.get_visual_selection_text()
    logger.trace('Visual selection text: ' .. tostring(selection_text))
    if not selection_text or util.trim(selection_text) == '' then
        logger.warn('No visual selection found.')
        return nil
    end

    local bufnr = vim.api.nvim_get_current_buf()
    return {
        bufnr = bufnr,
        filetype = vim.bo[bufnr].filetype,
        selection_text = selection_text,
        selection_range = selection_range,
    }
end

---Create a range extmark for the selection.
---@param bufnr integer
---@param range table
---@return integer mark_id
local function set_action_range_mark(bufnr, range)
    return vim.api.nvim_buf_set_extmark(bufnr, ns_action, range.start_row, range.start_col, {
        end_row = range.end_row,
        end_col = range.end_col,
    })
end

---Get a range table from an extmark.
---@param bufnr integer
---@param mark_id integer
---@return table|nil range
local function get_action_range(bufnr, mark_id)
    local mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns_action, mark_id, { details = true })
    if not mark or #mark == 0 then
        return nil
    end
    local details = mark[3] or {}
    if details.end_row == nil or details.end_col == nil then
        return nil
    end
    return {
        start_row = mark[1],
        start_col = mark[2],
        end_row = details.end_row,
        end_col = details.end_col,
    }
end

---Clear an action extmark.
---@param bufnr integer
---@param mark_id integer|nil
---@return nil
local function clear_action_mark(bufnr, mark_id)
    if mark_id and vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_del_extmark(bufnr, ns_action, mark_id)
    end
end

---Open a new chat buffer for a preset.
---@param preset table
---@return integer
local function open_chat(preset)
    vim.cmd('enew')
    local bufnr = vim.api.nvim_get_current_buf()

    vim.bo[bufnr].filetype = 'markdown'
    vim.bo[bufnr].buftype = 'nofile'
    vim.bo[bufnr].bufhidden = 'hide'
    vim.bo[bufnr].swapfile = false

    local setup = config_mod.resolve_preset_setup(preset)
    local buffer_setup = vim.deepcopy(setup)
    buffer_setup.name = nil
    buffer_setup.opts = nil

    vim.api.nvim_buf_set_name(bufnr, buffer.next_chat_name())

    local existing_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local has_content = #existing_lines > 1 or (#existing_lines == 1 and existing_lines[1] ~= '')
    if not has_content then
        local template = buffer.chat_template(preset and preset.instruction, buffer_setup)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, template)
        vim.api.nvim_win_set_cursor(0, { #template, 0 })
    else
        local _, update_err = buffer.update_setup_in_buffer(bufnr, buffer_setup)
        if update_err then
            logger.warn('Failed to update YAML frontmatter: ' .. update_err)
        end
    end

    return bufnr
end

---Send the current chat buffer to the configured provider.
---@param bufnr integer
---@return nil
local function send_request(bufnr)
    if vim.b[bufnr] and vim.b[bufnr].markdownllm_is_sending then
        logger.warn('A request is already in progress for this buffer.')
        return
    end

    local setup, system_text, messages = buffer.parse_buffer(bufnr)
    local frontmatter_setup, frontmatter_err = buffer.parse_setup_from_buffer(bufnr)

    if not setup then
        local default_setup = config_mod.get_default_setup()
        setup = vim.deepcopy(default_setup)
        setup.name = nil
        setup.opts = nil

        if not frontmatter_setup and not frontmatter_err then
            local _, update_err = buffer.update_setup_in_buffer(bufnr, setup)
            if update_err then
                logger.warn('Failed to seed YAML frontmatter: ' .. update_err)
            end
        end
    end

    if #messages == 0 then
        logger.warn('No messages found in the chat buffer. Add a ## User section with content first.')
        return
    end

    buffer.toggle_sending_flag(bufnr)
    local loading_line = buffer.append_loading_model_block(bufnr)
    local loading_mark = buffer.set_loading_virtual_text(bufnr, loading_line, 'Thinking...')

    logger.info('Sending request to Provider: ' .. setup.provider .. ', Model:' .. setup.model)

    local send_ok, send_err = pcall(function()
        local started = false
        local request = build_request(setup, system_text, messages)

        llm.send(request, {
            on_chunk = function(response_text)
                if not vim.api.nvim_buf_is_valid(bufnr) then
                    return
                end

                if response_text and response_text ~= '' then
                    if not started then
                        buffer.clear_loading_virtual_text(bufnr, loading_mark)
                        started = true
                    end
                    append_text_at_end(bufnr, response_text)
                end
            end,
            on_complete = function()
                cleanup_request_state(bufnr, loading_mark)
                logger.info('Response appended to markdownLLM chat.')
            end,
            on_error = function(msg)
                append_text_at_end(bufnr, msg)
                cleanup_request_state(bufnr, loading_mark)
                logger.error(msg)
            end,
            on_warning = function(msg)
                logger.warn(msg)
            end,
        })
    end)
    if not send_ok then
        append_text_at_end(bufnr, tostring(send_err))
        cleanup_request_state(bufnr, loading_mark)
        logger.error('MarkdownLLM send failed: ' .. tostring(send_err))
    end
end

---Send a replace action request and write the completed response back into the selected range.
---@param action table
---@param execution table
---@param setup table
---@param system_text string
---@return nil
local function run_replace_action(action, execution, setup, system_text)
    local bufnr = execution.bufnr
    local filetype = execution.filetype
    local selection_text = execution.selection_text
    local selection_range = execution.selection_range

    if not selection_range then
        logger.warn('No visual selection range found.')
        return
    end

    local mark_id = set_action_range_mark(bufnr, selection_range)
    local user_text = build_action_user_text(action, selection_text, filetype)
    local request = build_request(setup, system_text, {
        { role = 'user', text = user_text },
    })
    request.context.stream = false

    local response_text = ''
    local send_ok, send_err = pcall(function()
        llm.send(request, {
            on_chunk = function(chunk)
                if chunk and chunk ~= '' then
                    response_text = chunk
                end
            end,
            on_complete = function()
                if not vim.api.nvim_buf_is_valid(bufnr) then
                    return
                end

                local range = get_action_range(bufnr, mark_id)
                clear_action_mark(bufnr, mark_id)
                if not range then
                    return
                end

                local replacement = vim.split(response_text, '\n', { plain = true })
                vim.api.nvim_buf_set_text(
                    bufnr,
                    range.start_row,
                    range.start_col,
                    range.end_row,
                    range.end_col,
                    replacement
                )
                local preview = util.truncate_text(response_text:gsub('\n', '\\n'), 80)
                logger.info('Replaced with:', preview)
            end,
            on_error = function(msg)
                clear_action_mark(bufnr, mark_id)
                logger.error(msg)
            end,
            on_warning = function(msg)
                logger.warn(msg)
            end,
        })
    end)

    if not send_ok then
        clear_action_mark(bufnr, mark_id)
        logger.error('MarkdownLLM send failed: ' .. tostring(send_err))
    end
end

---Send a modal action request and stream the response into a temporary floating preview window.
---@param action table
---@param visual_selection_context table
---@param setup table
---@param system_text string
---@return nil
local function run_modal_action(action, visual_selection_context, setup, system_text)
    local user_text = build_action_user_text(action, visual_selection_context.selection_text, visual_selection_context.filetype)
    local modal_bufnr, modal_winid = ui.open_modal_preview()

    local function is_modal_valid()
        return vim.api.nvim_buf_is_valid(modal_bufnr) and vim.api.nvim_win_is_valid(modal_winid)
    end

    local function set_modal_lines(lines)
        if not vim.api.nvim_buf_is_valid(modal_bufnr) then return end
        vim.bo[modal_bufnr].modifiable = true
        vim.api.nvim_buf_set_lines(modal_bufnr, 0, -1, false, lines)
        vim.bo[modal_bufnr].modifiable = false
    end

    set_modal_lines({ '# MarkdownLLM Preview', '', '_Thinking..._' })

    local request = build_request(setup, system_text, {
        { role = 'user', text = user_text },
    })
    local started = false

    local function append_modal_text(text)
        if not is_modal_valid() then return end

        vim.bo[modal_bufnr].modifiable = true
        if not started then
            started = true
            vim.api.nvim_buf_set_lines(modal_bufnr, 0, -1, false, { '# MarkdownLLM Preview', '' })
        end
        append_text_at_end(modal_bufnr, text)
        vim.bo[modal_bufnr].modifiable = false
    end

    local send_ok, send_err = pcall(llm.send, request, {
        on_chunk = function(chunk)
            if chunk and chunk ~= '' then
                append_modal_text(chunk)
            end
        end,
        on_complete = function()
            if not is_modal_valid() then return end
            if not started then
                set_modal_lines({ '# MarkdownLLM Preview', '', '_No content returned._' })
            end
            logger.info('Preview ready.')
        end,
        on_error = function(msg)
            logger.error(msg)
            set_modal_lines({ '# MarkdownLLM Preview', '', msg })
        end,
        on_warning = function(msg)
            logger.warn(msg)
        end,
    })

    if not send_ok then
        local err_msg = tostring(send_err)
        logger.error('MarkdownLLM send failed: ' .. err_msg)
        set_modal_lines({ '# MarkdownLLM Preview', '', err_msg })
    end
end

---Send a chat action request by seeding a new chat buffer and dispatching it through the regular chat workflow.
---@param preset table|nil
---@param action table
---@param execution table
---@return nil
local function run_chat_action(preset, action, execution)
    local user_text = build_action_user_text(action, execution.selection_text, execution.filetype)
    local chat_bufnr = open_chat(preset)
    buffer.replace_last_user_block(chat_bufnr, user_text)
    send_request(chat_bufnr)
end

---Run a configured action using the current visual selection.
---@param action table
---@return nil
local function run_action(action)
    if not action then return end

    local visual_selection_context = get_visual_selection_context()
    if not visual_selection_context then return end

    -- Ensure backward compatibility
    action.type = normalize_action_type(action.type)

    local preset, err = resolve_action_preset(action)
    if err then
        logger.error(err)
        return
    end

    local ok, setup = pcall(config_mod.resolve_preset_setup, preset)
    if not ok then
        logger.error(tostring(setup))
        return
    end

    if action.type == 'replace' then
        run_replace_action(action, visual_selection_context, setup, preset.instruction)
    elseif action.type == 'modal' then
        run_modal_action(action, visual_selection_context, setup, preset.instruction)
    else
        run_chat_action(preset, action, visual_selection_context)
    end
end

---Prompt for a custom action and run it against the current visual selection.
---@return nil
local function prompted_action_from_visual()
    ui.prompt_action_text(function(input)
        local prompt_text = util.trim(input or '')
        if prompt_text == '' then
            logger.info('Custom action cancelled.')
            return
        end

        ui.select_action_kind(function(action_kind)
            if not action_kind then
                return
            end

            local action = {
                name = 'Custom prompt',
                pre_text = prompt_text,
                type = action_kind.type,
            }

            run_action(action)
        end)
    end)
end

-- ============================================================================
-- Public API
-- ============================================================================

---Prompt for a preset and open a new chat.
---@return nil
function M.new_chat_workflow()
    ui.select_preset(function(preset)
        if not preset then
            return
        end
        open_chat(preset)
    end)
end

---Send the current buffer as a chat request.
---@return nil
function M.send_current_buffer()
    local bufnr = vim.api.nvim_get_current_buf()
    send_request(bufnr)
end

---Create a chat from the visual selection and send it.
---@param action_name string|nil
---@return nil
function M.action_from_visual(action_name)
    if action_name and action_name ~= '' then
        local ok, action = pcall(config_mod.find_action, action_name)
        if not ok then
            logger.error(action)
            return
        end
        run_action(action)
        return
    end

    ui.select_action(function(action)
        if not action then
            return
        end
        if action.markdownllm_kind == 'custom_prompt' then
            prompted_action_from_visual()
            return
        end
        run_action(action)
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
        local buffer_setup = vim.deepcopy(setup)
        buffer_setup.name = nil
        buffer_setup.opts = nil
        local _, update_err = buffer.update_setup_in_buffer(bufnr, buffer_setup)
        if update_err then
            logger.warn('Failed to update YAML frontmatter: ' .. update_err)
        end
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

---Save the current chat buffer to disk.
---@return nil
function M.save_current_buffer()
    local bufnr = vim.api.nvim_get_current_buf()
    local save_dir, err = fs.ensure_chat_save_dir(config_mod.config.chat_save_dir)
    if not save_dir then
        logger.error(err)
        return
    end

    local input_name = vim.fn.input('Chat name > ')
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
        prompt = 'Select MarkdownLLM chat to resume > ',
        format_item = function(item)
            return item.label
        end,
    }, function(choice)
        util.safe_call(function()
            if not choice then
                return
            end

            vim.cmd('edit ' .. vim.fn.fnameescape(choice.path))
            local bufnr = vim.api.nvim_get_current_buf()
            vim.bo[bufnr].filetype = 'markdown'
            local setup, setup_err = buffer.parse_setup_from_buffer(bufnr)
            if setup_err then
                logger.warn('Invalid YAML frontmatter: ' .. setup_err)
            end
            if not setup then
                local default_setup = config_mod.get_default_setup()
                local buffer_setup = vim.deepcopy(default_setup)
                buffer_setup.name = nil
                buffer_setup.opts = nil
                local _, update_err = buffer.update_setup_in_buffer(bufnr, buffer_setup)
                if update_err then
                    logger.warn('Failed to seed YAML frontmatter: ' .. update_err)
                end
            end
            logger.info('Resumed MarkdownLLM chat: ' .. choice.label)
        end)
    end)
end

return M
