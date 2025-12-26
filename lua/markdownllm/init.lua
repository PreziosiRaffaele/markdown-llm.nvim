--- MarkdownLLM: markdown-driven chat buffer
---@module 'markdownllm'

local M = {}

local logModule = require('rpreziosi.core.logger')
local provider_factory = require('markdownllm.provider_factory')

local default_config = {
    log_level = vim.log.levels.INFO,
    setups = {},
    presets = {},
    actions = {},
    keymaps = {},
    chat_save_dir = vim.fn.stdpath('data') .. '/markdownllm/chats',
}

local config = vim.deepcopy(default_config)

-- Ensure the logger has a stable name even if MarkdownLLM is used before M.setup().
local logger = logModule.new()

local markdown_rule =
'All output must be in plain Markdown (no HTML) so it renders correctly in a Neovim markdown buffer.'

local function trim(text)
    return (text:gsub('^%s+', ''):gsub('%s+$', ''))
end

local function chat_template(instruction_text)
    local template = {
        '# System',
    }

    if instruction_text and instruction_text ~= '' then
        local lines = vim.split(instruction_text, '\n', { plain = true })
        vim.list_extend(template, lines)
    end

    table.insert(template, '- ' .. markdown_rule)
    table.insert(template, '')
    table.insert(template, '# Conversation')
    table.insert(template, '## User')
    table.insert(template, '')

    return template
end

local function parse_buffer(bufnr)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local system_lines = {}
    local messages = {}
    local mode = 'system'
    local current_role = nil
    local accumulator = {}

    local function flush()
        if current_role and #accumulator > 0 then
            local text = trim(table.concat(accumulator, '\n'))
            if text ~= '' then
                table.insert(messages, { role = current_role, text = text })
            end
        end
        accumulator = {}
    end

    for _, line in ipairs(lines) do
        if line:match('^#%s+System') then
            flush()
            mode = 'system'
            current_role = nil
        elseif line:match('^#%s+Conversation') then
            flush()
            mode = 'conversation'
            current_role = nil
        elseif line:match('^##%s+User') then
            flush()
            mode = 'conversation'
            current_role = 'user'
        elseif line:match('^##%s+Model') or line:match('^##%s+Assistant') then
            flush()
            mode = 'conversation'
            current_role = 'model'
        else
            if mode == 'system' then
                table.insert(system_lines, line)
            elseif mode == 'conversation' and current_role then
                table.insert(accumulator, line)
            end
        end
    end

    flush()

    local system_text = trim(table.concat(system_lines, '\n'))
    return system_text, messages
end

local function buffer_name_exists(name)
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) or vim.fn.buflisted(buf) == 1 then
            local bufname = vim.api.nvim_buf_get_name(buf)
            -- Check if buffer name ends with the target name (handles full paths)
            if bufname:match(vim.pesc(name) .. '$') then
                return true
            end
        end
    end
    return false
end

local function next_chat_name()
    local base = 'markdownLLM.md'
    if not buffer_name_exists(base) then
        return base
    end

    local idx = 1
    while true do
        local candidate = string.format('markdownLLM-%d.md', idx)
        if not buffer_name_exists(candidate) then
            return candidate
        end
        idx = idx + 1
    end
end

local function ensure_chat_save_dir(path)
    if not path or path == '' then
        return nil, 'Chat save directory is not configured.'
    end
    local ok, err = pcall(vim.fn.mkdir, path, 'p')
    if not ok then
        return nil, err
    end
    return path, nil
end

local function sanitize_chat_filename(name)
    local trimmed = trim(name or '')
    if trimmed == '' then
        return nil
    end
    local base = vim.fn.fnamemodify(trimmed, ':t')
    if not base:match('%.md$') then
        base = base .. '.md'
    end
    return base
end

