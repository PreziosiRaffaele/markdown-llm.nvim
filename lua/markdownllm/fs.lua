--- Filesystem helpers for MarkdownLLM.
---@module 'markdownllm.fs'

local M = {}

local util = require('markdownllm.util')

---Ensure the chat save directory exists.
---@param path string|nil
---@return string|nil
---@return string|nil
function M.ensure_chat_save_dir(path)
    if not path or path == '' then
        return nil, 'Chat save directory is not configured.'
    end
    local ok, err = pcall(vim.fn.mkdir, path, 'p')
    if not ok then
        return nil, err
    end
    return path, nil
end

---Normalize a chat filename to a safe markdown filename.
---@param name string|nil
---@return string|nil
function M.sanitize_chat_filename(name)
    local trimmed = util.trim(name or '')
    if trimmed == '' then
        return nil
    end
    local base = vim.fn.fnamemodify(trimmed, ':t')
    if not base:match('%.md$') then
        base = base .. '.md'
    end
    return base
end

---@param path string
---@return string[]|nil
---@return string|nil
function M.list_saved_chats(path)
    if not path or path == '' then
        return nil, 'Chat save directory is not configured.'
    end

    local files = vim.fn.globpath(path, '*.md', false, true)
    if type(files) ~= 'table' then
        return nil, 'Failed to list saved chats in ' .. path
    end

    table.sort(files)
    return files, nil
end

return M
