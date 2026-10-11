--- OpenAI Codex (ChatGPT subscription) driver implementation for MarkdownLLM.
---
--- Responsibilities:
--- - Build Responses payloads accepted by the ChatGPT Codex backend.
--- - Authenticate with the ChatGPT credentials stored by `codex login`.
--- - Parse SSE responses.
---
--- The Codex backend is not a public API: it requires `store = false`, a
--- non-empty `instructions` field, and always streams.
---@module 'markdownllm.providers.openai_codex'

local M = {}
local auth = require('markdownllm.providers.openai_codex_auth')
local responses = require('markdownllm.providers.responses')

local LABEL = 'OpenAI Codex'
local DEFAULT_BASE_URL = 'https://chatgpt.com/backend-api/codex/responses'

-- Identify the plugin honestly instead of impersonating the Codex CLI.
local ORIGINATOR = 'markdownllm'

-- The backend rejects requests without instructions; used when the chat has no
-- `# System` section.
local DEFAULT_INSTRUCTIONS = 'You are a helpful assistant.'

-- Verified against the live backend: temperature and top_p are rejected with
-- "Unsupported parameter", and the web search tool type is `web_search`.
local OPTIONS_SPEC = {
    label = LABEL,
    web_search_tool = 'web_search',
    unsupported = {
        'temperature',
        'top_p',
        'stop',
        'frequency_penalty',
        'presence_penalty',
        'seed',
    },
}

-- ============================================================================
-- Public API
-- ============================================================================

---Create a driver. Credentials are read on every call so a token refreshed by
---the Codex CLI is picked up on the next request.
---@param setup table
---@return table|nil
---@return string|nil
function M.new(setup)
    local credentials, auth_err = auth.read(setup.auth_file)
    if not credentials then
        return nil, auth_err
    end

    local base_url = setup.base_url and setup.base_url ~= '' and setup.base_url or DEFAULT_BASE_URL
    local driver = {
        stream_format = 'sse',
    }

    ---Build the Codex backend request specification.
    ---@param request markdownllm.LLMRequest
    ---@return table|nil
    ---@return string|nil
    function driver.spec(request)
        local instructions, input = responses.build_input(request.messages)
        local options, warnings = responses.map_options(request.options, OPTIONS_SPEC)

        -- The backend only streams. Non-streaming callers still work because the
        -- engine passes the whole SSE body to `parse`, which joins every delta.
        local payload = {
            model = request.context.model,
            instructions = (instructions and instructions ~= '') and instructions or DEFAULT_INSTRUCTIONS,
            input = input,
            stream = true,
            store = false,
        }

        payload = vim.tbl_deep_extend('force', payload, options)

        return {
            url = base_url,
            headers = {
                ['Content-Type'] = 'application/json',
                ['Accept'] = 'text/event-stream',
                ['Authorization'] = 'Bearer ' .. credentials.access_token,
                ['chatgpt-account-id'] = credentials.account_id,
                ['OpenAI-Beta'] = 'responses=experimental',
                ['originator'] = ORIGINATOR,
            },
            body = payload,
            warnings = warnings,
        }
    end

    ---Parse a single SSE event, or a whole SSE body for non-streaming requests.
    ---@param event string
    ---@return string|nil
    ---@return string|nil
    ---@return string|nil
    function driver.parse(event)
        return responses.parse_event(event, {
            label = LABEL,
            event_to_text = responses.output_text_delta,
        })
    end

    return driver
end

return M