---@param path string
---@return string[]|nil
---@return string|nil
local function list_saved_chats(path)
    if not path or path == '' then
        return nil, 'Chat save directory is not configured.'
    end

    local files = vim.fn.globpath(path, '*.md', false, true)
    if type(files) ~= 'table' then
        return nil, 'Failed to list saved chats in ' .. path
    end

    table.sort(files)
    return files, nil
end

local function find_setup(name)
    for _, setup in ipairs(config.setups or {}) do
        if setup.name == name then
            return setup
        end
    end
    return nil, 'Setup "' .. name .. '" not found in the configured setups.'
end

local function setup_names()
    local names = {}
    for _, setup in ipairs(config.setups or {}) do
        table.insert(names, setup.name)
    end
    return names
end

local function get_default_setup()
    if not config.default_setup_name then
        return nil, 'No default setup configured.'
    end

    local setup, err = find_setup(config.default_setup_name)

    return setup, err
end

---@param bufnr integer
---@param setup table
local function apply_setup_to_buffer(bufnr, setup)
    -- Deep copy the setup config so we can modify it without affecting the original
    local buffer_setup = vim.deepcopy(setup)
    -- Remove the name from the setup config, it's not needed in the buffer
    buffer_setup.name = nil
    vim.b[bufnr].markdownllm_setup = buffer_setup
end

---@param preset table
---@return table|nil
local function resolve_preset_setup_name(preset)
    local setup_name = preset and preset.setup and preset.setup ~= '' and preset.setup or config.default_setup_name
    return find_setup(setup_name)
end

local function select_preset(on_select)
    local presets = config.presets or {}
    if not presets or #presets == 0 then
        on_select(nil)
        return
    end

    vim.ui.select(presets, {
        prompt = 'Select prompt preset',
        format_item = function(item)
            local label = item.name or '(unnamed preset)'
            local setup = resolve_preset_setup_name(item)
            if setup then
                label = string.format('%s  [setup: %s]', label, setup.name)
            end
            return label
        end,
    }, function(choice)
        on_select(choice)
    end)
end

local function find_preset(name)
    if not name or name == '' then
        return nil
    end
    for _, preset in ipairs(config.presets or {}) do
        if preset.name == name then
            return preset
        end
    end
    return nil
end

local function get_visual_selection_text()
    local start_pos = vim.api.nvim_buf_get_mark(0, '<')
    local end_pos = vim.api.nvim_buf_get_mark(0, '>')
    if not start_pos or not end_pos then
        return ''
    end

    local start_row, start_col = start_pos[1] - 1, start_pos[2]
    local end_row, end_col = end_pos[1] - 1, end_pos[2]
    if end_row < start_row or (end_row == start_row and end_col < start_col) then
        start_row, end_row = end_row, start_row
        start_col, end_col = end_col, start_col
    end

    local mode = vim.fn.visualmode()
    if mode == 'V' then
        local lines = vim.api.nvim_buf_get_lines(0, start_row, end_row + 1, false)
        return table.concat(lines, '\n')
    end

    local text = vim.api.nvim_buf_get_text(0, start_row, start_col, end_row, end_col + 1, {})
    return table.concat(text, '\n')
end

local function build_action_user_text(action, selection_text)
    local lines = {}
    local pre_text = trim(action.pre_text or '')
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

    return trim(table.concat(lines, '\n'))
end

local function replace_last_user_block(bufnr, user_text)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local user_idx = nil
    for i = #lines, 1, -1 do
        if lines[i] == '## User' then
            user_idx = i
            break
        end
    end

    if not user_idx then
        return false
    end

    local new_lines = vim.split(user_text or '', '\n', { plain = true })
    table.insert(new_lines, '')
    vim.api.nvim_buf_set_lines(bufnr, user_idx, -1, false, new_lines)
    return true
end

local function select_action(on_select)
    local actions = config.actions or {}
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

