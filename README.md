# MarkdownLLM
**MarkdownLLM** is a Neovim plugin that provides a simple, markdown-driven interface for interacting with LLM providers. 

Recently, there has been a proliferation of LLM interaction tools designed as agents (e.g., cursor, claude-code, codex, gemini-cli). While these tools can accelerate workflows, they often lack clear and explicit control over the context provided to the LLM, they operate as "black boxes".

There is a tendency to trust agent-driven code changes or commands without fully understanding the underlying logic. This can create a disconnect between the human and the AI, hindering the human's learning and potentially leading to a loss of control over the software produced. 

In contrast to agents, when using an LLM through its native web interface, developers tend to assume a more critical approach. The cooperation between the developer and the LLM is more explicit and produces today the best results. 

By bringing LLM conversations into Neovim's native markdown environment, this plugin allows you to have the same critical and iterative dialogue you would have in a web interface, but with the full power of Vim's editing capabilities. 

You can easily add, remove, or modify any part of the conversation. Change system instructions or tweak model parameters on the fly, all with the efficiency of Vim motions!

## Demo
<!-- Demo source: https://github.com/user-attachments/assets/ca69bccd-6b32-4f56-b23d-719a20b93ddf -->
https://github.com/user-attachments/assets/ca69bccd-6b32-4f56-b23d-719a20b93ddf

## Install

MarkdownLLM is lightweight and has no required dependencies. The only optional suggestion is a markdown renderer for nicer in-editor output.

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
      selectChatSetup = "<leader>mc",
      selectDefaultSetup = "<leader>md",
      editChatSetup = "<leader>me",
      actions = "<leader>ma",
      saveChat = "<leader>mw",
      resumeChat = "<leader>mr",
    },
  },
}
```

### vim.pack (Neovim 0.10+)

```lua
vim.pack.add({
  { "PreziosiRaffaele/markdown-llm.nvim" },
  { "MeanderingProgrammer/render-markdown.nvim" },
})

require("markdownllm").setup({
  log_level = vim.log.levels.INFO,
  default_setup_name = "default",
  setups = {
    {
      name = "default",
      provider = "openai",
      model = "gpt-5.2",
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
    selectChatSetup = "<leader>mc",
    selectDefaultSetup = "<leader>md",
    editChatSetup = "<leader>me",
    actions = "<leader>ma",
    saveChat = "<leader>mw",
    resumeChat = "<leader>mr",
  },
})
```

### packer.nvim

```lua
require("packer").startup(function(use)
  use({
    "PreziosiRaffaele/markdown-llm.nvim",
    requires = {
      { "MeanderingProgrammer/render-markdown.nvim" },
    },
    config = function()
      require("markdownllm").setup({
        log_level = vim.log.levels.INFO,
        default_setup_name = "default",
        setups = {
          {
            name = "default",
            provider = "openai",
            model = "gpt-5.2",
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
          selectChatSetup = "<leader>mc",
          selectDefaultSetup = "<leader>md",
          editChatSetup = "<leader>me",
          actions = "<leader>ma",
          saveChat = "<leader>mw",
          resumeChat = "<leader>mr",
        },
      })
    end,
  })
end)
```

## Commands

- `:MarkLLMNewChat` open a new chat buffer (optionally with a preset).
- `:MarkLLMSendChat` send the current chat buffer to the provider.
- `:MarkLLMRunAction` send the current visual selection using an action.
- `:MarkLLMSelectBufferSetup` set the setup for the current buffer.
- `:MarkLLMSelectDefaultSetup` set the default setup for new buffers.
- `:MarkLLMEditChatSetup` edit the current chat setup in a floating window.
- `:MarkLLMSaveChat` save the current chat buffer to disk.
- `:MarkLLMResumeChat` resume a saved chat from disk.

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
  - `editChatSetup`
  - `actions`
  - `saveChat`
  - `resumeChat`

## Configuration Examples

### Multiple setups (providers + model options)

```lua
setups = {
  {
    name = "OpenAI-5.2",
    provider = "openai",
    model = "gpt-5.2",
    api_key_name = "OPENAI_API_KEY",
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
    name = "Gemini-2.5-pro",
    provider = "gemini",
    model = "gemini-2.5-pro",
    api_key_name = "GEMINI_API_KEY",
    opts = {
      tools = {
        {
          -- Enable Gemini web search tool by default
          google_search = vim.empty_dict(),
        },
      },
    },
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

## Providers

Built-in providers live under `lua/markdownllm/providers` and are resolved by name:

- `openai`
- `gemini`
- `grok`

## License

MIT. See `LICENSE`.
