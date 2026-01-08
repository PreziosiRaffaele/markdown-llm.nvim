--- OpenAI-compatible driver implementation for MarkdownLLM.
---
--- Responsibilities:
--- - Build OpenAI-compatible payloads.
--- - Resolve authentication (API key).
--- - Parse SSE/JSON responses.
---@module 'markdownllm.providers.openai'

local M = {}

local logger = require('markdownllm.logger')

local DEFAULT_BASE_URLS = {
    openai = 'https://api.openai.com/v1/chat/completions',
    grok = 'https://api.x.ai/v1/chat/completions',
    deepseek = 'https://api.deepseek.com/v1/chat/completions',
}

local WEB_SEARCH_TOOLS = {
    openai = {
        { type = 'web_search' },
    },
    grok = {
        { type = 'web_search' },
    },
}

---@param setup table
---@return string
local function provider_label(setup)
    if setup and setup.provider_label and setup.provider_label ~= '' then
        return setup.provider_label
    end
    if setup and setup.provider_name and setup.provider_name ~= '' then
        return setup.provider_name
    end
    return 'OpenAI-compatible'
end

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


---@param options table|nil
---@param provider_name string|nil
---@return table
local function normalize_options(options, provider_name)
    if type(options) ~= 'table' then
        return {}
    end
    local normalized = vim.deepcopy(options)
    normalized.payload_overrides = nil
    if normalized.web_search ~= nil then
        if normalized.web_search == true and normalized.tools == nil then
            local web_search_tool = WEB_SEARCH_TOOLS[provider_name]
            if web_search_tool then
                normalized.tools = vim.deepcopy(web_search_tool)
            else
                logger.warn(string.format(
                    'web_search is not supported for %s; ignoring.',
                    provider_label({ provider_name = provider_name })
                ))
            end
        end
        normalized.web_search = nil
    end
    return normalized
end

---@param setup table
---@return string
local function resolve_base_url(setup)
    if setup.base_url and setup.base_url ~= '' then
        return setup.base_url
    end
    local provider_name = setup.provider_name
    if provider_name and DEFAULT_BASE_URLS[provider_name] then
        return DEFAULT_BASE_URLS[provider_name]
    end
    return DEFAULT_BASE_URLS.openai
end

---@param setup table
---@return table|nil
---@return string|nil
function M.new(setup)
    local label = provider_label(setup or {})
    local api_key = os.getenv(setup.api_key_name or '')
    if not api_key or api_key == '' then
        return nil, label .. ' API key not found. Set environment variable ' .. tostring(setup.api_key_name) .. '.'
    end

    local provider_name = setup.provider_name
    local base_url = resolve_base_url(setup)
    local driver = {
        stream_format = 'sse',
    }

    ---Build the OpenAI request specification.
    ---@param request markdownllm.LLMRequest
    ---@return table|nil
    ---@return string|nil
    function driver.spec(request)
        local payload = {
            model = request.context.model,
            messages = request.messages,
            stream = request.context.stream and true or false,
        }

        local options = request.options or {}
        payload = vim.tbl_deep_extend('force', payload, normalize_options(options, provider_name))
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

        for line in event:gmatch('[^\r\n]+') do
            if vim.startswith(line, 'data: ') then
                saw_data = true
                local json_str = line:sub(7)
                if json_str == '[DONE]' then
                    return nil
                end

                local ok, body = decode_json(json_str)
                if not ok then
                    return nil, label .. ' JSON decode error: ' .. json_str, 'warning'
                end
                if body and body.error then
                    return nil, label .. ' API error: ' .. (body.error.message or vim.inspect(body.error)), 'fatal'
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
            return nil, label .. ' JSON decode error: ' .. event, 'fatal'
        end
        if body and body.error then
            return nil, label .. ' API error: ' .. (body.error.message or vim.inspect(body.error)), 'fatal'
        end

        return extract_text(body)
    end

    return driver
end

return M