local function append_response(bufnr, response_text)
    local winid = vim.fn.bufwinid(bufnr)
    local cursor = nil
    if winid ~= -1 then
        cursor = vim.api.nvim_win_get_cursor(winid)
    end

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local new_block = {}

    if #lines > 0 and lines[#lines]:match('%S') then
        table.insert(new_block, '')
    end

    table.insert(new_block, '## Model')
    local response_lines = vim.split(response_text, '\n', { plain = true })
    vim.list_extend(new_block, response_lines)
    table.insert(new_block, '')
    table.insert(new_block, '## User')
    table.insert(new_block, '')

    vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, new_block)
    if winid ~= -1 and cursor then
        vim.api.nvim_win_set_cursor(winid, cursor)
    end
end

local function send_request(bufnr)
    local setup = vim.b[bufnr].markdownllm_setup

    if not setup then
        logger.error('No active MarkdownLLM setup found.')
        return
    end

    if vim.b[bufnr] and vim.b[bufnr].markdownllm_is_sending then
        logger.warn('A request is already in progress for this buffer.')
        return
    end

    local system_text, messages = parse_buffer(bufnr)

    if #messages == 0 then
        logger.warn('No messages found in the chat buffer. Add a ## User section with content first.')
        return
    end

    local ok, implementation = pcall(provider_factory.get, setup.provider)
    if not ok then
        logger.error('Failed to get provider implementation: ' .. tostring(implementation))
        return
    end

    vim.b[bufnr].markdownllm_is_sending = true
    logger.info('Sending request to Provider: ' .. setup.provider .. ', Model:' .. setup.model)

    local send_ok, send_err = pcall(function()
        implementation.send(setup, system_text, messages, logger, function(response_text)
            -- Ensure buffer still exists and is valid before appending
            if vim.api.nvim_buf_is_valid(bufnr) then
                append_response(bufnr, response_text)
                logger.debug('model text (' .. setup.provider .. ' ' .. setup.model .. '): ' .. response_text)
                logger.info('Response appended to markdownLLM chat.')
            end
            if vim.api.nvim_buf_is_valid(bufnr) then
                vim.b[bufnr].markdownllm_is_sending = false
            end
        end, function(msg)
            logger.error(msg)
            if vim.api.nvim_buf_is_valid(bufnr) then
                vim.b[bufnr].markdownllm_is_sending = false
            end
        end)
    end)
    if not send_ok then
        logger.error('MarkdownLLM send failed: ' .. tostring(send_err))
        if vim.api.nvim_buf_is_valid(bufnr) then
            vim.b[bufnr].markdownllm_is_sending = false
        end
    end
end

