--- Configuration management for MarkdownLLM.
---@module 'markdownllm.config'

local M = {}

local default_config = {
    log_level = vim.log.levels.INFO,
    log_to_file = false,
    log_file_path = vim.fn.stdpath('cache') .. '/markdownllm.log',
    setups = {},
    presets = {},
    actions = {},
    keymaps = {},
    chat_save_dir = vim.fn.stdpath('data') .. '/markdownllm/chats',
}

M.config = vim.deepcopy(default_config)

---Flatten legacy setup options into the top-level setup table.
---@param setup table|nil
---@return table|nil
local function normalize_setup(setup)
    if type(setup) ~= 'table' then
        return setup
    end

    local normalized = vim.deepcopy(setup)
    local opts = normalized.opts
    if type(opts) == 'table' then
        for key, value in pairs(opts) do
            if normalized[key] == nil then
                normalized[key] = value
            end
        end
    end

    normalized.opts = nil
    return normalized
end

---Normalize all configured setups for consistent access.
---@param setups table[]|nil
---@return table[]
local function normalize_setups(setups)
    local normalized_setups = {}
    for _, setup in ipairs(setups or {}) do
        table.insert(normalized_setups, normalize_setup(setup))
    end
    return normalized_setups
end

---Update the configuration state.
---@param opts table|nil
---@return nil
function M.update(opts)
    M.config = vim.tbl_deep_extend('force', vim.deepcopy(default_config), opts or {})
    M.config.setups = normalize_setups(M.config.setups)
end

---Find a setup by name.
---@param name string
---@return table
---@throws string
function M.find_setup(name)
    for _, setup in ipairs(M.config.setups or {}) do
        if setup.name == name then
            return setup
        end
    end
    error('Setup "' .. name .. '" not found in the configured setups.')
end

---Return the list of configured setup names.
---@return string[]
function M.setup_names()
    local names = {}
    for _, setup in ipairs(M.config.setups or {}) do
        table.insert(names, setup.name)
    end
    return names
end

---Get the configured default setup.
---@return table
---@throws string
function M.get_default_setup()
    if not M.config.default_setup_name then
        error('No default setup configured.')
    end
    return M.find_setup(M.config.default_setup_name)
end

---Resolve the setup for a preset or fall back to the default.
---@param preset table|nil
---@return table
---@throws string
function M.resolve_preset_setup_name(preset)
    local setup_name
    if preset and preset.setup and preset.setup ~= '' then
        setup_name = preset.setup
    else
        setup_name = M.config.default_setup_name
    end
    return M.find_setup(setup_name)
end

---Find a preset by name.
---@param name string|nil
---@return table|nil
function M.find_preset(name)
    if not name or name == '' then
        return nil
    end
    for _, preset in ipairs(M.config.presets or {}) do
        if preset.name == name then
            return preset
        end
    end
    return nil
end

return M
