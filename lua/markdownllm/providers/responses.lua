--- Shared Responses API helpers for MarkdownLLM providers.
---
--- Responsibilities:
--- - Map provider-agnostic messages and options to Responses payload fields.
--- - Parse Responses SSE events and JSON bodies.
---@module 'markdownllm.providers.responses'

local M = {}

local provider_util = require('markdownllm.providers.util')

-- ============================================================================
-- Local helpers
-- ============================================================================

-- Fixed iteration order keeps payloads and warning messages deterministic.
local OPTION_KEYS = {
    'temperature',
    'top_p',
    'max_tokens',
    'stop',
    'frequency_penalty',
    'presence_penalty',
    'seed',
    'reasoning_effort',
    'web_search',
}

-- Options without a mapper here must be listed as unsupported by the caller.
local OPTION_MAPPERS = {
    temperature = function(payload, value)
        payload.temperature = value
    end,
    top_p = function(payload, value)
        payload.top_p = value
    end,
    max_tokens = function(payload, value)
        payload.max_output_tokens = value
    end,
    reasoning_effort = function(payload, value)
        payload.reasoning = { effort = value }
    end,
    web_search = function(payload, value, spec)
        if value == true then
            payload.tools = { { type = spec.web_search_tool or 'web_search_preview' } }
        end
    end,
}

---@param keys string[]|nil
---@return table<string, boolean>
local function to_set(keys)
    local set = {}
    for _, key in ipairs(keys or {}) do
        set[key] = true
    end
    return set
end

-- ============================================================================
-- Public API
-- ============================================================================

---Split messages into Responses `instructions` and `input`.
---The first system message becomes `instructions`; every other message is kept in order.
---@param messages markdownllm.LLMRequestMessage[]|nil
---@return string|nil instructions
---@return table input
function M.build_input(messages)
    local instructions = nil
    local input = {}

    for _, message in ipairs(messages or {}) do
        if instructions == nil and message.role == 'system' then
            instructions = message.content
        else
            table.insert(input, {
                role = message.role,
                content = message.content,
            })
        end
    end

    return instructions, input
end

---@class markdownllm.ResponsesOptionsSpec
---@field label string Name used in warnings (e.g. `OpenAI Responses`).
---@field unsupported string[] Option keys the provider ignores with a warning.
---@field web_search_tool string|nil Tool type enabled by `web_search` (default: `web_search_preview`).

---Map provider-agnostic options to Responses payload fields.
---Does not modify `options`.
---@param options table|nil
---@param spec markdownllm.ResponsesOptionsSpec
---@return table fields Payload fields to merge into the request body.
---@return string[] warnings
function M.map_options(options, spec)
    if type(options) ~= 'table' then
        return {}, {}
    end

    local unsupported = to_set(spec.unsupported)
    local fields = {}
    local ignored = {}

    for _, key in ipairs(OPTION_KEYS) do
        local value = options[key]
        if value ~= nil then
            if unsupported[key] or not OPTION_MAPPERS[key] then
                table.insert(ignored, key)
            else
                OPTION_MAPPERS[key](fields, vim.deepcopy(value), spec)
            end
        end
    end

    local warnings = {}
    if #ignored > 0 then
        table.insert(warnings, spec.label .. ' ignores unsupported options: ' .. table.concat(ignored, ', ') .. '.')
    end

    return fields, warnings
end

---Return the text fragment carried by a streaming output-text delta event.
---@param event_type string|nil
---@param body table|nil
---@return string|nil
function M.output_text_delta(event_type, body)
    if event_type == 'response.output_text.delta' then
        return body and body.delta or nil
    end
    return nil
end

---Extract concatenated output text from a Responses JSON body.
---@param body table|nil
---@return string|nil
function M.extract_output_text(body)
    local output = body and body.output
    if type(output) ~= 'table' then
        return nil
    end

    local fragments = {}
    for _, item in ipairs(output) do
        if type(item.content) == 'table' then
            for _, part in ipairs(item.content) do
                if part.type == 'output_text' and part.text then
                    table.insert(fragments, part.text)
                end
            end
        end
    end

    if #fragments == 0 then
        return nil
    end

    return table.concat(fragments, '')
