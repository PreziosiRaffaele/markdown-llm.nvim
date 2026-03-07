# MarkdownLLM
**MarkdownLLM** is a Neovim plugin that provides a simple, markdown-driven interface for interacting with LLM providers. 

Recently, there has been a proliferation of LLM interaction tools designed as agents (e.g., cursor, claude-code, codex, gemini-cli). While these tools can accelerate workflows, they often lack clear and explicit control over the context provided to the LLM, they operate as "black boxes".

There is a tendency to trust agent-driven code changes or commands without fully understanding the underlying logic. This can create a disconnect between the human and the AI, hindering the human's learning and potentially leading to a loss of control over the software produced. 

Unlike agent-based systems, interacting with an LLM through its native web interface keeps the human in a clearly leading role, with collaboration being explicit and the developer maintaining a more critical stance.

By bringing LLM chat into Neovim's native markdown environment, this plugin allows you to have the same critical and iterative dialogue you would have in a web interface, but with the full power of Vim's editing capabilities. 

You can easily add, remove, or modify any part of the conversation, giving you **full control over the context**. Change system instructions or tweak model parameters on the fly, all with the efficiency of Vim motions!

## Demo
<!-- Demo source: https://github.com/user-attachments/assets/5d08506d-e3eb-4a7f-a7aa-117bee2a055f -->
https://github.com/user-attachments/assets/5d08506d-e3eb-4a7f-a7aa-117bee2a055f

## Install

MarkdownLLM is lightweight completely written in Lua. 
It has no dependencies on other plugins.
Requires Neovim >= 0.10.
The only optional suggestion is to use [render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim) to render markdown in the chat buffer.

### lazy.nvim

```lua
{
  "PreziosiRaffaele/markdown-llm.nvim",
  -- optional markdown renderer
  dependencies = {
    {
      "MeanderingProgrammer/render-markdown.nvim",
    },
  },
  opts = {
    log_level = vim.log.levels.INFO,
    default_setup_name = "default",
    setups = {
      {
        name = "default",
        provider = "openai",
        model = "gpt-5.2",
        api_key_name = "OPENAI_API_KEY",
      },
    },
    presets = {
      { name = "Chat", instruction = "" },
    },
    actions = {},
    keymaps = {
      newChat = "<leader>mn",
      sendChat = "<leader>ms",
      selectChatSetup = "<leader>mc",
      selectDefaultSetup = "<leader>md",
      actions = "<leader>ma",
      saveChat = "<leader>mw",
      resumeChat = "<leader>mr",
    },
  },
}
```

### Other plugin managers

Add `PreziosiRaffaele/markdown-llm.nvim` (and optionally `MeanderingProgrammer/render-markdown.nvim`) as you normally would, then call the setup function in your config:

```lua
require("markdownllm").setup({
  log_level = vim.log.levels.INFO,
  default_setup_name = "default",
  setups = {
    {
      name = "default",
      provider = "openai",
      model = "gpt-5.2",
      api_key_name = "OPENAI_API_KEY",
    },
  },
  presets = {
    { name = "Chat", instruction = "" },
  },
  actions = {},
  keymaps = {
    newChat = "<leader>mn",
    sendChat = "<leader>ms",
    selectChatSetup = "<leader>mc",
    selectDefaultSetup = "<leader>md",
    actions = "<leader>ma",
    saveChat = "<leader>mw",
    resumeChat = "<leader>mr",
  },
})
```

## Commands

- `:MarkLLMNewChat` open a new chat buffer (optionally with a preset).
- `:MarkLLMSendChat` send the current chat buffer to the provider.
- `:MarkLLMRunAction` send the current visual selection using an action.
- `:MarkLLMSelectBufferSetup` set the setup for the current buffer.
- `:MarkLLMSelectDefaultSetup` set the default setup for new buffers.
- `:MarkLLMSaveChat` save the current chat buffer to disk.
- `:MarkLLMResumeChat` resume a saved chat from disk.

Help docs are available in `doc/markdownllm.txt` after running `:helptags`.

## Configuration

- `log_level` logger level (default: `vim.log.levels.INFO`).
- `log_to_file` enable logging to file (default: `false`).
- `log_file_path` log file path (default: `stdpath("cache")/markdownllm.log`).
- `default_setup_name` name of the default setup used for new chats.
- `setups` list of provider/model setups:
  - `name` unique label used in selectors.
  - `provider` provider name: `openai`, `gemini`, `grok`, `deepseek`.
  - `model` model id passed to the provider.
  - `api_key_name` environment variable containing the API key.
  - `base_url` optional override for the selected provider endpoint.
  - `timeout` optional request timeout in milliseconds.
  - `temperature`, `max_tokens`, `top_p`, `stop`, `frequency_penalty`, `presence_penalty`, `seed`, `reasoning_effort` model parameters.
  - `web_search` enable provider web search tool when supported.
  - OpenAI uses the Responses API: `max_tokens` maps to `max_output_tokens`; `stop`, `frequency_penalty`, `presence_penalty`, and `seed` are currently ignored with a warning.
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
  - `selectChatSetup`
  - `selectDefaultSetup`
  - `actions`
  - `saveChat`
