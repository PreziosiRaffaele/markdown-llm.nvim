--- LLM engine for MarkdownLLM.
---
--- Orchestrates provider requests via a driver contract, managing streaming buffers
--- and delegating parsing to provider-specific drivers.
---@module 'markdownllm.llm'

local M = {}

local driver_factory = require('markdownllm.driver_factory')
local logger = require('markdownllm.logger')

---@class markdownllm.LLMRequestContext
---@field provider string LLM provider key (resolved by driver_factory).
---@field model string Provider model id.
---@field stream boolean Stream responses when true.
---@field timeout integer|nil Request timeout in milliseconds.
---@field api_key_name string|nil Env var name for the provider API key.
---@field base_url string|nil Override base URL for OpenAI-compatible drivers.

---@class markdownllm.LLMRequestMessage
---@field role string 'system'|'user'|'assistant'.
---@field content string

---@class markdownllm.LLMRequestOptions
---@field temperature number|nil Sampling temperature.
---@field max_tokens integer|nil Max output tokens.
---@field top_p number|nil Nucleus sampling.
---@field stop string[]|nil Stop sequences.
---@field frequency_penalty number|nil Penalize repeated tokens.
---@field presence_penalty number|nil Penalize topic repetition.
---@field seed integer|nil Deterministic seed (if provider supports it).
---@field web_search boolean|nil Enable web search tool (if provider support it).

---@class markdownllm.LLMRequest
---@field context markdownllm.LLMRequestContext
---@field messages markdownllm.LLMRequestMessage[]
---@field options markdownllm.LLMRequestOptions|table|nil

---@class markdownllm.LLMCallbacks
---@field on_error fun(err:string)
---@field on_warning fun(warn:string)
---@field on_chunk fun(text:string)
---@field on_complete fun()

---@class markdownllm.LLMAbortHandle
---@field abort fun()

---@param body table
---@return string
local function encode_json(body)
    if vim.json and vim.json.encode then
        return vim.json.encode(body)
    end
    return vim.fn.json_encode(body)
end

---@param callbacks markdownllm.LLMCallbacks
---@param name string
---@return function
local function callback_or_noop(callbacks, name)
    local cb = callbacks and callbacks[name]
    if type(cb) == 'function' then
        return cb
    end
    return function() end
end

---@param request markdownllm.LLMRequest
---@param callbacks markdownllm.LLMCallbacks
---@return markdownllm.LLMAbortHandle|nil
function M.send(request, callbacks)
    local on_error = callback_or_noop(callbacks, 'on_error')
    local on_warning = callback_or_noop(callbacks, 'on_warning')
    local on_chunk = callback_or_noop(callbacks, 'on_chunk')
    local on_complete = callback_or_noop(callbacks, 'on_complete')

    local driver, driver_err = driver_factory.get(request.context)
    if not driver then
        on_error(driver_err or ('Provider not found: ' .. tostring(request.context.provider)))
        return nil
    end

    local spec, spec_err = driver.spec(request)
    if not spec then
        on_error(spec_err or 'Provider spec error.')
        return nil
    end

    logger.debug('LLM request:', request)
    logger.trace('LLM request url:', spec.url)
    logger.trace('LLM request body:', spec.body)

    local cmd = { 'curl', '--silent', '--no-buffer', '-X', 'POST', spec.url }
    if request.context.timeout then
        local timeout_s = math.max(1, math.floor(request.context.timeout / 1000))
        table.insert(cmd, '--max-time')
        table.insert(cmd, tostring(timeout_s))
    end
    for k, v in pairs(spec.headers or {}) do
        table.insert(cmd, '-H')
        table.insert(cmd, string.format('%s: %s', k, v))
    end
    table.insert(cmd, '-d')
    table.insert(cmd, encode_json(spec.body))
    if spec.args then
        vim.list_extend(cmd, spec.args)
    end

    local job_obj
    local buffer = ''
    local stderr_buffer = {}
    local aborted = false
    local stream_format = request.context.stream and (driver.stream_format or 'sse') or 'json'

    local function abort_with_error(err)
        if aborted then
            return
        end
        aborted = true
        vim.schedule(function()
            on_error(err)
        end)
        if job_obj then
            job_obj:kill(15)
            vim.defer_fn(function()
                if job_obj then
                    job_obj:kill(9)
                end
            end, 500)
        end
    end

    local function handle_event(event)
        if event == '' then
            return
        end
        local text, parse_err, severity = driver.parse(event)
        if parse_err then
            if severity == 'fatal' then
                abort_with_error(parse_err)
                return
            end
            vim.schedule(function()
                on_warning(parse_err)
            end)
            return
        end
        if text and text ~= '' then
            vim.schedule(function()
                on_chunk(text)
            end)
        end
    end

    local function process_buffer()
        if stream_format == 'json' then
            return
        end
        local sep = (stream_format == 'jsonl') and '\n' or '\n\n'
        while true do
            local idx = buffer:find(sep, 1, true)
            if not idx then
                break
            end
            local event = buffer:sub(1, idx - 1)
            buffer = buffer:sub(idx + #sep)
            handle_event(event)
            if aborted then
                return
            end
        end
    end

    job_obj = vim.system(cmd, {
        stdout = function(_, data)
            if aborted or not data then
                return
            end
            logger.trace(data)
            buffer = buffer .. data
            process_buffer()
        end,
        stderr = function(_, data)
            if data then
                table.insert(stderr_buffer, data)
            end
        end,
    }, function(obj)
        if aborted then
            return
        end

        if obj.code ~= 0 then
            local err_msg = table.concat(stderr_buffer, '')
            if err_msg == '' then
                err_msg = 'exit code ' .. obj.code
            end
            abort_with_error('Request failed: ' .. err_msg)
            return
        end

        if stream_format == 'json' then
            if buffer ~= '' then
                handle_event(buffer)
            end
        else
            process_buffer()
            if buffer ~= '' then
                handle_event(buffer)
            end
        end

        if not aborted then
            vim.schedule(on_complete)
        end
    end)

    return {
        abort = function()
            abort_with_error('Request aborted.')
        end,
    }
end

return M
