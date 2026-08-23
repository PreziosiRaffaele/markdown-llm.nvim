# MarkdownLLM
**MarkdownLLM** is a Neovim plugin for chatting with LLM providers in a plain Markdown buffer.

Recently, there has been a proliferation of LLM interaction tools designed as agents (e.g., cursor, claude-code, codex, gemini-cli). While these tools can accelerate workflows, they often lack clear and explicit control over the context provided to the LLM, they operate as "black boxes".

There is a tendency to trust agent-driven code changes or commands without fully understanding the underlying logic. This can create a disconnect between the human and the AI, hindering the human's learning and potentially leading to a loss of control over the software produced.

Unlike agent-based systems, interacting with an LLM through its native web interface keeps the human in a clearly leading role, with collaboration being explicit and the developer maintaining a more critical stance.

By bringing LLM chat into Neovim's native markdown environment, this plugin allows you to have the same critical and iterative dialogue you would have in a web interface, but with the full power of Vim's editing capabilities.

## What You Can Do

- Start LLM chats directly inside Neovim
- Edit any part of the conversation before sending again
- Switch provider, model, and options from YAML frontmatter
- Use presets to seed chats with reusable system instructions
- Run actions on visual selections for common text or code transformations
- Save chats to disk and resume them later

Each chat is a Markdown document with editable YAML frontmatter, so the complete context always stays visible and under your control.

## Screenshots

### Chat workflow

Use MarkdownLLM as a regular chat buffer: start a conversation, iterate on it, and edit the context directly when needed.

#### Start a chat

![Start a chat](https://github.com/user-attachments/assets/ec039ce0-3fad-4749-aa45-3ce6ea17c18b)

#### Chat with the LLM

![chat](https://github.com/user-attachments/assets/a1ce2fbe-1507-4520-9a3e-4c839e6cd28d)

#### Edit chat

![Edit chat](https://github.com/user-attachments/assets/eb70df35-6473-46d9-97ff-512ee562e6f6)

### Actions workflow

Actions let you send a visual selection through a predefined prompt, making common text and code transformations faster.

#### Actions

![Actions](https://github.com/user-attachments/assets/6774e729-a8a7-4ed3-8c66-bab84b36d199)


## Install

MarkdownLLM is lightweight, completely written in Lua.
It has no dependencies on other plugins.
The only optional suggestion is to use [render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim) to render markdown in the chat buffer.

Requirements:

- Neovim >= 0.10
- `curl` available on your `PATH`
- An API key for your chosen provider

### 1. Set your provider API key

API keys are read from environment variables at request time. Export the one matching your provider before starting Neovim:

```sh
export OPENAI_API_KEY="sk-..."
# or GEMINI_API_KEY, GROK_API_KEY, DEEPSEEK_API_KEY, ...
```

Add the export line to your shell profile (`~/.zshrc`, `~/.bashrc`, ...) to make it permanent.
The variable name is chosen per setup via the `api_key_name` option.

### 2. Install and configure

For your first chat, define one entry in `setups`, point `default_setup_name` at it, and add one prompt preset.

#### lazy.nvim

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
    default_setup_name = "default",
    setups = {
      {
        name = "default",
        provider = "openai",
        model = "gpt-5.6",
        api_key_name = "OPENAI_API_KEY",
      },
    },
    presets = {
      { name = "Chat", instruction = "" },
    },
  },
}
```

#### Other plugin managers

Add `PreziosiRaffaele/markdown-llm.nvim` (and optionally `MeanderingProgrammer/render-markdown.nvim`) as you normally would, then call the setup function in your config:

```lua
require("markdownllm").setup({
  default_setup_name = "default",
  setups = {
    {
      name = "default",
      provider = "openai",
      model = "gpt-5.6",
      api_key_name = "OPENAI_API_KEY",
    },
  },
  presets = {
    { name = "Chat", instruction = "" },
  },
})
```

Note: if `default_setup_name` does not match one of your setup names, `setup()` shows an error notification and no `:MarkLLM*` commands are registered.

### 3. Start your first chat

1. Run `:MarkLLMNewChat`: a new Markdown buffer opens with YAML frontmatter mirroring your setup.
2. Type your message under `## User`.
3. Run `:MarkLLMSendChat` to stream the response into the buffer.
4. Edit any part of the conversation - frontmatter included - and send again.

That is all you need. Keymaps, additional presets, actions, and multiple providers are optional refinements described below.

### Full configuration example

With lazy.nvim:

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
        model = "gpt-5.6",
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
      stopChat = "<leader>mx",
      selectChatSetup = "<leader>mc",
      selectDefaultSetup = "<leader>md",
      actions = "<leader>ma",
      saveChat = "<leader>mw",
      resumeChat = "<leader>mr",
    },
  },
}
```

With other plugin managers, pass the same `opts` table to `require("markdownllm").setup(opts)`.

## Commands

- `:MarkLLMNewChat` open a new chat buffer (optionally with a preset).
- `:MarkLLMSendChat` send the current chat buffer to the provider.
- `:MarkLLMStop` stop the in-flight chat request for the current buffer.
- `:MarkLLMRunAction` send the current visual selection using a configured action or the built-in `Custom prompt...` flow.
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
  - `temperature`, `max_tokens`, `top_p`, `stop`, `frequency_penalty`, `presence_penalty`, `seed`, `reasoning_effort` model parameters. Set `reasoning_effort = "none"` to strictly request disabled thinking; support depends on the provider and model.
  - `web_search` enable provider web search tool when supported.
  - OpenAI uses the Responses API: `max_tokens` maps to `max_output_tokens`; `stop`, `frequency_penalty`, `presence_penalty`, and `seed` are currently ignored with a warning.
- `presets` list of prompt presets used to seed new chats:
  - `name` label shown in the preset selector.
  - `instruction` content injected under the `# System` section.
  - `setup` setup name override; defaults to `default_setup_name`.