local function open_chat(preset)
    vim.cmd('enew')
    local bufnr = vim.api.nvim_get_current_buf()

    vim.bo[bufnr].filetype = 'markdown'
    vim.bo[bufnr].buftype = 'nofile'
    vim.bo[bufnr].bufhidden = 'hide'
    vim.bo[bufnr].swapfile = false

    local setup_name, err = resolve_preset_setup_name(preset)

    if not setup_name then
        logger.error(err)
        return
    end

    apply_setup_to_buffer(bufnr, setup_name)

    vim.api.nvim_buf_set_name(bufnr, next_chat_name())

    local existing_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local has_content = #existing_lines > 1 or (#existing_lines == 1 and existing_lines[1] ~= '')
    if not has_content then
        local template = chat_template(preset and preset.instruction)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, template)
        vim.api.nvim_win_set_cursor(0, { #template, 0 })
    end

    return bufnr
end

local function send_current_buffer()
    local bufnr = vim.api.nvim_get_current_buf()
    send_request(bufnr)
end

local function save_current_buffer()
    local bufnr = vim.api.nvim_get_current_buf()
    local save_dir, err = ensure_chat_save_dir(config.chat_save_dir)
    if not save_dir then
        logger.error(err)
        return
    end

    local input_name = vim.fn.input('Chat name: ')
    local filename = sanitize_chat_filename(input_name)
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

--- Resume a saved MarkdownLLM chat file and apply the default setup.
--- @return nil
local function resume_saved_chat()
    local save_dir, err = ensure_chat_save_dir(config.chat_save_dir)
    if not save_dir then
        logger.error(err)
        return
    end

    local files, list_err = list_saved_chats(save_dir)
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
        if not choice then
            return
        end

        local setup, setup_err = get_default_setup()
        if not setup then
            logger.error(setup_err)
            return
        end

        vim.cmd('edit ' .. vim.fn.fnameescape(choice.path))
        local bufnr = vim.api.nvim_get_current_buf()
        vim.bo[bufnr].filetype = 'markdown'
        apply_setup_to_buffer(bufnr, setup)
        logger.info('Resumed MarkdownLLM chat: ' .. choice.label)
    end)
end

local function action_from_visual()
    local selection_text = get_visual_selection_text()
    logger.trace('Visual selection text: ' .. tostring(selection_text))
    if not selection_text or trim(selection_text) == '' then
        logger.warn('No visual selection found.')
        return
    end

    select_action(function(action)
        if not action then
            return
        end

        local preset = find_preset(action.preset) or (config.presets and config.presets[1]) or nil
        if not preset then
            logger.error('No presets configured. Add at least one preset first.')
            return
        end

        if action.preset and not find_preset(action.preset) then
            logger.error('Preset "' .. tostring(action.preset) .. '" not found.')
            return
        end

        local user_text = build_action_user_text(action, selection_text)
        local bufnr = open_chat(preset)
        replace_last_user_block(bufnr, user_text)

        send_request(bufnr)
    end)
end


local function select_setup(on_select)
    local names = setup_names()
    if #names == 0 then
        logger.error('No setups configured.')
        return
    end

    vim.ui.select(names, { prompt = 'Select MarkdownLLM setup' }, function(choice)
        if choice then
            local setup, err = find_setup(choice)
            if not setup then
                logger.error(err)
                return
            end
            on_select(setup)
        end
    end)
end

--- Select and apply a MarkdownLLM setup for the current buffer.
--- @param bufnr integer|nil
--- @return nil
local function select_buffer_setup(bufnr)
    if not bufnr then
        return
    end
    select_setup(function(setup)
        apply_setup_to_buffer(bufnr, setup)
        logger.info(
            string.format('MarkdownLLM buffer using setup "%s" (%s / %s)', setup.name, setup.provider, setup.model)
        )
    end)
end

local function select_default_setup()
    select_setup(function(setup)
        config.default_setup_name = setup.name
        logger.info(string.format('Default setup set to "%s"', setup.name))
    end)
end

---@param setup table
---@return string[]
local function format_setup_for_edit(setup)
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
local function parse_setup_from_lines(lines)
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
local function open_setup_editor(target_bufnr)
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

    vim.api.nvim_buf_set_lines(editor_bufnr, 0, -1, false, format_setup_for_edit(setup))

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
            local updated, err = parse_setup_from_lines(lines)
            if not updated then
                logger.error('Failed to parse setup: ' .. tostring(err))
                return
            end
            if not vim.api.nvim_buf_is_valid(target_bufnr) then
                logger.error('MarkdownLLM buffer no longer exists.')
                return
            end
            apply_setup_to_buffer(target_bufnr, updated)
            vim.bo[editor_bufnr].modified = false
            logger.info('MarkdownLLM setup updated for the buffer.')
        end,
    })
end

