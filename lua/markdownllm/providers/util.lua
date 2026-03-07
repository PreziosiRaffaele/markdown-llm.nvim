--- Provider utility helpers for MarkdownLLM.
---@module 'markdownllm.providers.util'

local M = {}

---Extract a provider error message from a decoded JSON body.
---@param body table|nil
---@return string|nil
function M.extract_api_error(body)
    local api_error = body and body.error or nil
    if api_error == nil or api_error == vim.NIL then
        return nil
    end
    if type(api_error) == 'table' and api_error.message and api_error.message ~= vim.NIL then
        return tostring(api_error.message)
    end
    return vim.inspect(api_error)
end

return M
