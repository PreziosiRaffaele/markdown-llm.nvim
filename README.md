# MarkdownLLM

MarkdownLLM is a Neovim plugin that provides a simple interface for interacting with LLM providers.



## Install

Use your plugin manager and load the module in your config:

```lua
require("markdownllm").setup({
  log_level = vim.log.levels.INFO,
  default_setup_name = "default",
  setups = {
    {
      name = "default",
      provider = "openai",
      model = "gpt-4o-mini",
      api_key_name = "OPENAI_API_KEY",
      opts = {},
    },
  },
  presets = {
    { name = "Chat", instruction = "" },
  },
  actions = {},
  keymaps = {
    newChat = "<leader>mn",
    sendChat = "<leader>ms",
    selectBufferSetup = "<leader>mc",
    selectDefaultSetup = "<leader>md",
    editBufferSetup = "<leader>me",
    actions = "<leader>ma",
    saveChat = "<leader>mw",
  },
})
```

## Commands

- `:MarkdownLLMNewChat` open a new chat buffer (optionally with a preset).
- `:MarkdownLLMSendChat` send the current chat buffer to the provider.
- `:MarkdownLLMRunAction` send the current visual selection using an action.
- `:MarkdownLLMSelectBufferSetup` set the setup for the current buffer.
- `:MarkdownLLMSelectDefaultSetup` set the default setup for new buffers.
- `:MarkdownLLMEditBufferSetup` edit the current buffer setup in a floating window.
- `:MarkdownLLMSaveChat` save the current chat buffer to disk.

## Configuration

- `log_level` logger level (default: `vim.log.levels.INFO`).
- `default_setup_name` name of the default setup used for new chats.
- `setups` list of provider/model setups.
- `presets` list of prompt presets (optional instruction + setup name).
- `actions` list of actions used for visual selection prompts.
- `chat_save_dir` directory for saved chats (default: `stdpath("data")/markdownllm/chats`).
- `keymaps` optional command bindings:
  - `newChat`
  - `sendChat`
  - `selectBufferSetup`
  - `selectDefaultSetup`
  - `editBufferSetup`
  - `actions`
  - `saveChat`

## Providers

Built-in providers live under `lua/markdownllm/providers` and are resolved by name:

- `openai`
- `gemini`
- `grok`