end

---Describe a terminal response that ended without completing.
---`response.failed` carries its error in `response.error`, not the top-level `error`.
---@param body table
---@return string|nil failure Message for a failed response.
---@return string|nil incomplete Reason for an incomplete (truncated) response.
local function terminal_problem(body)
    local response = type(body.response) == 'table' and body.response or body
    local is_failed = body.type == 'response.failed' or (body.type == nil and response.status == 'failed')
    local is_incomplete = body.type == 'response.incomplete' or (body.type == nil and response.status == 'incomplete')

    if is_failed then
        local response_error = response.error
        if type(response_error) == 'table' and type(response_error.message) == 'string' then
            return response_error.message, nil
        end
        return 'response failed', nil
    end

    if is_incomplete then
        local details = response.incomplete_details
        local reason = type(details) == 'table' and details.reason or nil
        return nil, type(reason) == 'string' and reason or 'unknown reason'
    end

    return nil, nil
end

---@class markdownllm.ResponsesParseOptions
---@field label string Name used in error messages.
---@field event_to_text fun(event_type:string|nil, body:table|nil):string|nil

---Parse a single Responses SSE event, a whole SSE body, or a JSON response.
---A truncated (`incomplete`) response returns its text together with a warning.
---@param event string
---@param opts markdownllm.ResponsesParseOptions
---@return string|nil text
---@return string|nil err
---@return string|nil severity `fatal` or `warning` when `err` is set.
function M.parse_event(event, opts)
    local chunks = {}
    local saw_data = false
    local event_name = nil
    local label = opts.label
    local incomplete_warning = nil

    for line in event:gmatch('[^\r\n]+') do
        if vim.startswith(line, 'event:') then
            event_name = vim.trim(line:sub(7))
        elseif vim.startswith(line, 'data: ') then
            saw_data = true
            local json_str = line:sub(7)
            if json_str == '[DONE]' then
                return nil
            end

            local ok, body = pcall(vim.json.decode, json_str)
            if not ok then
                return nil, label .. ' JSON decode error: ' .. json_str, 'warning'
            end

            if type(body) == 'table' and body.type == 'error' then
                local message = body.message
                if message == nil or message == vim.NIL then
                    message = vim.inspect(body)
                end
                return nil, label .. ' API error: ' .. tostring(message), 'fatal'
            end

            local api_error = provider_util.extract_api_error(body)
            if api_error then
                return nil, label .. ' API error: ' .. api_error, 'fatal'
            end

            if type(body) == 'table' then
                local failure, incomplete = terminal_problem(body)
                if failure then
                    return nil, label .. ' API error: ' .. failure, 'fatal'
                end
                if incomplete then
                    incomplete_warning = label .. ' response incomplete: ' .. incomplete .. '.'
                end
            end

            local event_type = body and body.type or event_name
            local text_chunk = opts.event_to_text(event_type, body)
            if text_chunk and text_chunk ~= '' then
                table.insert(chunks, text_chunk)
            end
        end
    end

    if saw_data then
        local text = #chunks > 0 and table.concat(chunks, '') or nil
        if incomplete_warning then
            return text, incomplete_warning, 'warning'
        end
        return text
    end

    local ok, body = pcall(vim.json.decode, event)
    if not ok then
        return nil, label .. ' JSON decode error: ' .. event, 'fatal'
    end

    local api_error = provider_util.extract_api_error(body)
    if api_error then
        return nil, label .. ' API error: ' .. api_error, 'fatal'
    end

    local text = M.extract_output_text(body)
    if type(body) == 'table' then
        local failure, incomplete = terminal_problem(body)
        if failure then
            return nil, label .. ' API error: ' .. failure, 'fatal'
        end
        if incomplete then
            return text, label .. ' response incomplete: ' .. incomplete .. '.', 'warning'
        end
    end
    return text
end

return M
