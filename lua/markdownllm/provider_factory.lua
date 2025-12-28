--- Provider factory for MarkdownLLM.
---
--- Maps a provider name (e.g. `gemini`, `openai`) to a provider implementation module.
---@module 'markdownllm.provider_factory'

local M = {}

local providers = {
    gemini = require('markdownllm.providers.gemini'),
    grok = require('markdownllm.providers.grok'),
    openai = require('markdownllm.providers.openai'),
}

--- Resolve a provider implementation by name.
--- @tparam string provider_name Provider identifier (e.g. `gemini`, `openai`).
--- @treturn table implementation Provider module exposing `send(...)`.
--- @raise If `provider_name` is unknown.
function M.get(provider_name)
    local implementation = providers[provider_name]

    -- check if the provider is supported
    if not implementation then
        error('Provider ' .. tostring(provider_name) .. ' is not supported.')
    end

    -- check if implementation has send function
    if type(implementation.send) ~= 'function' then
        error('Provider ' .. provider_name .. ' does not have a send function.')
    end

    return implementation
end

return M
