---Regression tests for the openai-codex provider (ChatGPT subscription).

local failures = {}
local test_count = 0

local ACCOUNT_ID = 'account-123'
local DEFAULT_URL = 'https://chatgpt.com/backend-api/codex/responses'

---@param actual any
---@param expected any
---@param message string
local function assert_same(actual, expected, message)
    if not vim.deep_equal(actual, expected) then
        error(string.format('%s\nexpected: %s\nactual:   %s', message, vim.inspect(expected), vim.inspect(actual)), 2)
    end
end

---@param value string|nil
---@param expected string
---@param message string
local function assert_contains(value, expected, message)
    if type(value) ~= 'string' or not value:find(expected, 1, true) then
        error(string.format('%s\nexpected to find: %s\nactual:           %s', message, expected, vim.inspect(value)), 2)
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

---@param value string
---@return string
local function base64url(value)
    return (vim.base64.encode(value):gsub('%+', '-'):gsub('/', '_'):gsub('=+$', ''))
end

---Build an unsigned JWT carrying the given claims.
---@param claims table
---@return string
local function fake_jwt(claims)
    return base64url('{"alg":"none"}') .. '.' .. base64url(vim.json.encode(claims)) .. '.signature'
end

---@param exp_offset integer Seconds from now until expiry.
---@param extra_claims table|nil
---@return string
local function fake_access_token(exp_offset, extra_claims)
    return fake_jwt(vim.tbl_extend('force', { exp = os.time() + exp_offset }, extra_claims or {}))
end

---Write an auth file into a fresh temp directory and return its path.
---@param auth table|string
---@return string
local function write_auth_file(auth)
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local path = dir .. '/auth.json'
    local content = type(auth) == 'string' and auth or vim.json.encode(auth)
    local file = assert(io.open(path, 'w'))
    file:write(content)
    file:close()
    return path
end

---@param access_token string
---@return table
local function chatgpt_auth(access_token)
    return {
        OPENAI_API_KEY = vim.NIL,
        tokens = {
            id_token = 'id-token',
            access_token = access_token,
            refresh_token = 'refresh-token',
            account_id = ACCOUNT_ID,
        },
        last_refresh = '2026-10-10T00:00:00Z',
    }
end

---@param path string
---@return string
local function read_file(path)
    local file = assert(io.open(path, 'r'))
    local content = file:read('*a')
    file:close()
    return content
end

---@param setup table|nil
---@return table driver
---@return string access_token
local function new_driver(setup)
    local token = fake_access_token(3600)
    local config = vim.tbl_extend('force', { auth_file = write_auth_file(chatgpt_auth(token)) }, setup or {})
    local driver, err = require('markdownllm.providers.openai_codex').new(config)
    assert(driver, err)
    return driver, token
end

---@param messages table|nil
---@param options table|nil
---@param stream boolean|nil
---@return markdownllm.LLMRequest
local function request(messages, options, stream)
    return {
        context = { provider = 'openai-codex', model = 'gpt-5.6-sol', stream = stream ~= false },
        messages = messages or { { role = 'user', content = 'Hello' } },
        options = options or {},
    }
end

-- ============================================================================
-- Credentials
-- ============================================================================

test('Credentials are read from the auth file without modifying it', function()
    local auth = require('markdownllm.providers.openai_codex_auth')
    local token = fake_access_token(3600)
    local path = write_auth_file(chatgpt_auth(token))
    local before = read_file(path)

    local credentials, err = auth.read(path)

    assert(credentials, err)
    assert_same(credentials.access_token, token, 'Access token must come from tokens.access_token')
    assert_same(credentials.account_id, ACCOUNT_ID, 'Account id must come from tokens.account_id')
    assert(credentials.expires_at > os.time(), 'Expiry must be decoded from the JWT exp claim')
    assert_same(read_file(path), before, 'The Codex auth file must never be modified')
end)