- `resumeChat`

## Chat YAML frontmatter

Each chat buffer starts with YAML frontmatter that mirrors the setup. Edit it directly to change providers or model options:

```yaml
---
provider: openai
model: gpt-5.2
api_key_name: OPENAI_API_KEY
temperature: 0.2
max_tokens: 800
reasoning_effort: xhigh
---
```

## Configuration Examples

### Multiple setups (providers + model options)

```lua
setups = {
  {
    name = "OpenAI-5.2",
    provider = "openai",
    model = "gpt-5.2",
    api_key_name = "OPENAI_API_KEY",
    reasoning_effort = "xhigh"
  },
  {
    name = "Gemini-2.5-flash",
    provider = "gemini",
    model = "gemini-2.5-flash",
    api_key_name = "GEMINI_API_KEY",
  },
  {
    name = "Grok Code Fast",
    provider = "grok",
    model = "grok-code-fast-1",
    api_key_name = "GROK_API_KEY",
  },
  {
    name = "DeepSeek Chat",
    provider = "deepseek",
    model = "deepseek-chat",
    api_key_name = "DEEPSEEK_API_KEY",
    base_url = "https://api.deepseek.com/v1/chat/completions",
  },
  {
    name = "Gemini-2.5-pro",
    provider = "gemini",
    model = "gemini-2.5-pro",
    api_key_name = "GEMINI_API_KEY",
    web_search = true,
  },
}
```

### Presets (system instructions + default setup)

```lua
presets = {
  {
    name = "Chat",
    instruction = "",
  },
  {
    name = "Software Development",
    instruction = "You are an expert software developer and architect. Favor the Unix philosophy. Ask clarifying questions when requirements are ambiguous. Propose tradeoffs before making architectural choices.",
  },
  {
    name = "Geopolitics",
    instruction = "You are an expert geopolitics analyst and educator. Explain geopolitics topics clearly and neutrally for an intelligent, non-specialist audience.",
  },
  {
    name = "Traduttore Italiano",
    setup = "Gemini-2.5-flash", -- Setup Name Override
    instruction = "You are an Italian native speaker and translator. Write natural Italian and preserve the original meaning.",
  },
  {
    name = 'Grammar Check',
    instruction = 'You are a professional editor. Follow these rules: 1. Correct grammar and punctuation 2. Improve clarity and readability 3. Maintain the original tone and intent 4. Keep the same format (lists stay lists, etc.) 5. Don\'t add explanations or comments',
    setup = 'Gemini-2.5-flash',
  },
}
```

### Actions (visual selection prompts)

```lua
actions = {
  {
    name = "Summarize",
    preset = "Chat",
    type = "text",
    pre_text = "Summarize the following text:\n\n",
  },
  {
    name = 'Rewrite',
    preset = 'Grammar Check',
    type = 'replace_visual',
    pre_text = 'Please correct the following text. Return only the revised version without additional comments:',
    shortcut = '<leader>mr',
  },
  {
    name = "Explain Code",
    preset = "Software Development",
    type = "code",
    language = "lua",
    pre_text = "Explain what this code does:\n\n",
  },
  {
    name = "Traduci",
    preset = "Traduttore Italiano",
    type = "text",
    pre_text = "Traduci questo testo in italiano:\n\n",
  },
}
```

Notes:
- `type = "replace_visual"` replaces the selected text in-place with the model response.
- `shortcut` adds a visual-mode keymap for the action, bypassing the action picker.

## Providers

The following providers are currently supported:

- `OpenAI (Responses API)`
- `xAI (Responses API)`
- `DeepSeek (chat-completions-compatible)`
- `Google (Gemini)`

Other providers can be added per request. Raise an issue or PR to add a new provider.

## Troubleshooting

### Logs

To enable file logging, set `log_to_file = true` in your setup and optionally
override `log_file_path`. The default log path is
`stdpath("cache")/markdownllm.log`. To debug API calls, set
`log_level = vim.log.levels.DEBUG` to log request and raw response bodies.

Example:

```lua
require("markdownllm").setup({
  log_level = vim.log.levels.DEBUG,
  log_to_file = true,
  log_file_path = vim.fn.stdpath("cache") .. "/markdownllm.log",
})
```

## License

MIT. See `LICENSE`.
