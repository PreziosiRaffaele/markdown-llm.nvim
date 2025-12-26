# Repository Guidelines
## Project purpose
This plugin provides a simple, markdown-based chat interface for interacting with LLM providers directly within Neovim. It is not an agent; it is a tool designed to give you, the developer, complete and explicit control over the conversational context.
## Core Principles
All modifications to this repository must adhere to the core tenets of the Unix philosophy. The goal is a system composed of small, simple, and well-defined parts that work together effectively.

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
            * For predictable failures use as convention to return values (nil, err[, code])
            * For unexpected failures or impossible states → use error or assert.
            - For exceptional failures use pcall as safety net, especially when you call a function you do not trust completely.
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
