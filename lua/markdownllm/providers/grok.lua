--- Grok /v1/responses driver implementation for MarkdownLLM.
---
--- Responsibilities:
--- - Build Grok Responses payloads.
--- - Resolve authentication (API key).
--- - Parse SSE/JSON responses.
---@module 'markdownllm.providers.grok'

local M = {}
local responses = require('markdownllm.providers.responses')

local DEFAULT_BASE_URL = 'https://api.x.ai/v1/responses'

---@param messages markdownllm.LLMRequestMessage[]
---@return table
local function build_input(messages)
    local input = {}
    for _, message in ipairs(messages or {}) do
        table.insert(input, {
            role = message.role,
            content = message.content,
        })
    end
    return input
end

---@param options table|nil
---@return table
local function normalize_options(options)
    if type(options) ~= 'table' then
        return {}
    end
    return vim.deepcopy(options)
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

---@param setup table
---@return table|nil
---@return string|nil
function M.new(setup)
    local label = setup.provider or 'Grok'
    local api_key = os.getenv(setup.api_key_name or '')
    if not api_key or api_key == '' then
        return nil, label .. ' API key not found. Set environment variable ' .. tostring(setup.api_key_name) .. '.'
    end

    local base_url = DEFAULT_BASE_URL
    local driver = {
        stream_format = 'sse',
    }

    ---Build the Grok Responses request specification.
    ---@param request markdownllm.LLMRequest
    ---@return table|nil
    ---@return string|nil
    function driver.spec(request)
        local options = normalize_options(request.options)

        local payload = {
            model = request.context.model,
            input = build_input(request.messages),
            stream = request.context.stream and true or false,
            store = false,
        }

        if options.temperature ~= nil then
            payload.temperature = options.temperature
        end

        if options.top_p ~= nil then
            payload.top_p = options.top_p
        end

        if options.max_tokens ~= nil then
            payload.max_output_tokens = options.max_tokens
        end

        if options.web_search == true then
            payload.tools = {
                { type = 'web_search' },
            }
        end

        if options.reasoning_effort ~= nil then
            payload.reasoning = {
                effort = options.reasoning_effort
            }
        end

        return {
            url = base_url,
            headers = {
                ['Content-Type'] = 'application/json',
                ['Authorization'] = 'Bearer ' .. api_key,
            },
            body = payload,
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
