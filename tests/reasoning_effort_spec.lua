---Regression tests for provider-specific reasoning_effort payload mappings.

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

---@param module_name string
---@param setup table
---@return table
local function new_driver(module_name, setup)
    setup.api_key_name = 'MARKDOWNLLM_TEST_API_KEY'
    local driver, err = require(module_name).new(setup)
    assert(driver, err)
    return driver
end

---@param provider string
---@param model string
---@param options table|nil
---@param stream boolean
---@return markdownllm.LLMRequest
local function request(provider, model, options, stream)
    return {
        context = {
            provider = provider,
            model = model,
            stream = stream,
        },
        messages = {
            { role = 'user', content = 'Hello' },
        },
        options = options or {},
    }
end

test('DeepSeek maps none to disabled thinking without mutating options', function()
    local driver = new_driver('markdownllm.providers.openai_compatible', {
        provider = 'deepseek',
        provider_name = 'deepseek',
    })
    local options = { reasoning_effort = 'none' }

    for _, stream in ipairs({ false, true }) do
        local spec, err = driver.spec(request('deepseek', 'deepseek-chat', options, stream))
        assert(spec, err)
        assert_same(spec.body.thinking, { type = 'disabled' }, 'DeepSeek must disable thinking')
        assert_nil(spec.body.reasoning_effort, 'DeepSeek must omit top-level reasoning_effort')
    end

    assert_same(options, { reasoning_effort = 'none' }, 'DeepSeek must not mutate request options')
end)

test('DeepSeek preserves non-none and omitted efforts', function()
    local driver = new_driver('markdownllm.providers.openai_compatible', {
        provider = 'deepseek',
        provider_name = 'deepseek',
    })
    local low_spec = assert(driver.spec(request('deepseek', 'deepseek-chat', { reasoning_effort = 'low' }, false)))
    assert_same(low_spec.body.reasoning_effort, 'low', 'DeepSeek must preserve existing effort values')
    assert_nil(low_spec.body.thinking, 'DeepSeek must not add thinking for existing effort values')

    local default_spec = assert(driver.spec(request('deepseek', 'deepseek-chat', {}, false)))
    assert_nil(default_spec.body.reasoning_effort, 'DeepSeek must preserve an omitted effort')
    assert_nil(default_spec.body.thinking, 'DeepSeek must preserve default thinking behavior')
end)

test('compatible providers do not inherit the DeepSeek none mapping', function()
    local driver = new_driver('markdownllm.providers.openai_compatible', {
        provider = 'compatible',
        provider_name = 'compatible',
        base_url = 'https://example.test/v1/chat/completions',
    })
    local spec = assert(driver.spec(request('compatible', 'compatible-model', { reasoning_effort = 'none' }, false)))
    assert_same(spec.body.reasoning_effort, 'none', 'Compatible providers must preserve their existing mapping')
    assert_nil(spec.body.thinking, 'Compatible providers must not receive DeepSeek thinking fields')
end)

test('OpenAI maps none and preserves omitted effort', function()
    local driver = new_driver('markdownllm.providers.openai', { provider = 'openai' })
    local options = { reasoning_effort = 'none' }

    for _, stream in ipairs({ false, true }) do
        local spec, err = driver.spec(request('openai', 'gpt-5', options, stream))
        assert(spec, err)
        assert_same(spec.body.reasoning, { effort = 'none' }, 'OpenAI must send the none effort')
    end

    local default_spec = assert(driver.spec(request('openai', 'gpt-5', {}, false)))
    assert_nil(default_spec.body.reasoning, 'OpenAI must preserve an omitted effort')
    assert_same(options, { reasoning_effort = 'none' }, 'OpenAI must not mutate request options')
end)

test('Gemini maps none for each recognized disable-capable family', function()
    local driver = new_driver('markdownllm.providers.gemini', { provider = 'gemini' })
    local models = {
        'gemini-2.5-flash',
        'gemini-2.5-flash-preview-05-20',
        'gemini-2.5-flash-lite',
        'gemini-2.5-flash-lite-preview-06-17',
    }

    for _, model in ipairs(models) do
        local options = { reasoning_effort = 'none' }
        for _, stream in ipairs({ false, true }) do
            local spec, err = driver.spec(request('gemini', model, options, stream))
            assert(spec, err)
            assert_same(
                spec.body.generationConfig.thinkingConfig,
                { thinkingBudget = 0 },
                'Gemini must disable thinking for ' .. model
            )
            assert_nil(
                spec.body.generationConfig.thinkingConfig.thinkingLevel,
                'Gemini must not send thinkingLevel for none'
            )
        end
        assert_same(options, { reasoning_effort = 'none' }, 'Gemini must not mutate request options')
    end
end)

test('Gemini rejects known unsupported and unknown models', function()
    local driver = new_driver('markdownllm.providers.gemini', { provider = 'gemini' })
    local models = {
        'gemini-2.5-pro',
        'gemini-3-flash-preview',
        'gemini-unknown',
    }

    for _, model in ipairs(models) do
        local spec, err = driver.spec(request('gemini', model, { reasoning_effort = 'none' }, false))
        assert_nil(spec, 'Gemini must reject reasoning_effort none for ' .. model)
        assert_same(
            err,
            'Gemini model ' .. model .. ' does not support reasoning_effort = "none".',
            'Gemini must return a clear unsupported-model error'
        )
    end
end)

test('Gemini preserves non-none and omitted efforts', function()
    local driver = new_driver('markdownllm.providers.gemini', { provider = 'gemini' })
    local low_spec =
        assert(driver.spec(request('gemini', 'gemini-3-flash-preview', { reasoning_effort = 'low' }, false)))
    assert_same(
        low_spec.body.generationConfig.thinkingConfig,
        { thinkingLevel = 'low' },
        'Gemini must preserve existing effort mappings'
    )

    local default_spec = assert(driver.spec(request('gemini', 'gemini-2.5-flash', {}, false)))
    assert_nil(default_spec.body.generationConfig, 'Gemini must preserve an omitted effort')
end)

test('Grok rejects none and preserves an existing effort', function()
    local driver = new_driver('markdownllm.providers.grok', { provider = 'grok' })
    local options = { reasoning_effort = 'none' }

    for _, stream in ipairs({ false, true }) do
        local spec, err = driver.spec(request('grok', 'grok-4', options, stream))
        assert_nil(spec, 'Grok must reject reasoning_effort none')
        assert_same(
            err,
            'Grok model grok-4 does not support reasoning_effort = "none".',
            'Grok must return a clear unsupported-model error'
        )
    end

    local low_spec = assert(driver.spec(request('grok', 'grok-4', { reasoning_effort = 'low' }, false)))
    assert_same(low_spec.body.reasoning, { effort = 'low' }, 'Grok must preserve existing effort values')
    assert_same(options, { reasoning_effort = 'none' }, 'Grok must not mutate request options')
end)

test('frontmatter round-trips reasoning_effort none', function()
    local buffer = require('markdownllm.buffer')
    local lines = buffer.serialize_setup_to_yaml({
        provider = 'deepseek',
        model = 'deepseek-chat',
        reasoning_effort = 'none',
    })
    assert_same(lines[4], 'reasoning_effort: none', 'Frontmatter must serialize none unchanged')

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    local setup, err = buffer.parse_setup_from_buffer(bufnr)
    vim.api.nvim_buf_delete(bufnr, { force = true })
    assert(setup, err)
    assert_same(setup.reasoning_effort, 'none', 'Frontmatter must parse none unchanged')
end)

if #failures > 0 then
    error(table.concat(failures, '\n\n'))
end

print(string.format('%d reasoning effort tests passed', test_count))
