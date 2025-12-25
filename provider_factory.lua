--- Provider factory for Promptbook.
---
--- Maps a provider name (e.g. `gemini`, `openai`) to a provider implementation module.
---@module 'rpreziosi.core.promptbook.provider_factory'

local M = {}

local providers = {
    gemini = require('rpreziosi.core.promptbook.providers.gemini'),
    grok = require('rpreziosi.core.promptbook.providers.grok'),
    openai = require('rpreziosi.core.promptbook.providers.openai'),
}

--- Resolve a provider implementation by name.
--- @tparam string provider_name Provider identifier (e.g. `gemini`, `openai`).
--- @treturn table implementation Provider module exposing `send(...)`.
--- @raise If `provider_name` is unknown.
function M.get(provider_name)
    local implementation = providers[provider_name]
    if not implementation then
        error('Provider ' .. tostring(provider_name) .. ' is not supported.')
    end

    return implementation
end

return M
