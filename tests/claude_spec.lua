---Regression tests for the Claude Messages driver.

local failures = {}
local test_count = 0

vim.env.MARKDOWNLLM_TEST_API_KEY = 'test-key'

---@param actual any
---@param expected any
---@param message string
local function assert_same(actual, expected, message)
    if not vim.deep_equal(actual, expected) then
        error(string.format('%s\nexpected: %s\nactual:   %s', message, vim.inspect(expected), vim.inspect(actual)), 2)
    end
end

---@param value any
---@param message string
local function assert_nil(value, message)
    if value ~= nil then
        error(message .. '\nactual: ' .. vim.inspect(value), 2)
    end
end

---@param name string
---@param run function
local function test(name, run)
    test_count = test_count + 1
    local ok, err = xpcall(run, debug.traceback)
    if not ok then
        table.insert(failures, name .. ':\n' .. err)
    end
end

---@param setup table|nil
---@return table
local function new_driver(setup)
    setup = setup or {}
    setup.provider = 'claude'
    setup.api_key_name = 'MARKDOWNLLM_TEST_API_KEY'
    local driver, err = require('markdownllm.providers.claude').new(setup)
    assert(driver, err)
    return driver
end

---@param options table|nil
---@param stream boolean|nil
---@return markdownllm.LLMRequest
local function request(options, stream)
    return {
        context = {
            provider = 'claude',
            model = 'claude-opus-5-5',
            stream = stream ~= false,
        },
        messages = {
            { role = 'system', content = 'Be brief.' },
            { role = 'user', content = 'Hello' },
            { role = 'assistant', content = 'Hi' },
            { role = 'user', content = 'Again' },
        },
        options = options or {},
    }
end

---@param events table[]
---@return string
local function sse(events)
    local lines = {}
    for _, event in ipairs(events) do
        table.insert(lines, 'event: ' .. event.type .. '\ndata: ' .. vim.json.encode(event))
    end
    return table.concat(lines, '\n\n')
end

test('missing API key fails with the variable name', function()
    local driver, err = require('markdownllm.providers.claude').new({
        provider = 'claude',
        api_key_name = 'MARKDOWNLLM_TEST_MISSING_KEY',
    })
    assert_nil(driver, 'Driver must not be created without a key')
    assert_same(
        err,
        'Claude API key not found. Set environment variable MARKDOWNLLM_TEST_MISSING_KEY.',
        'Missing key error must name the variable'
    )
end)

test('spec builds a Messages request with system, headers, and default max_tokens', function()
    local spec = assert(new_driver().spec(request()))
    assert_same(spec.url, 'https://api.anthropic.com/v1/messages', 'Default endpoint')
    assert_same(spec.headers, {
        ['Content-Type'] = 'application/json',
        ['x-api-key'] = 'test-key',
        ['anthropic-version'] = '2026-10-21',
    }, 'Headers')
    assert_same(spec.body, {
        model = 'claude-opus-5-5',
        system = 'Be brief.',
        stream = true,
        max_tokens = 32000,
        messages = {
            { role = 'user', content = 'Hello' },
            { role = 'assistant', content = 'Hi' },
            { role = 'user', content = 'Again' },
        },
    }, 'Body')
    assert_same(spec.warnings, {}, 'No warnings without options')
end)

test('spec honors base_url and workspace_id', function()
    local spec = assert(new_driver({
        base_url = 'https://proxy.test/v1/messages',
        workspace_id = 'wrkspc_123',
    }).spec(request()))
    assert_same(spec.url, 'https://proxy.test/v1/messages', 'base_url override')
    assert_same(spec.headers['anthropic-workspace-id'], 'wrkspc_123', 'Workspace header')
end)

test('spec maps options and warns about unsupported ones', function()
    local options = {
        max_tokens = 1000,
        stop = 'END',
        reasoning_effort = 'high',
        web_search = true,
        temperature = 0.2,
        top_p = 0.9,
        seed = 1,
    }
    local spec = assert(new_driver().spec(request(options, false)))
    local body = spec.body
    assert_same(body.stream, false, 'Non-streaming flag')
    assert_same(body.max_tokens, 1000, 'max_tokens')
    assert_same(body.stop_sequences, { 'END' }, 'A single stop string becomes a list')
    assert_same(body.thinking, { type = 'adaptive' }, 'Effort enables adaptive thinking')
    assert_same(body.output_config, { effort = 'high' }, 'Effort goes in output_config')
    assert_same(body.tools, { { type = 'web_search_20260209', name = 'web_search' } }, 'Web search tool')
    assert_nil(body.temperature, 'temperature must not be sent')
    assert_nil(body.top_p, 'top_p must not be sent')
    assert_nil(body.seed, 'seed must not be sent')
    assert_same(
        spec.warnings,
        { 'Claude ignores unsupported options: temperature, top_p, seed.' },
        'Unsupported options warning'
    )
    assert_same(options.stop, 'END', 'Options must not be mutated')
end)

test('reasoning_effort none requests disabled thinking without an effort', function()
    local spec = assert(new_driver().spec(request({ reasoning_effort = 'none' })))
    assert_same(spec.body.thinking, { type = 'disabled' }, 'none disables thinking')
    assert_nil(spec.body.output_config, 'none sends no effort')
end)

