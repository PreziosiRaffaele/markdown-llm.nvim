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

local OPTIONS_SPEC = {
    label = 'OpenAI Responses',
    unsupported = {
        'stop',
        'frequency_penalty',
        'presence_penalty',
        'seed',
    },
}

-- ============================================================================
-- Public API
-- ============================================================================

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
        local instructions, input = responses.build_input(request.messages)
        local options, warnings = responses.map_options(request.options, OPTIONS_SPEC)

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
            event_to_text = responses.output_text_delta,
        })
    end

    return driver
end

return M
