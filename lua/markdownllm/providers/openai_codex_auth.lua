--- Read-only access to the ChatGPT credentials stored by the Codex CLI.
---
--- Responsibilities:
--- - Locate the Codex `auth.json` written by `codex login`.
--- - Return the access token and ChatGPT account id needed by the Codex backend.
--- - Detect expired tokens before a request is sent.
---
--- This module never refreshes or writes credentials: refresh tokens rotate on
--- use, so refreshing here would silently log the Codex CLI out. The Codex CLI
--- refreshes the file itself when it next needs credentials and finds the token
--- near its `exp`.
---@module 'markdownllm.providers.openai_codex_auth'

local M = {}

local JWT_AUTH_CLAIM = 'https://api.openai.com/auth'

-- Treat tokens that expire within this window as expired so a request does not
-- fail mid-stream.
local EXPIRY_MARGIN_SECONDS = 60

local LOGIN_HINT = 'Run `codex login` and choose "Sign in with ChatGPT".'

-- ============================================================================
-- Local helpers
-- ============================================================================

---@param value any
---@return boolean
local function is_non_empty_string(value)
    return type(value) == 'string' and value ~= ''
end

---Resolve the credentials path: explicit file, then $CODEX_HOME, then ~/.codex.
---Uses vim.fs.normalize, which expands only `~` and environment variables;
---vim.fn.expand would also treat `%`, `#`, `<` and wildcards specially.
---@param auth_file string|nil
---@return string
local function resolve_path(auth_file)
    if is_non_empty_string(auth_file) then
        return vim.fs.normalize(auth_file)
    end
    local codex_home = os.getenv('CODEX_HOME')
    if is_non_empty_string(codex_home) then
        return vim.fs.joinpath(vim.fs.normalize(codex_home), 'auth.json')
    end
    return vim.fs.normalize('~/.codex/auth.json')
end

---@param path string
---@return string|nil
local function read_file(path)
    local file = io.open(path, 'r')
    if not file then
        return nil
    end
    local content = file:read('*a')
    file:close()
    return content
end

---Decode the payload of a JWT without verifying its signature.
---The claims are only used for an early expiry check and account lookup; the
---backend still validates the token.
---@param token string
---@return table|nil
local function decode_jwt_payload(token)
    local payload = token:match('^[^.]+%.([^.]+)%.')
    if not payload then
        return nil
    end

    -- JWTs use unpadded base64url; vim.base64 expects padded standard base64.
    payload = payload:gsub('%-', '+'):gsub('_', '/')
    payload = payload .. string.rep('=', (4 - #payload % 4) % 4)

    local ok_base64, json = pcall(vim.base64.decode, payload)
    if not ok_base64 then
        return nil
    end
    local ok_json, claims = pcall(vim.json.decode, json)
    if not ok_json or type(claims) ~= 'table' then
        return nil
    end
    return claims
end

---@param tokens table
---@param claims table|nil
---@return string|nil
local function resolve_account_id(tokens, claims)
    if is_non_empty_string(tokens.account_id) then
        return tokens.account_id
    end
    local auth_claim = claims and claims[JWT_AUTH_CLAIM]
    if type(auth_claim) == 'table' and is_non_empty_string(auth_claim.chatgpt_account_id) then
        return auth_claim.chatgpt_account_id
    end
    return nil
end

-- ============================================================================
-- Public API
-- ============================================================================

---@class markdownllm.OpenAICodexCredentials
---@field access_token string Bearer token for the Codex backend.
---@field account_id string ChatGPT account id sent as `chatgpt-account-id`.
---@field expires_at integer|nil Unix time when the access token expires, when known.

---Read ChatGPT credentials from the Codex CLI auth file. Never modifies the file.
---@param auth_file string|nil Explicit path; defaults to $CODEX_HOME/auth.json or ~/.codex/auth.json.
---@return markdownllm.OpenAICodexCredentials|nil
---@return string|nil error Actionable message when credentials are missing, invalid, or expired.
function M.read(auth_file)
    local path = resolve_path(auth_file)

    local content = read_file(path)
    if not content then
        return nil, 'Codex credentials not found at ' .. path .. '. ' .. LOGIN_HINT
    end

    local ok, auth = pcall(vim.json.decode, content)
    if not ok or type(auth) ~= 'table' then
        return nil, 'Codex credentials at ' .. path .. ' are not valid JSON. ' .. LOGIN_HINT
    end

    local tokens = type(auth.tokens) == 'table' and auth.tokens or {}
    if not is_non_empty_string(tokens.access_token) then
        if is_non_empty_string(auth.OPENAI_API_KEY) then
            return nil,
                'Codex is logged in with an API key, not a ChatGPT subscription. Use provider = "openai" instead.'
        end
        return nil, 'Codex credentials at ' .. path .. ' contain no ChatGPT access token. ' .. LOGIN_HINT
    end

    local claims = decode_jwt_payload(tokens.access_token)
    local account_id = resolve_account_id(tokens, claims)
    if not account_id then
        return nil, 'Codex credentials at ' .. path .. ' contain no ChatGPT account id. ' .. LOGIN_HINT
    end

    local expires_at = claims and tonumber(claims.exp) or nil
    if expires_at and expires_at - EXPIRY_MARGIN_SECONDS <= os.time() then
        -- The Codex CLI refreshes based on the token's exp, but only when it
        -- needs credentials, so ask for an action that contacts OpenAI.
        return nil,
            'Codex access token expired. Refresh it by sending one message in `codex`'
                .. ' (or run `codex login` again), then send again.'
    end

    return {
        access_token = tokens.access_token,
        account_id = account_id,
        expires_at = expires_at,
    }
end

return M