test('Account id falls back to the JWT auth claim', function()
    local auth = require('markdownllm.providers.openai_codex_auth')
    local token = fake_access_token(3600, {
        ['https://api.openai.com/auth'] = { chatgpt_account_id = 'claim-account' },
    })
    local data = chatgpt_auth(token)
    data.tokens.account_id = nil

    local credentials, err = auth.read(write_auth_file(data))

    assert(credentials, err)
    assert_same(credentials.account_id, 'claim-account', 'Account id must be read from the JWT claim')
end)

test('CODEX_HOME is used when no auth_file is configured', function()
    local auth = require('markdownllm.providers.openai_codex_auth')
    local token = fake_access_token(3600)
    local path = write_auth_file(chatgpt_auth(token))
    local original = vim.env.CODEX_HOME
    vim.env.CODEX_HOME = vim.fs.dirname(path)

    local credentials, err = auth.read(nil)
    vim.env.CODEX_HOME = original

    assert(credentials, err)
    assert_same(credentials.access_token, token, 'Credentials must be read from $CODEX_HOME/auth.json')
end)

test('Missing auth file asks the user to log in', function()
    local auth = require('markdownllm.providers.openai_codex_auth')
    local credentials, err = auth.read(vim.fn.tempname() .. '/missing.json')
    assert_same(credentials, nil, 'Missing credentials must not be returned')
    assert_contains(err, 'codex login', 'The error must explain how to log in')
end)

test('Paths with Vim special characters do not throw', function()
    local auth = require('markdownllm.providers.openai_codex_auth')
    local ok, credentials, err = pcall(auth.read, '#missing/auth.json')
    assert(ok, 'Reading must not raise for paths starting with #')
    assert_same(credentials, nil, 'Missing credentials must not be returned')
    assert_contains(err, '#missing/auth.json', 'The path must be kept verbatim')
end)

test('Invalid JSON is reported', function()
    local auth = require('markdownllm.providers.openai_codex_auth')
    local _, err = auth.read(write_auth_file('{not json'))
    assert_contains(err, 'not valid JSON', 'Malformed auth files must be reported')
end)

test('API-key Codex login points to the openai provider', function()
    local auth = require('markdownllm.providers.openai_codex_auth')
    local _, err = auth.read(write_auth_file({ OPENAI_API_KEY = 'sk-test', tokens = vim.NIL }))
    assert_contains(err, 'provider = "openai"', 'API-key logins must point to the openai provider')
end)

test('Expired access tokens are rejected before sending', function()
    local auth = require('markdownllm.providers.openai_codex_auth')
    local _, err = auth.read(write_auth_file(chatgpt_auth(fake_access_token(-10))))
    assert_contains(err, 'expired', 'Expired tokens must be reported')
    assert_contains(err, 'codex login', 'The error must explain how to refresh')
end)

test('Driver creation surfaces credential errors', function()
    local driver, err = require('markdownllm.providers.openai_codex').new({
        auth_file = vim.fn.tempname() .. '/missing.json',
    })
    assert_same(driver, nil, 'No driver must be created without credentials')
    assert_contains(err, 'codex login', 'Credential errors must reach the caller')
end)

-- ============================================================================
-- Driver
-- ============================================================================

test('Spec targets the Codex backend with subscription headers', function()
    local driver, token = new_driver()
    local spec = assert(driver.spec(request({
        { role = 'system', content = 'Be brief.' },
        { role = 'user', content = 'Hello' },
        { role = 'assistant', content = 'Hi' },
        { role = 'user', content = 'Again' },
    })))

    assert_same(spec.url, DEFAULT_URL, 'Default URL must be the Codex backend')
    assert_same(spec.headers['Authorization'], 'Bearer ' .. token, 'Access token must be sent as bearer')
    assert_same(spec.headers['chatgpt-account-id'], ACCOUNT_ID, 'Account id header is required')
    assert_same(spec.headers['OpenAI-Beta'], 'responses=experimental', 'Responses beta header is required')
    assert_same(spec.headers['originator'], 'markdownllm', 'The plugin must identify itself')
    assert_same(spec.body, {
        model = 'gpt-5.6-sol',
        instructions = 'Be brief.',
        input = {
            { role = 'user', content = 'Hello' },
            { role = 'assistant', content = 'Hi' },
            { role = 'user', content = 'Again' },
        },
        stream = true,
        store = false,
    }, 'Body must follow the Codex backend contract')
end)

