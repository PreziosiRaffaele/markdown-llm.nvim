# MarkdownLLM

Markdown-driven chat buffers for Neovim.

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
  keymaps = {},
})
```

## Commands

- `:MarkdownLLMNew` open a new chat buffer (optionally with a preset).
- `:MarkdownLLMSend` send the current chat buffer to the provider.
- `:MarkdownLLMAction` send the current visual selection using an action.
- `:MarkdownLLMSelectBufferSetup` set the setup for the current buffer.
- `:MarkdownLLMSelectDefaultSetup` set the default setup for new buffers.
- `:MarkdownLLMEditBufferSetup` edit the current buffer setup in a floating window.

## Configuration

- `log_level` logger level (default: `vim.log.levels.INFO`).
- `default_setup_name` name of the default setup used for new chats.
- `setups` list of provider/model setups.
- `presets` list of prompt presets (optional instruction + setup name).
- `actions` list of actions used for visual selection prompts.
- `keymaps` optional command bindings:
  - `newChat`
  - `sendChat`
  - `setups`
  - `actions`

## Providers

Built-in providers live under `lua/markdownllm/providers` and are resolved by name:

- `openai`
- `gemini`
- `grok`

