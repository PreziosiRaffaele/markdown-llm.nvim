--- LLM engine for MarkdownLLM.
---
--- Orchestrates provider requests via a driver contract, managing streaming buffers
--- and delegating parsing to provider-specific drivers.
---@module 'markdownllm.llm'

local M = {}

local driver_factory = require('markdownllm.driver_factory')
local logger = require('markdownllm.logger')

-- ============================================================================
-- Local helpers and types
-- ============================================================================

---@class markdownllm.LLMRequestContext
---@field provider string Provider key resolved by driver_factory (e.g. `openai`, `deepseek`, `gemini`, `grok`).
---@field model string Provider model id. Gemini uses this in the URL path; OpenAI/Grok/DeepSeek use it in the payload.
---@field stream boolean When true, request streaming and parse SSE; when false, expect a single JSON response.
---@field timeout integer|nil Request timeout in milliseconds (mapped to curl --max-time, seconds, min 1).
---@field api_key_name string|nil Env var name containing the provider API key (required by all current drivers).
---@field base_url string|nil Override base URL for the selected provider driver; ignored by Gemini unless its driver adds support.

---@class markdownllm.LLMRequestMessage
---@field role string 'system'|'user'|'assistant'. Gemini consumes only the first system message as a system instruction.
---@field content string Plain text content (text-only payloads in current drivers).

---@class markdownllm.LLMRequestOptions
---@field temperature number|nil Sampling temperature (OpenAI/Gemini/Grok/DeepSeek).
---@field max_tokens integer|nil Max output tokens (OpenAI maps to max_output_tokens; Gemini/DeepSeek use max_tokens; Grok maps to max_output_tokens).
---@field top_p number|nil Nucleus sampling (OpenAI/Gemini/Grok/DeepSeek).
---@field stop string[]|nil Stop sequences (Gemini/DeepSeek; ignored by OpenAI Responses and Grok).
---@field frequency_penalty number|nil Penalize repeated tokens (Gemini/DeepSeek; ignored by OpenAI Responses).
---@field presence_penalty number|nil Penalize topic repetition (Gemini/DeepSeek; ignored by OpenAI Responses).
---@field seed integer|nil Deterministic seed (Gemini/DeepSeek; ignored by OpenAI Responses).
---@field reasoning_effort string|nil Provider-agnostic reasoning effort. `"none"` strictly requests disabled thinking when the provider and model support it.
---@field web_search boolean|nil Convenience toggle: OpenAI -> web_search_preview; Gemini -> google_search tool; Grok -> web_search tool; DeepSeek ignores.

---@class markdownllm.LLMRequest
---@field context markdownllm.LLMRequestContext
---@field messages markdownllm.LLMRequestMessage[]
---@field options markdownllm.LLMRequestOptions|table|nil Provider options (unknown keys may be ignored by drivers).

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

-- ============================================================================
-- Public API
-- ============================================================================

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

    if type(spec.warnings) == 'table' then
        for _, warning in ipairs(spec.warnings) do
            if type(warning) == 'string' and warning ~= '' then
                vim.schedule(function()
                    on_warning(warning)
                end)
            end
        end
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
    local terminal_sent = false
    local stream_format = request.context.stream and (driver.stream_format or 'sse') or 'json'

    local function schedule_terminal(callback)
        if terminal_sent then
            return
        end
        terminal_sent = true
        vim.schedule(callback)
    end

    local function abort_with_error(err)
        if aborted then
            return
        end
        aborted = true
        schedule_terminal(function()
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
            schedule_terminal(on_complete)
        end
    end)

    return {
        abort = function()
            abort_with_error('Request aborted.')
        end,
    }
end

return M
