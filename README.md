# MarkdownLLM
**MarkdownLLM** is a Neovim plugin that provides a simple, markdown-driven interface for interacting with LLM providers. 

Recently, there has been a proliferation of LLM interaction tools designed as agents (e.g., cursor, claude-code, codex, gemini-cli). While these tools can accelerate workflows, they often lack clear and explicit control over the context provided to the LLM, they operate as "black boxes".

There is a tendency to trust agent-driven code changes or commands without fully understanding the underlying logic. This can create a disconnect between the human and the AI, hindering the human's learning and potentially leading to a loss of control over the software produced. 

In contrast to agents, when using an LLM through its native web interface, developers tend to assume a more critical approach. The cooperation between the developer and the LLM is more explicit and produces today the best results. 

By bringing LLM conversations into Neovim's native markdown environment, this plugin allows you to have the same critical and iterative dialogue you would have in a web interface, but with the full power of Vim's editing capabilities. 

You can easily add, remove, or modify any part of the conversation. Change system instructions or tweak model parameters on the fly, all with the efficiency of Vim motions!
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
    resumeChat = "<leader>mr",
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
- `:MarkdownLLMResumeChat` resume a saved chat from disk.

Help docs are available in `doc/markdownllm.txt` after running `:helptags`.

## Configuration

- `log_level` logger level (default: `vim.log.levels.INFO`).
- `default_setup_name` name of the default setup used for new chats.
- `setups` list of provider/model setups:
  - `name` unique label used in selectors.
  - `provider` provider name: `openai`, `gemini`, `grok`.
  - `model` model id passed to the provider.
  - `api_key_name` environment variable containing the API key.
  - `base_url` optional override for OpenAI/Grok endpoints.
  - `opts` provider-specific options merged into payload.
- `presets` list of prompt presets used to seed new chats:
  - `name` label shown in the preset selector.
  - `instruction` content injected under the `# System` section.
  - `setup` setup name override; defaults to `default_setup_name`.
- `actions` list of actions used for visual selection prompts:
  - `name` label shown in the action selector.
  - `preset` preset name to open; defaults to the first preset.
  - `type` `text` (default) or `code`; `code` wraps the selection in a fenced code block.
  - `language` optional code fence language when `type = "code"`; defaults to the current buffer filetype.
  - `pre_text` text prepended before the selection.
- `chat_save_dir` directory for saved chats (default: `stdpath("data")/markdownllm/chats`).
- `keymaps` optional command bindings:
  - `newChat`
  - `sendChat`
  - `selectBufferSetup`
  - `selectDefaultSetup`
  - `editBufferSetup`
  - `actions`
  - `saveChat`
  - `resumeChat`

## Providers

Built-in providers live under `lua/markdownllm/providers` and are resolved by name:

- `openai`
- `gemini`
- `grok`

## License

MIT. See `LICENSE`.