test('Instructions default when the chat has no system section', function()
    local driver = new_driver()
    local spec = assert(driver.spec(request()))
    assert_same(spec.body.instructions, 'You are a helpful assistant.', 'Instructions are required by the backend')
end)

test('Non-streaming requests still ask the backend to stream', function()
    local driver = new_driver()
    local spec = assert(driver.spec(request(nil, nil, false)))
    assert_same(spec.body.stream, true, 'The Codex backend only streams')
end)

test('Supported options are mapped and unsupported ones warn', function()
    local driver = new_driver()
    local spec = assert(driver.spec(request(nil, {
        temperature = 0.2,
        max_tokens = 100,
        seed = 1,
        reasoning_effort = 'high',
        web_search = true,
    })))

    assert_same(spec.body.reasoning, { effort = 'high' }, 'reasoning_effort must be sent')
    assert_same(spec.body.tools, { { type = 'web_search' } }, 'web_search must use the Codex tool type')
    assert_same(spec.body.max_output_tokens, 100, 'max_tokens must map to max_output_tokens')
    assert_same(spec.body.temperature, nil, 'temperature must not be sent')
    assert_same(
        spec.warnings,
        { 'OpenAI Codex ignores unsupported options: temperature, seed.' },
        'Ignored options must be reported'
    )
end)

test('base_url overrides the Codex endpoint', function()
    local driver = new_driver({ base_url = 'https://example.test/codex/responses' })
    local spec = assert(driver.spec(request()))
    assert_same(spec.url, 'https://example.test/codex/responses', 'base_url must override the endpoint')
end)

test('A whole SSE body is joined into one text for non-streaming actions', function()
    local driver = new_driver()
    local body = table.concat({
        'event: response.created\ndata: {"type":"response.created"}',
        'event: response.output_text.delta\ndata: {"type":"response.output_text.delta","delta":"Hel"}',
        'event: response.output_text.delta\ndata: {"type":"response.output_text.delta","delta":"lo"}',
        'event: response.output_text.done\ndata: {"type":"response.output_text.done","text":"Hello"}',
        'event: response.completed\ndata: {"type":"response.completed"}',
    }, '\n\n')

    local text, err = driver.parse(body)

    assert_same(err, nil, 'A complete SSE body must parse without errors')
    assert_same(text, 'Hello', 'Only deltas must be joined, without duplicating done events')
end)

test('SSE keep-alive comments are ignored', function()
    local driver = new_driver()
    local text, err, severity = driver.parse(': keep-alive')
    assert_same({ text, err, severity }, {}, 'A comment-only event must produce neither text nor error')

    text, err = driver.parse(
        ': keep-alive\nevent: response.output_text.delta\ndata: {"type":"response.output_text.delta","delta":"Hi"}'
    )
    assert_same(err, nil, 'Comments mixed with data must not error')
    assert_same(text, 'Hi', 'Data next to a comment must still be parsed')
end)

test('response.failed aborts with the backend error', function()
    local driver = new_driver()
    local text, err, severity = driver.parse(
        'event: response.failed\ndata: {"type":"response.failed","response":{"error":{"message":"usage limit reached"}}}'
    )
    assert_same(text, nil, 'Failed responses must not return text')
    assert_same(err, 'OpenAI Codex API error: usage limit reached', 'The failure reason must reach the user')
    assert_same(severity, 'fatal', 'Failed responses must abort')
end)

test('response.incomplete keeps the text and warns', function()
    local driver = new_driver()
    local body = table.concat({
        'event: response.output_text.delta\ndata: {"type":"response.output_text.delta","delta":"partial"}',
        'event: response.incomplete\ndata: {"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"}}}',
    }, '\n\n')
    local text, err, severity = driver.parse(body)
    assert_same(text, 'partial', 'Truncated text must be kept')
    assert_same(err, 'OpenAI Codex response incomplete: max_output_tokens.', 'The truncation reason must be reported')
    assert_same(severity, 'warning', 'Incomplete responses must not abort')
end)

