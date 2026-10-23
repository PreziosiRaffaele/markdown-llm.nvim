--- Anthropic Claude /v1/messages driver implementation for MarkdownLLM.
---
--- Responsibilities:
--- - Build Claude Messages payloads.
--- - Resolve authentication (API key).
--- - Parse SSE/JSON responses.
---@module 'markdownllm.providers.claude'

local M = {}
local provider_util = require('markdownllm.providers.util')

local LABEL = 'Claude'
local DEFAULT_BASE_URL = 'https://api.anthropic.com/v1/messages'
local API_VERSION = '2026-10-21'

-- The Messages API requires max_tokens. Thinking counts against it, so a low
-- default would truncate answers on models that think by default.
local DEFAULT_MAX_TOKENS = 32000

-- Dynamic-filtering web search, supported by Claude 4.6 and later models.
local WEB_SEARCH_TOOL = {
    type = 'web_search_20260209',
    name = 'web_search',
}

-- API version 2026-10-21 rejects temperature, top_p, and top_k on every model;
-- the remaining keys have no Messages API equivalent.
local UNSUPPORTED_OPTIONS = {
    'temperature',
    'top_p',
    'frequency_penalty',
    'presence_penalty',
    'seed',
}

-- ============================================================================
-- Local helpers
-- ============================================================================

---Split messages into the top-level `system` prompt and the conversation.
---The first system message becomes `system`; every other message is kept in order.
---@param messages markdownllm.LLMRequestMessage[]|nil
---@return string|nil system
---@return table conversation
local function build_messages(messages)
    local system = nil
    local conversation = {}

    for _, message in ipairs(messages or {}) do
        if system == nil and message.role == 'system' then
            system = message.content
        else
            table.insert(conversation, {
                role = message.role,
                content = message.content,
            })
        end
    end

    return system, conversation
end

---Normalize the `stop` option to the list form `stop_sequences` requires.
---A single string becomes a one-element list; a list is copied.
---@param stop string|string[]
---@return string[]
local function to_stop_sequences(stop)
    if type(stop) == 'string' then
        return { stop }
    end
    return vim.deepcopy(stop)
end

---Map provider-agnostic options to Messages payload fields.
---Does not modify `options`.
---@param options table|nil
---@return table fields Payload fields to merge into the request body.
---@return string[] warnings
local function map_options(options)
    options = type(options) == 'table' and options or {}
    local fields = {
        max_tokens = options.max_tokens or DEFAULT_MAX_TOKENS,
    }

    if options.stop ~= nil then
        fields.stop_sequences = to_stop_sequences(options.stop)
    end

    local effort = options.reasoning_effort
    if effort == 'none' then
        -- Sent as-is so the API decides whether the model can disable thinking.
        fields.thinking = { type = 'disabled' }
    elseif effort ~= nil then
        -- Adaptive thinking is off by default on some models (e.g. Opus 4.7/4.8),
        -- so enable it explicitly whenever an effort is requested.
        fields.thinking = { type = 'adaptive' }
        fields.output_config = { effort = effort }
    end

    if options.web_search == true then
        fields.tools = { vim.deepcopy(WEB_SEARCH_TOOL) }
    end

    local ignored = {}
    for _, key in ipairs(UNSUPPORTED_OPTIONS) do
        if options[key] ~= nil then
            table.insert(ignored, key)
        end
    end

    local warnings = {}
    if #ignored > 0 then
        table.insert(warnings, LABEL .. ' ignores unsupported options: ' .. table.concat(ignored, ', ') .. '.')
    end

    return fields, warnings
end

---Describe a stop reason that ended the answer early.
---@param stop_reason any
---@param stop_details any
---@return string|nil
local function stop_reason_warning(stop_reason, stop_details)
    if stop_reason == 'max_tokens' then
        return LABEL .. ' response truncated: max_tokens reached.'
    end
    if stop_reason == 'model_context_window_exceeded' then
        return LABEL .. ' response truncated: context window exceeded.'
    end
    -- Server tools such as web search stop here when their loop hits its
    -- iteration limit; the answer is unfinished.
    if stop_reason == 'pause_turn' then
        return LABEL .. ' response paused before finishing (server tool limit reached).'
    end
    if stop_reason == 'refusal' then
        local category = type(stop_details) == 'table' and stop_details.category or nil
        if type(category) == 'string' then
            return LABEL .. ' declined the request (' .. category .. ').'
        end
        return LABEL .. ' declined the request.'
    end
    return nil
end

