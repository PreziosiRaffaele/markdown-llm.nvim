--- OpenAI /v1/responses driver implementation for MarkdownLLM.
---
--- Responsibilities:
--- - Build OpenAI Responses payloads.
--- - Resolve authentication (API key).
--- - Parse SSE/JSON responses.
---@module 'markdownllm.providers.openai'

local M = {}
local responses = require('markdownllm.providers.responses')

local DEFAULT_BASE_URL = 'https://api.openai.com/v1/responses'

local UNSUPPORTED_OPTIONS = {
    'stop',
    'frequency_penalty',
    'presence_penalty',
    'seed',
}

---@param messages markdownllm.LLMRequestMessage[]
---@return string|nil
---@return table
local function build_input(messages)
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

---@param event_type string|nil
---@param body table|nil
---@return string|nil
local function event_to_text(event_type, body)
    if event_type == 'response.output_text.delta' then
        return body and body.delta or nil
    end
    return nil
end

---@param options table|nil
---@return table
---@return string[]
local function normalize_options(options)
    if type(options) ~= 'table' then
        return {}, {}
    end

    local normalized = {}
    local warnings = {}

    if options.temperature ~= nil then
        normalized.temperature = options.temperature
    end

    if options.top_p ~= nil then
        normalized.top_p = options.top_p
    end

    if options.max_tokens ~= nil then
        normalized.max_output_tokens = options.max_tokens
    end

    if options.reasoning_effort ~= nil then
        normalized.reasoning = {
            effort = options.reasoning_effort,
        }
    end

    if options.web_search == true then
        normalized.tools = {
            { type = 'web_search_preview' },
        }
    end

    local ignored = {}
    for _, key in ipairs(UNSUPPORTED_OPTIONS) do
        if options[key] ~= nil then
            table.insert(ignored, key)
        end
    end

    if #ignored > 0 then
        table.insert(
            warnings,
            'OpenAI Responses ignores unsupported options: ' .. table.concat(ignored, ', ') .. '.'
        )
    end

    return normalized, warnings
end

---@param setup table
---@return table|nil
---@return string|nil
function M.new(setup)
    local label = setup.provider or 'OpenAI'
    local api_key = os.getenv(setup.api_key_name or '')
    if not api_key or api_key == '' then
        return nil, label .. ' API key not found. Set environment variable ' .. tostring(setup.api_key_name) .. '.'
    end

    local base_url = setup.base_url and setup.base_url ~= '' and setup.base_url or DEFAULT_BASE_URL
    local driver = {
        stream_format = 'sse',
    }

    ---Build the OpenAI Responses request specification.
    ---@param request markdownllm.LLMRequest
    ---@return table|nil
    ---@return string|nil
    function driver.spec(request)
        local instructions, input = build_input(request.messages)
        local options, warnings = normalize_options(request.options)

        local payload = {
            model = request.context.model,
            input = input,
            stream = request.context.stream and true or false,
            store = false,
        }

        if instructions and instructions ~= '' then
            payload.instructions = instructions
        end

        payload = vim.tbl_deep_extend('force', payload, options)

        return {
            url = base_url,
            headers = {
                ['Content-Type'] = 'application/json',
                ['Authorization'] = 'Bearer ' .. api_key,
            },
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
        return responses.parse_event(event, {
            label = label,
            event_to_text = event_to_text,
        })
    end

    return driver
end

return M
