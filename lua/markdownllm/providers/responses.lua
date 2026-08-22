--- Shared Responses API helpers for MarkdownLLM providers.
---@module 'markdownllm.providers.responses'

local M = {}

local provider_util = require('markdownllm.providers.util')

---Extract concatenated output text from a Responses JSON body.
---@param body table|nil
---@return string|nil
function M.extract_output_text(body)
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

---Parse a single Responses SSE event or JSON response.
---@param event string
---@param opts table
---@param opts.label string
---@param opts.event_to_text fun(event_type:string|nil, body:table|nil):string|nil
---@return string|nil
---@return string|nil
---@return string|nil
function M.parse_event(event, opts)
    local chunks = {}
    local saw_data = false
    local event_name = nil
    local label = opts.label

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

            if type(body) == 'table' and body.type == 'error' then
                local message = body.message
                if message == nil or message == vim.NIL then
                    message = vim.inspect(body)
                end
                return nil, label .. ' API error: ' .. tostring(message), 'fatal'
            end

            local api_error = provider_util.extract_api_error(body)
            if api_error then
                return nil, label .. ' API error: ' .. api_error, 'fatal'
            end

            local event_type = body and body.type or event_name
            local text_chunk = opts.event_to_text(event_type, body)
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

    local api_error = provider_util.extract_api_error(body)
    if api_error then
        return nil, label .. ' API error: ' .. api_error, 'fatal'
    end

    return M.extract_output_text(body)
end

return M
