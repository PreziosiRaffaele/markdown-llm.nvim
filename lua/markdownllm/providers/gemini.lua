--- Gemini provider implementation for MarkdownLLM.
---
--- Responsibilities:
--- - Build Gemini-specific payloads.
--- - Resolve authentication (API key).
--- - Make HTTP request.
--- - Parse response and extract text.
---@module 'markdownllm.providers.gemini'

local M = {}
local logger = require('markdownllm.logger')

local function build_payload(system_text, messages, setup)
    local opts = setup.opts or {}

    local payload = {
        system_instruction = {
            parts = {
                {
                    text = system_text,
                },
            },
        },
        contents = {},
    }

    if opts.tools and #opts.tools > 0 then
        payload.tools = vim.deepcopy(opts.tools)
    end

    for _, message in ipairs(messages) do
        table.insert(payload.contents, {
            role = message.role,
            parts = {
                { text = message.text },
            },
        })
    end

    if opts.generation_config then
        payload.generationConfig = opts.generation_config
    end

    if opts.payload_overrides then
        payload = vim.tbl_deep_extend('force', payload, opts.payload_overrides)
    end

    return payload
end

local function extract_text(body)
    local candidate = body and body.candidates and body.candidates[1]
    if not candidate or not candidate.content or not candidate.content.parts then
        return nil
    end

    local fragments = {}
    for _, part in ipairs(candidate.content.parts) do
        if part.text then
            table.insert(fragments, part.text)
        end
    end

    if #fragments == 0 then
        return nil
    end

    return table.concat(fragments, '\n')
end

--- Send a chat completion request to Gemini.
--- @tparam table setup Active setup table (`{ model = ..., api_key_name = ..., opts = ... }`).
--- @tparam string system_text System/instructions block.
--- @tparam table messages List of `{ role = "user"|"model", text = string }`.
--- @tparam function|nil on_success Callback `(response_text:string)`.
--- @tparam function|nil on_error Callback `(message:string)` (defaults to `logger.error`).
--- @treturn nil
function M.send(setup, system_text, messages, on_success, on_error)
    on_error = on_error or logger.error

    local api_key = os.getenv(setup.api_key_name)
    if not api_key or api_key == '' then
        on_error('Gemini API key not found. Set environment variable ' .. setup.api_key_name .. '.')
        return
    end

    local payload = build_payload(system_text, messages, setup)
    local url = string.format(
        'https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent?key=%s',
        setup.model,
        api_key
    )

    local encoded = vim.fn.json_encode(payload)
    logger.debug('request (gemini ' .. setup.model .. '): ' .. encoded)

    vim.system({
        'curl',
        '-s',
        '-X',
        'POST',
        url,
        '-H',
        'Content-Type: application/json',
        '-d',
        encoded,
    }, { text = true }, function(obj)
        vim.schedule(function()
            if obj.code ~= 0 then
                on_error('Request failed: ' .. (obj.stderr or ('exit code ' .. obj.code)))
                return
            end

            logger.debug('raw response (gemini ' .. setup.model .. '): ' .. obj.stdout)

            local ok, body = pcall(vim.fn.json_decode, obj.stdout)
            if not ok then
                on_error('Failed to decode Gemini response: ' .. tostring(obj.stdout))
                return
            end

            if body.error then
                on_error('Gemini API error: ' .. (body.error.message or vim.inspect(body.error)))
                return
            end

            local response_text = extract_text(body)
            if not response_text then
                on_error('Gemini returned no text content. The response may have been filtered or incomplete.')
                return
            end

            on_success(response_text)
        end)
    end)
end

return M
