--- Gemini provider implementation for MarkdownLLM.
---
--- Responsibilities:
--- - Build Gemini-specific payloads.
--- - Resolve authentication (API key).
--- - Make HTTP request (Streaming).
--- - Parse SSE response.
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

--- Send a chat completion request to Gemini with streaming.
--- @tparam table setup Active setup table (`{ model = ..., api_key_name = ..., opts = ... }`).
--- @tparam string system_text System/instructions block.
--- @tparam table messages List of `{ role = "user"|"model", text = string }`.
--- @tparam function on_chunk Callback `(partial_text:string)` called whenever new text arrives.
--- @tparam function|nil on_complete Callback `()` called when the stream finishes successfully.
--- @tparam function|nil on_error Callback `(message:string)` (defaults to `logger.error`).
--- @treturn nil
function M.send(setup, system_text, messages, on_chunk, on_complete, on_error)
    local api_key = os.getenv(setup.api_key_name)
    if not api_key or api_key == '' then
        on_error('Gemini API key not found. Set env: ' .. setup.api_key_name)
        return
    end

    local payload = build_payload(system_text, messages, setup)

    -- streamGenerateContent with sse
    local url = string.format(
        'https://generativelanguage.googleapis.com/v1beta/models/%s:streamGenerateContent?alt=sse',
        setup.model
    )

    local encoded = vim.fn.json_encode(payload)
    logger.debug('gemini request payload: ' .. encoded)

    -- Buffer to hold partial chunks from curl
    local buffer = ""
    local stderr_buffer = {}

    vim.system({
        'curl', '-s', '-N', '-X', 'POST', url,
        '-H', 'x-goog-api-key: ' .. api_key,
        '-H', 'Content-Type: application/json',
        '-d', encoded,
    }, {
        stdout = function(_, data)
            if not data then return end

            -- 1. Append new data to buffer
            buffer = buffer .. data

            -- 2. Process complete lines within the buffer
            while true do
                -- Find the first newline
                local newline_index = string.find(buffer, "\n")
                if not newline_index then break end

                -- Extract the line and remove it from buffer
                local line = string.sub(buffer, 1, newline_index - 1)
                buffer = string.sub(buffer, newline_index + 1)

                -- 3. Parse SSE 'data: ' lines
                if vim.startswith(line, "data: ") then
                    local json_str = string.sub(line, 7)

                    -- Schedule the callback interaction
                    vim.schedule(function()
                        local ok, body = pcall(vim.fn.json_decode, json_str)
                        if not ok then
                            on_error("Gemini JSON decode error: " .. json_str)
                            return
                        end

                        if body.error then
                            on_error('Gemini API Error: ' .. (body.error.message or "Unknown"))
                            return
                        end

                        local text_chunk = extract_text(body)
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
        end
    }, function(obj)
        vim.schedule(function()
            if obj.code ~= 0 then
                local err_msg = table.concat(stderr_buffer, "")
                if err_msg == "" then err_msg = "exit code " .. obj.code end
                on_error('Gemini Request failed: ' .. err_msg)
                return
            end
            on_complete()
        end)
    end)
end

return M