- `actions` list of actions used for visual selection prompts:
  - `name` label shown in the action selector.
  - `preset` preset name to open; defaults to the first preset.
  - `type` `chat` (default) or `replace`.
  - `language` optional code fence language for legacy `type = "code"` compatibility; defaults to the current buffer filetype.
  - `pre_text` text prepended before the selection.
  - legacy aliases `text`, `code`, and `replace_visual` are still accepted and mapped to `chat`, `chat`, and `replace`.
  - unsupported action types now fall back to `chat`.
  - legacy `type = "code"` still forces fenced code rendering.
- `chat_save_dir` directory for saved chats (default: `stdpath("data")/markdownllm/chats`).
- `keymaps` optional command bindings:
  - `newChat`
  - `sendChat`
  - `stopChat`
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
model: gpt-5.6
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
    name = "OpenAI-5.6",
    provider = "openai",
    model = "gpt-5.6",
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
    name = "DeepSeek No Thinking",
    provider = "deepseek",
    model = "deepseek-v4-flash",
    api_key_name = "DEEPSEEK_API_KEY",
    base_url = "https://api.deepseek.com/v1/chat/completions",
    reasoning_effort = "none",
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
    type = "chat",
    pre_text = "Summarize the following text:\n\n",
  },
  {
    name = 'Rewrite',
    preset = 'Grammar Check',
    type = 'replace',
    pre_text = 'Please correct the following text. Return only the revised version without additional comments:',
    shortcut = '<leader>mr',
  },
  {
    name = "Explain Code",
    preset = "Software Development",
    type = "chat",
    language = "lua",
    pre_text = "Explain what this code does:\n\n",
  },
  {
    name = "Traduci",
    preset = "Traduttore Italiano",
    type = "chat",
    pre_text = "Traduci questo testo in italiano:\n\n",
  },
}
```

Notes:
- `type = "replace"` shows a temporary `Replacing...` marker above the target and then replaces the selected text in-place with the model response.
- `shortcut` adds a visual-mode keymap for the action, bypassing the action picker.
- `:MarkLLMRunAction` always adds a built-in `Custom prompt...` entry to the action picker. It uses the default setup, prompts for freeform instructions, then asks whether to run as `chat` or `replace`.
- Legacy `type = "code"` still forces fenced code rendering.

## Providers

The following providers are currently supported:

- `OpenAI (Responses API)`
- `xAI (Responses API)`
- `DeepSeek (chat-completions-compatible)`
- `Google (Gemini)`

`reasoning_effort` is a provider-agnostic option, but its values are not
universally portable. The special value `"none"` means that thinking must be
disabled; MarkdownLLM never substitutes a lower effort or the model default:

- DeepSeek models with the thinking toggle map `"none"` to
  `thinking = { type = "disabled" }` and omit the top-level
  `reasoning_effort` field.
- OpenAI Responses sends `reasoning = { effort = "none" }`. Model support is
  determined by the OpenAI API, and an API rejection is returned as an error.
- Gemini maps `"none"` to `thinkingConfig.thinkingBudget = 0` for recognized
  Gemini 2.5 Flash and Flash-Lite models. Gemini 2.5 Pro, Gemini 3, and unknown
  models are rejected before the request is sent.
- Grok does not currently support disabling reasoning, so `"none"` is rejected
  before the request is sent. Existing supported effort values are unchanged.

Other providers can be added per request. Raise an issue or PR to add a new provider.

## Troubleshooting

### Logs

To enable file logging, set `log_to_file = true` in your plugin configuration and optionally
override `log_file_path`. The default log path is
`stdpath("cache")/markdownllm.log`. To debug API calls, set
`log_level = vim.log.levels.DEBUG` to log request and raw response bodies.

Add these fields to your existing `opts` table, or to the table already passed to `require("markdownllm").setup()`:

```lua
log_level = vim.log.levels.DEBUG,
log_to_file = true,
log_file_path = vim.fn.stdpath("cache") .. "/markdownllm.log",
```

## License

MIT. See `LICENSE`.
