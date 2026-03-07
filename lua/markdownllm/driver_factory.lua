--- Driver factory for MarkdownLLM.
---
--- Maps a provider name (e.g. `gemini`, `openai`) to a driver implementation.
---@module 'markdownllm.driver_factory'

local M = {}

local openai = require('markdownllm.providers.openai')
local openai_compatible = require('markdownllm.providers.openai_compatible')
local grok = require('markdownllm.providers.grok')
local providers = {
    gemini = require('markdownllm.providers.gemini'),
    openai = openai,
    grok = grok,
    deepseek = openai_compatible,
}

--- Resolve a provider driver by name.
--- @tparam string provider_name Provider identifier (e.g. `gemini`, `openai`).
--- @tparam table setup Provider setup/config context.
--- @treturn table|nil driver Driver module exposing `spec(...)` and `parse(...)`.
--- @treturn string|nil error
function M.get(setup)
    local provider_name = setup.provider
    local implementation = providers[provider_name]
    if not implementation then
        return nil, 'Provider ' .. tostring(provider_name) .. ' is not supported.'
    end

    if type(implementation.new) ~= 'function' then
        return nil, 'Provider ' .. tostring(provider_name) .. ' does not expose a driver.'
    end

    local setup_copy = vim.deepcopy(setup or {})
    if not setup_copy.provider_name or setup_copy.provider_name == '' then
        setup_copy.provider_name = provider_name
    end

    local driver, error = implementation.new(setup_copy)

    if not driver then
        return nil, error
    end

    return driver
end

return M
