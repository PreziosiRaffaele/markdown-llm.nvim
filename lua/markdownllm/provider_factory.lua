--- Provider factory for MarkdownLLM.
---
--- Legacy wrapper around the driver factory.
---@module 'markdownllm.provider_factory'

local M = {}

local driver_factory = require('markdownllm.driver_factory')

--- Resolve a provider implementation by name.
--- @tparam string provider_name Provider identifier (e.g. `gemini`, `openai`).
--- @tparam table setup Provider setup/config context.
--- @treturn table|nil driver Provider driver exposing `spec(...)` and `parse(...)`.
--- @treturn string|nil error
function M.get(provider_name, setup)
    return driver_factory.get(provider_name, setup)
end

return M