---Return the text carried by a decoded streaming event, plus a warning when
---the event reports that the answer ended early.
---@param body table
---@return string|nil text
---@return string|nil warning
local function stream_event_text(body)
    if body.type == 'content_block_delta' then
        local delta = body.delta
        if type(delta) == 'table' and delta.type == 'text_delta' then
            return delta.text, nil
        end
    elseif body.type == 'message_delta' then
        local delta = type(body.delta) == 'table' and body.delta or {}
        return nil, stop_reason_warning(delta.stop_reason, delta.stop_details)
    end
    return nil, nil
end

---Extract concatenated text from a non-streaming Messages response.
---@param body table
---@return string|nil
local function extract_message_text(body)
    if type(body.content) ~= 'table' then
        return nil
    end

    local fragments = {}
    for _, block in ipairs(body.content) do
        if block.type == 'text' and type(block.text) == 'string' then
            table.insert(fragments, block.text)
        end
    end

    if #fragments == 0 then
        return nil
    end
    return table.concat(fragments, '')
end

---Parse a single SSE event, or a whole SSE body for non-streaming callers.
---@param event string
---@return string|nil text
---@return string|nil err
---@return string|nil severity
---@return boolean saw_data False when the event carried no `data:` line.
local function parse_sse(event)
    local chunks = {}
    local saw_data = false
    local warning = nil

    for line in event:gmatch('[^\r\n]+') do
        if vim.startswith(line, 'data:') then
            saw_data = true
            local json_str = vim.trim(line:sub(6))
            local ok, body = pcall(vim.json.decode, json_str)
            if not ok or type(body) ~= 'table' then
                return nil, LABEL .. ' JSON decode error: ' .. json_str, 'warning', true
            end

            local api_error = provider_util.extract_api_error(body)
            if api_error then
                return nil, LABEL .. ' API error: ' .. api_error, 'fatal', true
            end

            local text, event_warning = stream_event_text(body)
            if text and text ~= '' then
                table.insert(chunks, text)
            end
            warning = warning or event_warning
        end
    end

    local text = #chunks > 0 and table.concat(chunks, '') or nil
    if warning then
        return text, warning, 'warning', saw_data
    end
    return text, nil, nil, saw_data
end

-- ============================================================================
-- Public API
-- ============================================================================

---@param setup table
---@return table|nil
---@return string|nil
function M.new(setup)
    local api_key = os.getenv(setup.api_key_name or '')
    if not api_key or api_key == '' then
        return nil, LABEL .. ' API key not found. Set environment variable ' .. tostring(setup.api_key_name) .. '.'
    end

    local base_url = setup.base_url and setup.base_url ~= '' and setup.base_url or DEFAULT_BASE_URL
    local headers = {
        ['Content-Type'] = 'application/json',
        ['x-api-key'] = api_key,
        ['anthropic-version'] = API_VERSION,
    }
    -- Keys that are not scoped to one workspace must name the workspace to use.
    if type(setup.workspace_id) == 'string' and setup.workspace_id ~= '' then
        headers['anthropic-workspace-id'] = setup.workspace_id
    end

    local driver = {
        stream_format = 'sse',
    }

    ---Build the Claude Messages request specification.
    ---@param request markdownllm.LLMRequest
    ---@return table|nil
    ---@return string|nil
    function driver.spec(request)
        local system, messages = build_messages(request.messages)
        local options, warnings = map_options(request.options)

        local payload = {
            model = request.context.model,
            messages = messages,
            stream = request.context.stream and true or false,
        }

        if system and system ~= '' then
            payload.system = system
        end

        payload = vim.tbl_deep_extend('force', payload, options)

        return {
            url = base_url,
            headers = vim.deepcopy(headers),
            body = payload,
            warnings = warnings,
        }
    end

    ---Parse a single SSE event or JSON response.
    ---@param event string
    ---@return string|nil
    ---@return string|nil
    ---@return string|nil
    function driver.parse(event)
        local text, err, severity, saw_data = parse_sse(event)
        if saw_data then
            return text, err, severity
        end

        -- Event-name lines (`event: ping`) and SSE comments carry no data.
        if vim.startswith(event, 'event:') or vim.startswith(event, ':') then
            return nil
        end

        local ok, body = pcall(vim.json.decode, event)
        if not ok or type(body) ~= 'table' then
            return nil, LABEL .. ' JSON decode error: ' .. event, 'fatal'
        end

        local api_error = provider_util.extract_api_error(body)
        if api_error then
            return nil, LABEL .. ' API error: ' .. api_error, 'fatal'
        end

        local message_text = extract_message_text(body)
        local warning = stop_reason_warning(body.stop_reason, body.stop_details)
        if warning then
            return message_text, warning, 'warning'
        end
        return message_text
    end

    return driver
end

return M
