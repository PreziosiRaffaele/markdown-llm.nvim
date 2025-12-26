local M = {}

local default_config = {
    -- The lowest log level to process.
    -- Available levels: TRACE, DEBUG, INFO, WARN, ERROR, OFF
    level = vim.log.levels.INFO,
    -- Whether to output logs to a file.
    log_to_file = false,
    -- The path to the log file.
    log_file_path = vim.fn.stdpath('cache') .. '/markdownllm.log',
    -- Whether to display logs using vim.notify().
    log_to_notify = true,
}

local config = vim.deepcopy(default_config)

local level_names = {
    [vim.log.levels.TRACE] = 'TRACE',
    [vim.log.levels.DEBUG] = 'DEBUG',
    [vim.log.levels.INFO] = 'INFO',
    [vim.log.levels.WARN] = 'WARN',
    [vim.log.levels.ERROR] = 'ERROR',
}

--- Update the logger configuration.
--- @param opts table|nil
--- @return nil
function M.configure(opts)
    config = vim.tbl_deep_extend('force', vim.deepcopy(default_config), opts or {})
end

local function format_message(msg_parts)
    local formatted_parts = {}
    for _, part in ipairs(msg_parts) do
        if type(part) == 'table' then
            table.insert(formatted_parts, vim.inspect(part))
        else
            table.insert(formatted_parts, tostring(part))
        end
    end
    return table.concat(formatted_parts, ' ')
end

local function log(level, msg_parts)
    if level < config.level then
        return
    end

    local level_name = level_names[level]
    local msg_str = format_message(msg_parts)
    local final_msg = string.format('[%s] %s', level_name, msg_str)

    if config.log_to_notify then
        vim.notify(final_msg, level)
    end

    if config.log_to_file then
        local file = io.open(config.log_file_path, 'a')
        if file then
            file:write(os.date('%Y-%m-%d %H:%M:%S') .. ' ' .. final_msg .. '\n')
            file:close()
        else
            vim.notify('Error: Could not open log file: ' .. config.log_file_path, vim.log.levels.ERROR)
        end
    end
end

function M.trace(...)
    log(vim.log.levels.TRACE, { ... })
end

function M.debug(...)
    log(vim.log.levels.DEBUG, { ... })
end

function M.info(...)
    log(vim.log.levels.INFO, { ... })
end

function M.warn(...)
    log(vim.log.levels.WARN, { ... })
end

function M.error(...)
    log(vim.log.levels.ERROR, { ... })
end

return M
