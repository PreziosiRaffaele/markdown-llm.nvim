--- Gemini driver implementation for MarkdownLLM.
---
--- Responsibilities:
--- - Build Gemini-specific payloads.
--- - Resolve authentication (API key).
--- - Parse SSE/JSON responses.
---@module 'markdownllm.providers.gemini'

local M = {}

---@param text string
---@return boolean
---@return table|nil
local function decode_json(text)
    if vim.json and vim.json.decode then
        return pcall(vim.json.decode, text)
    end
    return pcall(vim.fn.json_decode, text)
end

---@param body table|nil
---@return string|nil
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


---@param messages markdownllm.LLMRequestMessage[]
---@return string
---@return markdownllm.LLMRequestMessage[]
local function split_system_message(messages)
    local system_text = ''
    local remaining = {}

    for _, message in ipairs(messages or {}) do
        if message.role == 'system' and system_text == '' then
            system_text = message.content or ''
        else
            table.insert(remaining, message)
        end
    end

    return system_text, remaining
end

---@param options table|nil
---@return table|nil
local function build_generation_config(options)
    if type(options) ~= 'table' then
        return nil
    end

    local config = {}
    if type(options.generation_config) == 'table' then
        config = vim.deepcopy(options.generation_config)
    end

    if options.temperature ~= nil and config.temperature == nil then
        config.temperature = options.temperature
    end
    if options.top_p ~= nil and config.topP == nil then
        config.topP = options.top_p
    end
    if options.max_tokens ~= nil and config.maxOutputTokens == nil then
        config.maxOutputTokens = options.max_tokens
    end
    if options.stop ~= nil and config.stopSequences == nil then
        config.stopSequences = options.stop
    end
    if options.frequency_penalty ~= nil and config.frequencyPenalty == nil then
        config.frequencyPenalty = options.frequency_penalty
    end
    if options.presence_penalty ~= nil and config.presencePenalty == nil then
        config.presencePenalty = options.presence_penalty
    end
    if options.seed ~= nil and config.seed == nil then
        config.seed = options.seed
    end

    if next(config) == nil then
        return nil
    end
    return config
end

---@param setup table
---@return table|nil
---@return string|nil
function M.new(setup)
    local api_key = os.getenv(setup.api_key_name or '')
    if not api_key or api_key == '' then
        return nil, 'Gemini API key not found. Set env: ' .. tostring(setup.api_key_name)
    end

    local driver = {
        stream_format = 'sse',
    }

    ---Build the Gemini request specification.
    ---@param request markdownllm.LLMRequest
    ---@return table|nil
    ---@return string|nil
    function driver.spec(request)
        local options = request.options or {}
        local system_text, remaining = split_system_message(request.messages or {})

        local payload = {
            contents = {},
        }

        if system_text ~= '' then
            payload.system_instruction = {
                parts = {
                    { text = system_text },
                },
            }
        end

        for _, message in ipairs(remaining) do
            local role = message.role == 'assistant' and 'model' or message.role
            table.insert(payload.contents, {
                role = role,
                parts = {
                    { text = message.content },
                },
            })
        end

        if type(options.tools) == 'table' and #options.tools > 0 then
            payload.tools = vim.deepcopy(options.tools)
        elseif options.web_search == true then
            payload.tools = {
                {
                    google_search = vim.empty_dict(),
                },
            }
        end

        local generation_config = build_generation_config(options)
        if generation_config then
            payload.generationConfig = generation_config
        end

        if type(options.payload_overrides) == 'table' then
            payload = vim.tbl_deep_extend('force', payload, options.payload_overrides)
        end

        local action = request.context.stream and 'streamGenerateContent?alt=sse' or 'generateContent'
        local url = string.format(
            'https://generativelanguage.googleapis.com/v1beta/models/%s:%s',
            request.context.model,
            action
        )

        return {
            url = url,
            headers = {
                ['x-goog-api-key'] = api_key,
                ['Content-Type'] = 'application/json',
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
        local chunks = {}
        local saw_data = false

        for line in event:gmatch('[^\r\n]+') do
            if vim.startswith(line, 'data: ') then
                saw_data = true
                local json_str = line:sub(7)
                local ok, body = decode_json(json_str)
                if not ok then
                    return nil, 'Gemini JSON decode error: ' .. json_str, 'warning'
                end
                if body and body.error then
                    return nil, 'Gemini API error: ' .. (body.error.message or 'Unknown'), 'fatal'
                end

                local text_chunk = extract_text(body)
                if text_chunk then
                    table.insert(chunks, text_chunk)
                end
            end
        end

        if saw_data then
            if #chunks == 0 then
                return nil
            end
            return table.concat(chunks, '')
        end

        local ok, body = decode_json(event)
        if not ok then
            return nil, 'Gemini JSON decode error: ' .. event, 'fatal'
        end
        if body and body.error then
            return nil, 'Gemini API error: ' .. (body.error.message or 'Unknown'), 'fatal'
        end

        return extract_text(body)
    end

    return driver
end

return M