--- Configure MarkdownLLM and register commands + default keymaps.
--- @tparam table|nil opts Configuration overrides merged into defaults.
--- @treturn nil
function M.setup(opts)
    config = vim.tbl_deep_extend('force', vim.deepcopy(default_config), opts or {})

    -- Ensure the default setup is configured

    local default_setup, err = get_default_setup()
    if not default_setup then
        logger.error(err)
        return
    end

    -- Set log Level

    logger = logModule.new({name = 'MarkdownLLM', level = config.log_level})

    -- Commands

    vim.api.nvim_create_user_command('MarkdownLLMNewChat', function()
        select_preset(function(preset)
            if not preset then
                return
            end
            open_chat(preset)
        end)
    end, { desc = 'Open a new MarkdownLLM markdown buffer (optionally with preset)' })

    vim.api.nvim_create_user_command('MarkdownLLMSendChat', function()
        send_current_buffer()
    end, { desc = 'Send the current MarkdownLLM buffer to the provider' })

    vim.api.nvim_create_user_command('MarkdownLLMRunAction', function()
        action_from_visual()
    end, { range = true, desc = 'Pick an action for the visual selection and send it' })

    vim.api.nvim_create_user_command('MarkdownLLMSelectBufferSetup', function()
        local buffer = vim.api.nvim_get_current_buf()
        select_buffer_setup(buffer)
    end, { desc = 'Select the MarkdownLLM setup for the current buffer (provider + model + options)' })

    vim.api.nvim_create_user_command('MarkdownLLMSelectDefaultSetup', function()
        select_default_setup()
    end, { desc = 'Select the MarkdownLLM default setup' })

    vim.api.nvim_create_user_command('MarkdownLLMEditBufferSetup', function()
        local buffer = vim.api.nvim_get_current_buf()
        open_setup_editor(buffer)
    end, { desc = 'Edit the MarkdownLLM setup for the current buffer in a floating window' })

    vim.api.nvim_create_user_command('MarkdownLLMSaveChat', function()
        save_current_buffer()
    end, { desc = 'Save the current MarkdownLLM buffer to a file' })

    vim.api.nvim_create_user_command('MarkdownLLMResumeChat', function()
        resume_saved_chat()
    end, { desc = 'Resume a saved MarkdownLLM chat from disk' })

    -- Keymaps

    if config.keymaps and config.keymaps.newChat then
        vim.keymap.set(
            'n',
            config.keymaps.newChat,
            ':MarkdownLLMNewChat<CR>',
            { desc = 'New MarkdownLLM chat' }
        )
    end

    if config.keymaps and config.keymaps.sendChat then
        vim.keymap.set(
            'n',
            config.keymaps.sendChat,
            ':MarkdownLLMSendChat<CR>',
            { desc = 'Send MarkdownLLM message' }
        )
    end

    if config.keymaps and config.keymaps.selectChatSetup then
        vim.keymap.set(
            'n',
            config.keymaps.selectChatSetup,
            ':MarkdownLLMSelectBufferSetup<CR>',
            { desc = 'Select the MarkdownLLM setup to use for the current chat' }
        )
    end

    if config.keymaps and config.keymaps.selectDefaultSetup then
        vim.keymap.set(
            'n',
            config.keymaps.selectDefaultSetup,
            ':MarkdownLLMSelectDefaultSetup<CR>',
            { desc = 'Select the MarkdownLLM default setup' }
        )
    end

    if config.keymaps and config.keymaps.editBufferSetup then
        vim.keymap.set(
            'n',
            config.keymaps.editBufferSetup,
            ':MarkdownLLMEditBufferSetup<CR>',
            { desc = 'Edit the MarkdownLLM buffer setup' }
        )
    end

    if config.keymaps and config.keymaps.actions then
        vim.keymap.set(
            'v',
            config.keymaps.actions,
            ":'<,'>MarkdownLLMRunAction<CR>",
            { desc = 'MarkdownLLM action' }
        )
    end

    if config.keymaps and config.keymaps.saveChat then
        vim.keymap.set(
            'n',
            config.keymaps.saveChat,
            ':MarkdownLLMSaveChat<CR>',
            { desc = 'Save MarkdownLLM chat' }
        )
    end

    if config.keymaps and config.keymaps.resumeChat then
        vim.keymap.set(
            'n',
            config.keymaps.resumeChat,
            ':MarkdownLLMResumeChat<CR>',
            { desc = 'Resume MarkdownLLM chat' }
        )
    end
end

return M
