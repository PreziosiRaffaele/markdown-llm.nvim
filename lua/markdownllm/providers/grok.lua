--- Grok (xAI) provider implementation for MarkdownLLM.
---
--- Responsibilities:
--- - Build OpenAI-compatible payloads for Grok.
--- - Resolve authentication (API key).
--- - Make HTTP request.
--- - Parse response and extract text.
---@module 'markdownllm.providers.grok'

local M = {}
local logger = require('markdownllm.logger')

local function build_payload(system_text, messages, setup)
    local opts = setup.opts or {}

    local chat_messages = {
        {
            role = 'system',
            content = system_text,
        },
    }

    for _, message in ipairs(messages) do
        local role = message.role == 'model' and 'assistant' or 'user'
        table.insert(chat_messages, { role = role, content = message.text })
    end

    local payload = {
        model = setup.model,
        messages = chat_messages,
    }

    if opts then
        payload = vim.tbl_deep_extend('force', payload, opts)
    end

    return payload
end

--- Send a chat completion request to Grok (xAI).
--- @tparam table setup Active setup table (`{ model = ..., api_key_name = ..., base_url = ..., opts = ... }`).
--- @tparam string system_text System/instructions block.
--- @tparam table messages List of `{ role = "user"|"model", text = string }`.
--- @tparam function|nil on_success Callback `(response_text:string)`.
--- @tparam function|nil on_error Callback `(message:string)` (defaults to `logger.error`).
--- @treturn nil
function M.send(setup, system_text, messages, on_success, on_error)
    on_error = on_error or logger.error

    local api_key = os.getenv(setup.api_key_name)
    if not api_key or api_key == '' then
        on_error('Grok API key not found. Set environment variable ' .. (setup.api_key_name) .. '.')
        return
    end

    local payload = build_payload(system_text, messages, setup)
    local encoded = vim.fn.json_encode(payload)
    local url = setup.base_url or 'https://api.x.ai/v1/chat/completions'

    logger.debug('request (grok ' .. setup.model .. '): ' .. encoded)

    vim.system({
        'curl',
        '-s',
        '-X',
        'POST',
        url,
        '-H',
        'Content-Type: application/json',
        '-H',
        'Authorization: Bearer ' .. api_key,
        '-d',
        encoded,
    }, { text = true }, function(obj)
        vim.schedule(function()
            if obj.code ~= 0 then
                on_error('Request failed: ' .. (obj.stderr or ('exit code ' .. obj.code)))
                return
            end

            logger.debug('raw response (grok ' .. setup.model .. '): ' .. obj.stdout)

            local ok, body = pcall(vim.fn.json_decode, obj.stdout)
            if not ok then
                on_error('Failed to decode Grok response: ' .. tostring(obj.stdout))
                return
            end

            if body.error then
                on_error('Grok API error: ' .. (body.error.message or vim.inspect(body.error)))
                return
            end

            local choice = body.choices and body.choices[1]
            local response_text = choice and choice.message and choice.message.content
            if not response_text then
                on_error('Grok returned no text content. The response may have been filtered or incomplete.')
                return
            end

            on_success(response_text)
        end)
    end)
end

return M