test('parse joins text deltas and ignores thinking and ping events', function()
    local driver = new_driver()
    assert_nil(driver.parse(sse({ { type = 'message_start', message = { id = 'msg_1' } } })), 'message_start')
    assert_nil(driver.parse(sse({ { type = 'ping' } })), 'ping')
    assert_nil(
        driver.parse(
            sse({ { type = 'content_block_delta', index = 0, delta = { type = 'thinking_delta', thinking = 'x' } } })
        ),
        'thinking delta'
    )
    local text, err = driver.parse(
        sse({ { type = 'content_block_delta', index = 1, delta = { type = 'text_delta', text = 'Hel' } } })
    )
    assert_same(text, 'Hel', 'text delta')
    assert_nil(err, 'No error for a text delta')
    assert_nil(driver.parse(sse({ { type = 'message_delta', delta = { stop_reason = 'end_turn' } } })), 'end_turn')
    assert_nil(driver.parse(sse({ { type = 'message_stop' } })), 'message_stop')
end)

test('parse warns on max_tokens and refusal stop reasons', function()
    local driver = new_driver()
    local _, err, severity = driver.parse(sse({ { type = 'message_delta', delta = { stop_reason = 'max_tokens' } } }))
    assert_same(err, 'Claude response truncated: max_tokens reached.', 'Truncation warning')
    assert_same(severity, 'warning', 'Truncation is non-fatal')

    _, err, severity = driver.parse(sse({
        { type = 'message_delta', delta = { stop_reason = 'refusal', stop_details = { category = 'cyber' } } },
    }))
    assert_same(err, 'Claude declined the request (cyber).', 'Refusal warning')
    assert_same(severity, 'warning', 'Refusal is non-fatal')

    _, err, severity = driver.parse(sse({ { type = 'message_delta', delta = { stop_reason = 'pause_turn' } } }))
    assert_same(err, 'Claude response paused before finishing (server tool limit reached).', 'Pause warning')
    assert_same(severity, 'warning', 'Pause is non-fatal')

    _, err, severity = driver.parse(sse({
        { type = 'message_delta', delta = { stop_reason = 'model_context_window_exceeded' } },
    }))
    assert_same(err, 'Claude response truncated: context window exceeded.', 'Context window warning')
    assert_same(severity, 'warning', 'Context window truncation is non-fatal')
end)

test('parse treats streamed error events as fatal', function()
    local _, err, severity = new_driver().parse(sse({
        { type = 'error', error = { type = 'overloaded_error', message = 'Overloaded' } },
    }))
    assert_same(err, 'Claude API error: Overloaded', 'Error message')
    assert_same(severity, 'fatal', 'Errors abort the request')
end)

test('parse reads a whole SSE body for non-streaming callers', function()
    local body = sse({
        { type = 'content_block_delta', index = 0, delta = { type = 'text_delta', text = 'Hello' } },
        { type = 'content_block_delta', index = 0, delta = { type = 'text_delta', text = ' world' } },
        { type = 'message_delta', delta = { stop_reason = 'end_turn' } },
    })
    assert_same(new_driver().parse(body), 'Hello world', 'Joined text')
end)

test('parse reads a JSON response', function()
    local driver = new_driver()
    local text, err = driver.parse(vim.json.encode({
        type = 'message',
        content = {
            { type = 'thinking', thinking = '' },
            { type = 'text', text = 'Hello' },
            { type = 'text', text = ' world' },
        },
        stop_reason = 'end_turn',
    }))
    assert_same(text, 'Hello world', 'Text blocks are joined')
    assert_nil(err, 'No error')

    local truncated, warning, severity = driver.parse(vim.json.encode({
        type = 'message',
        content = { { type = 'text', text = 'Hel' } },
        stop_reason = 'max_tokens',
    }))
    assert_same(truncated, 'Hel', 'Truncated text is kept')
    assert_same(warning, 'Claude response truncated: max_tokens reached.', 'Truncation warning')
    assert_same(severity, 'warning', 'Truncation is non-fatal')

    local _, api_err, api_severity = driver.parse(vim.json.encode({
        type = 'error',
        error = { type = 'invalid_request_error', message = 'Bad model' },
    }))
    assert_same(api_err, 'Claude API error: Bad model', 'JSON error message')
    assert_same(api_severity, 'fatal', 'JSON errors are fatal')
end)

test('driver factory resolves the claude provider', function()
    local driver, err = require('markdownllm.driver_factory').get({
        provider = 'claude',
        api_key_name = 'MARKDOWNLLM_TEST_API_KEY',
    })
    assert(driver, err)
    assert_same(type(driver.spec), 'function', 'Driver exposes spec')
end)

test('frontmatter round-trips workspace_id', function()
    local buffer = require('markdownllm.buffer')
    local lines = buffer.serialize_setup_to_yaml({
        provider = 'claude',
        model = 'claude-opus-5-5',
        workspace_id = 'wrkspc_123',
    })
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    local setup, err = buffer.parse_setup_from_buffer(bufnr)
    vim.api.nvim_buf_delete(bufnr, { force = true })
    assert(setup, err)
    assert_same(setup.workspace_id, 'wrkspc_123', 'Frontmatter must keep workspace_id')
end)

if #failures > 0 then
    error(table.concat(failures, '\n\n'))
end

print(string.format('%d claude tests passed', test_count))
