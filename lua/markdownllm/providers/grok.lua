--- Grok /v1/responses driver implementation for MarkdownLLM.
---
--- Responsibilities:
--- - Build Grok Responses payloads.
--- - Resolve authentication (API key).
--- - Parse SSE/JSON responses.
---@module 'markdownllm.providers.grok'

local M = {}

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

---@param body table|nil
---@return string|nil
local function extract_output_text(body)
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
        if options.max_output_tokens ~= nil then
            payload.max_output_tokens = options.max_output_tokens
        elseif options.max_tokens ~= nil then
            payload.max_output_tokens = options.max_tokens
        end

        if type(options.tools) == 'table' and #options.tools > 0 then
            payload.tools = vim.deepcopy(options.tools)
        elseif options.web_search == true then
            payload.tools = {
                { type = 'web_search' },
            }
        end

        if options.store ~= nil then
            payload.store = options.store
        end

        if type(options.payload_overrides) == 'table' then
            payload = vim.tbl_deep_extend('force', payload, options.payload_overrides)
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
        local chunks = {}
        local saw_data = false
        local event_name = nil

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
                if body and body.error then
                    return nil, label .. ' API error: ' .. (body.error.message or vim.inspect(body.error)), 'fatal'
                end

                local event_type = body and body.type or event_name
                local text_chunk = nil
                if event_type == 'response.output_text.delta' then
                    text_chunk = body.delta
                elseif event_type == 'response.output_text.done' then
                    text_chunk = nil
                elseif event_type == 'response.completed' then
                    text_chunk = nil
                end

                if text_chunk and text_chunk ~= '' then
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

        local ok, body = pcall(vim.json.decode, event)
        if not ok then
            return nil, label .. ' JSON decode error: ' .. event, 'fatal'
        end
        if body and body.error then
            return nil, label .. ' API error: ' .. (body.error.message or vim.inspect(body.error)), 'fatal'
        end

        return extract_output_text(body)
    end

    return driver
end

return M
