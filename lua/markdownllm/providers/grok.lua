--- Grok (xAI) provider implementation for MarkdownLLM.
---
--- Responsibilities:
--- - Build OpenAI-compatible payloads for Grok.
--- - Resolve authentication (API key).
--- - Make HTTP request (Streaming).
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
        stream = true,
    }

    if opts then
        payload = vim.tbl_deep_extend('force', payload, opts)
    end

    return payload
end

local function extract_stream_text(body)
    local choice = body and body.choices and body.choices[1]
    if not choice then
        return nil
    end

    local delta = choice.delta
    if delta and delta.content then
        return delta.content
    end

    if choice.text then
        return choice.text
    end

    local message = choice.message
    if message and message.content then
        return message.content
    end

    return nil
end

--- Send a chat completion request to Grok (xAI) with streaming.
--- @tparam table setup Active setup table (`{ model = ..., api_key_name = ..., base_url = ..., opts = ... }`).
--- @tparam string system_text System/instructions block.
--- @tparam table messages List of `{ role = "user"|"model", text = string }`.
--- @tparam function on_chunk Callback `(partial_text:string)` called whenever new text arrives.
--- @tparam function|nil on_complete Callback `()` called when the stream finishes successfully.
--- @tparam function|nil on_error Callback `(message:string)` (defaults to `logger.error`).
--- @treturn nil
function M.send(setup, system_text, messages, on_chunk, on_complete, on_error)
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

    local buffer = ""
    local raw_buffer = ""
    local stderr_buffer = {}
    local completed = false
    local saw_data_line = false

    vim.system({
        'curl',
        '-s',
        '-N',
        '-X',
        'POST',
        url,
        '-H',
        'Content-Type: application/json',
        '-H',
        'Authorization: Bearer ' .. api_key,
        '-d',
        encoded,
    }, {
        stdout = function(_, data)
            if not data then return end

            raw_buffer = raw_buffer .. data
            buffer = buffer .. data

            while true do
                local newline_index = string.find(buffer, "\n")
                if not newline_index then break end

                local line = string.sub(buffer, 1, newline_index - 1)
                buffer = string.sub(buffer, newline_index + 1)

                line = string.gsub(line, "\r$", "")
                if vim.startswith(line, "data: ") then
                    saw_data_line = true
                    local json_str = string.sub(line, 7)
                    if json_str == "[DONE]" then
                        if not completed then
                            completed = true
                            if on_complete then
                                vim.schedule(on_complete)
                            end
                        end
                        return
                    end

                    vim.schedule(function()
                        local ok, body = pcall(vim.fn.json_decode, json_str)
                        if not ok then
                            on_error("Grok JSON decode error: " .. json_str)
                            return
                        end

                        if body.error then
                            on_error('Grok API error: ' .. (body.error.message or vim.inspect(body.error)))
                            return
                        end

                        local text_chunk = extract_stream_text(body)
                        if text_chunk then
                            on_chunk(text_chunk)
                        end
                    end)
                end
            end
        end,
        stderr = function(_, data)
            if data then
                table.insert(stderr_buffer, data)
            end
        end,
    }, function(obj)
        vim.schedule(function()
            if obj.code ~= 0 then
                local err_msg = table.concat(stderr_buffer, "")
                if err_msg == "" then err_msg = "exit code " .. obj.code end
                on_error('Request failed: ' .. err_msg)
                return
            end

            if not saw_data_line then
                local trimmed = vim.trim(raw_buffer)
                if trimmed ~= "" then
                    local ok, body = pcall(vim.fn.json_decode, trimmed)
                    if ok and body and body.error then
                        on_error('Grok API error: ' .. (body.error.message or vim.inspect(body.error)))
                        return
                    end
                    on_error('Grok returned an unexpected non-streaming response.')
                    return
                end
            end

            if not completed and on_complete then
                on_complete()
            end
        end)
    end)
end

return M
