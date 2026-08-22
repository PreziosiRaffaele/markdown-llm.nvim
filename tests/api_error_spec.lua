---Regression tests for surfacing provider API errors.

local failures = {}
local test_count = 0

---@param actual any
---@param expected any
---@param message string
local function assert_same(actual, expected, message)
    if not vim.deep_equal(actual, expected) then
        error(string.format('%s\nexpected: %s\nactual:   %s', message, vim.inspect(expected), vim.inspect(actual)), 2)
    end
end

---@param value string
---@param expected string
---@param message string
local function assert_contains(value, expected, message)
    if not value:find(expected, 1, true) then
        error(string.format('%s\nexpected to find: %s\nactual:           %s', message, expected, value), 2)
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

test('Responses parser treats flat SSE error events as fatal', function()
    local responses = require('markdownllm.providers.responses')
    local _, err, severity =
        responses.parse_event('event: error\ndata: {"type":"error","code":"invalid_request","message":"Bad request"}', {
            label = 'OpenAI',
            event_to_text = function()
                return nil
            end,
        })

    assert_same(err, 'OpenAI API error: Bad request', 'Flat error messages must reach the caller')
    assert_same(severity, 'fatal', 'Flat error events must abort the request')
end)

test('LLM engine asks curl to fail with the response body', function()
    local original_driver_factory = package.loaded['markdownllm.driver_factory']
    local original_llm = package.loaded['markdownllm.llm']
    local original_system = vim.system
    local original_schedule = vim.schedule
    local captured_cmd = nil
    local version_checks = 0

    package.loaded['markdownllm.driver_factory'] = {
        get = function()
            return {
                spec = function()
                    return {
                        url = 'https://example.test/v1/responses',
                        body = {},
                    }
                end,
                parse = function()
                    return nil
                end,
            }
        end,
    }
    package.loaded['markdownllm.llm'] = nil
    vim.schedule = function(callback)
        callback()
    end
    vim.system = function(cmd, opts, on_exit)
        if cmd[2] == '--version' then
            version_checks = version_checks + 1
            return {
                wait = function()
                    return { code = 0, stdout = 'curl 7.76.0 test' }
                end,
            }
        end
        captured_cmd = cmd
        opts.stdout(nil, '{"error":{"message":"Invalid API key"}}')
        opts.stderr(nil, 'curl: (22) The requested URL returned error: 401\n')
        on_exit({ code = 22 })
        return { kill = function() end }
    end

    local reported_error = nil
    local llm = require('markdownllm.llm')
    llm.send({ context = { provider = 'openai', stream = false } }, {
        on_error = function(err)
            reported_error = err
        end,
    })

    vim.system = original_system
    vim.schedule = original_schedule
    package.loaded['markdownllm.driver_factory'] = original_driver_factory
    package.loaded['markdownllm.llm'] = original_llm

    assert(vim.list_contains(captured_cmd, '--fail-with-body'), 'curl must fail on non-2xx responses')
    assert_same(version_checks, 1, 'curl support must be detected once')
    assert_contains(reported_error, 'curl: (22)', 'Transport errors must remain visible')
    assert_contains(reported_error, 'Invalid API key', 'The response body must reach the caller')
end)

if #failures > 0 then
    error(table.concat(failures, '\n\n'))
end

print(string.format('%d API error tests passed', test_count))
