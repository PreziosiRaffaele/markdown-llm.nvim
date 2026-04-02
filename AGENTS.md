# Repository Guidelines
## Project purpose
This plugin provides a simple, markdown-based chat interface for interacting with LLM providers directly within Neovim. It is not an agent; it is a tool designed to give you, the developer, complete and explicit control over the conversational context.

## Project Structure
```
lua/
└── markdownllm/
    ├── init.lua          # Main plugin file (setup, commands, keymaps)
    ├── config.lua        # Configuration management
    ├── util.lua          # Generic utility functions
    ├── buffer.lua        # Neovim buffer manipulation
    ├── ui.lua            # User interface components (vim.ui, popups)
    ├── fs.lua            # Filesystem operations (saving/loading chats)
    ├── core.lua          # Core application logic and workflows
    ├── logger.lua        # Logging utilities
    └── providers/        # LLM provider implementations
        ├── gemini.lua
        ├── grok.lua
        └── openai.lua
```

## Core Principles
- All modifications to this repository must adhere to the core tenets of the Unix philosophy. The goal is a system composed of small, simple, and well-defined parts that work together effectively.

## LLM Engine Contract
Keep the low-level LLM engine reusable and separate from Neovim UI/buffer workflows.

- **Separation of Concerns**: `llm.lua` orchestrates requests; `core.lua` owns Neovim buffers, UI, and state. Entrypoints should not know provider internals.
- **Template-Method Engine**: The engine defines the flow and delegates provider-specific work via a small driver contract (`spec` and `parse`). The engine owns stream buffering and feeds complete events to `driver.parse`.
- **Callbacks Contract**:
  - `on_error(err)`: fatal; aborts the request and stops streaming.
  - `on_warning(warn)`: non-fatal; streaming continues.
  - `on_chunk(text)`: streaming text fragments.
  - `on_complete()`: called once on successful completion.
- **Request Contract**: Provider-agnostic request shape with `context`, `messages`, and `options`. Drivers map/transform these fields to provider-specific payloads as needed.

### 1. Do One Thing and Do It Well (Single Responsibility Principle)
- **Principle**: Each component should focus on a single, well-defined task.
- **How to Apply This Here**:
    - **Functions**: Lua functions should be small and focused.
    - **Modules**: Lua modules should be small and focused. It is ok to have a larger lua module only if there is an high cohesivity and doesn't make a lot of sense to split in smaller modules.

### 2. Write Programs That Work Together (Composition)
- **Principle**: Expect the output of every program to become the input to another.
- **How to Apply This Here**:
    - **Favor Filters**: Scripts should read from `stdin`, transform data, and write to `stdout`.
    - **Use Pipes**: Prefer chaining standard Unix utilities (`grep`, `sed`, `awk`) over writing a new, complex script.

### 3. Write Programs to Handle Text Streams
- **Principle**: Text streams are a universal interface.
- **How to Apply This Here**:
    - **No Interactive Input**: Scripts should not require interactive user input. Use arguments and `stdin`.
    - **Plain Text Output**: A script's output should be easily parsable plain text.

### 4. Simplicity and Clarity
- **Principle**: Clarity is better than cleverness.
- **How to Apply This Here**:
    - **Readable Code**: Avoid obfuscated one-liners. Prefer readable, well-formatted code.
    - **Comment the "Why"**: Use comments to explain the reasoning behind non-obvious configurations.

### 6. Design for Clear and Simple Interfaces (Lua Modules & Functions)
*   **Principle**: Every Lua function and module should have a predictable contract. It must be obvious what data it requires (arguments), what data it produces (return values), and what changes it makes to the editor's state (side effects).
*   **How to Apply This Here**:
    *   **Document the Contract with Annotations**: At the top of any non-trivial function, use EmmyLua/LDoc style comments to document its interface. This is both human-readable and can be understood by language servers.
    *   **Use Return Values for Data and Errors**:
        *   **Successful data** is the primary return value. A function that calculates something should `return` the result.
        *   **Errors**
            - If the error can be resolved in the method, fix the issue and continue.
            - If the error cannot be resolved:
                - if it breaks abstraction, wrap the error and rethrow it.
                - otherwise, do nothing and bubble up the error. Until reach a point where the error is handled.
    *   **Make Side Effects Obvious and Intentional**:
        *   **A "side effect"** in Neovim is any action that modifies the editor's state. Common examples include:
            *   Setting options (`vim.o`, `vim.bo`, `vim.wo`).
            *   Modifying global variables (`vim.g`).
            *   Creating keymaps (`vim.keymap.set`).
            *   Defining autocommands (`vim.api.nvim_create_autocmd`).
            *   Calling any `vim.api` function that changes buffers, windows, or files.
        *   **Name for the Action**: Functions whose primary purpose is a side effect should have a verb-based name that describes the action (e.g., `setup_lsp`, `apply_keymaps`, `open_scratch_buffer`).

    *   **Separate Queries from Commands (Command-Query Separation)**:
        *   A **Query** is a function that inspects the editor's state without changing it. It should `return` a value and have no side effects.
            *   *Example*: `function get_current_filetype() return vim.bo.filetype end`
        *   A **Command** is a function that causes a side effect. It should be named for its action and should not return data unless it's an indicator of success/failure.
            *   *Example*: `function set_light_theme() ... end`

### 7. Module and Methods Documentation
- Each module needs to have a clear description of its responsibilities; ideally, it should have a single responsibility.
- Each method needs a clear description of what it does, along with descriptions of its inputs and outputs. From the method's documentation, its behavior should be evident.

### 8. Module Layout
- Structure Lua modules in two explicit blocks:
  - local helpers first
  - public `M.*` methods last
- Separate the two blocks with visible banner comments, for example:
```lua
-- ============================================================================
-- Local helpers
-- ============================================================================

-- ============================================================================
-- Public API
-- ============================================================================
```
- Keep internal workflows calling local helpers directly. Do not expose helper functions on `M` unless they are part of the intended public module interface.