test('The driver factory resolves openai-codex', function()
    local token = fake_access_token(3600)
    local driver, err = require('markdownllm.driver_factory').get({
        provider = 'openai-codex',
        auth_file = write_auth_file(chatgpt_auth(token)),
    })
    assert(driver, err)
end)

test('The engine keeps credentials out of logs and argv', function()
    local token = fake_access_token(3600)
    local auth_file = write_auth_file(chatgpt_auth(token))
    local original_logger = package.loaded['markdownllm.logger']
    local original_llm = package.loaded['markdownllm.llm']
    local original_system = vim.system
    local original_schedule = vim.schedule
    local logged = {}
    local captured_cmd, captured_stdin = nil, nil
    local events = {}

    local function capture(...)
        table.insert(logged, vim.inspect({ ... }))
    end
    package.loaded['markdownllm.logger'] =
        { trace = capture, debug = capture, info = capture, warn = capture, error = capture }
    package.loaded['markdownllm.llm'] = nil
    vim.schedule = function(callback)
        callback()
    end
    vim.system = function(cmd, opts, on_exit)
        if cmd[2] == '--version' then
            return {
                wait = function()
                    return { code = 0, stdout = 'curl 8.0.0 test' }
                end,
            }
        end
        captured_cmd = cmd
        captured_stdin = opts.stdin
        opts.stdout(
            nil,
            'event: response.output_text.delta\ndata: {"type":"response.output_text.delta","delta":"partial"}\n\n'
                .. 'event: response.incomplete\ndata: {"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"}}}\n\n'
        )
        on_exit({ code = 0 })
        return { kill = function() end }
    end

    local llm = require('markdownllm.llm')
    local req = request()
    req.context.auth_file = auth_file
    llm.send(req, {
        on_chunk = function(text)
            table.insert(events, 'chunk:' .. text)
        end,
        on_warning = function(warning)
            table.insert(events, 'warning:' .. warning)
        end,
        on_complete = function()
            table.insert(events, 'complete')
        end,
        on_error = function(err)
            table.insert(events, 'error:' .. err)
        end,
    })

    vim.system = original_system
    vim.schedule = original_schedule
    package.loaded['markdownllm.logger'] = original_logger
    package.loaded['markdownllm.llm'] = original_llm

    assert(#logged > 0, 'The engine must log the request')
    for _, line in ipairs(logged) do
        assert(not line:find(token, 1, true), 'The access token must not appear in logs')
    end
    for _, arg in ipairs(captured_cmd) do
        assert(not arg:find(token, 1, true), 'The access token must not appear in curl argv')
    end
    assert_contains(captured_stdin, 'header = "Authorization: Bearer ' .. token .. '"', 'Headers must go through stdin')
    assert_contains(captured_stdin, 'data = "{', 'The body must go through stdin')
    assert_same(events, {
        'chunk:partial',
        'warning:OpenAI Codex response incomplete: max_output_tokens.',
        'complete',
    }, 'Truncated text must be delivered before the warning')
end)

-- ============================================================================
-- Frontmatter
-- ============================================================================

test('Frontmatter round-trips provider and auth_file', function()
    local buffer = require('markdownllm.buffer')
    local lines = buffer.serialize_setup_to_yaml({
        provider = 'openai-codex',
        model = 'gpt-5.6-sol',
        auth_file = '~/.codex/auth.json',
    })

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    local setup, err = buffer.parse_setup_from_buffer(bufnr)
    vim.api.nvim_buf_delete(bufnr, { force = true })

    assert(setup, err)
    assert_same(setup.provider, 'openai-codex', 'Provider must round-trip')
    assert_same(setup.auth_file, '~/.codex/auth.json', 'auth_file must round-trip')
end)

if #failures > 0 then
    error(table.concat(failures, '\n\n'))
end

print(string.format('%d openai-codex tests passed', test_count))
