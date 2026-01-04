# Separate LLM Engine from Neovim UI/Buffer Workflows
## LLM Engine
MarkdownLLm has a separate LLM engine for chat-completion requests. The engine can be used by different entrypoints.

## Design Summary
- Add an llm module that can orchestrate a request and can be used by different entrypoints.
- Entrypoints shouldn't need to know about the provider implementation. However they need to specify the provider in the request.
- Define a contract for the request.
- The llm has a template design pattern. There is a single function that orchestrates the request and delegates to provider-specific functions.
- Since most of the providers adhere to openai standards, we can use the same driver implementation for most of them (openai, grok, deepseek)
- Some providers can use different implementation as Antrophic.
- Keep `core.lua` focused on Neovim buffers, UI, and state.
- Include an explicit streaming toggle in the request/setup.

## Template-Method Style Engine
The engine orchestrates a standard flow; providers implement details via a small contract.
The engine owns stream buffering and feeds `driver.parse` complete events (SSE or JSONL),
so providers stay stateless and focus on parsing a single event.

## Callbacks Contract
Callbacks distinguish terminal errors from recoverable issues.
- `on_error(err)`: fatal; the engine aborts the request and stops streaming.
- `on_warning(warn)`: non-fatal; used for recoverable parse issues while streaming continues.
- `on_chunk(text)`: streaming text fragments; called zero or more times.
- `on_complete()`: called once on successful completion.

## Request 
The llm define a clear interface for the request. The request is provider agnostic.

#### 1. Context (`request.context`)
*Meta-information used by the engine for routing, driver selection, and request lifecycle management.*

| Property | Type | Description |
| :--- | :--- | :--- |
| **`provider`** | `string` | The identifier for the service to use (e.g., `"openai"`, `"anthropic"`, `"gemini"`).| 
| **`model`** | `string` | The specific model ID to target (e.g., `"gpt-4-turbo"`, `"claude-3-opus-20240229"`). |
| **`stream`** | `boolean` | If `true`, the engine expects SSE and calls `callbacks.on_chunk` incrementally. |
| **`timeout`** | `integer` | *(Optional)* The timeout in milliseconds for the request connection/read. |

#### 2. Messages (`request.messages`)
*The core payload representing the conversation history. This follows the standard chat-completion format.*

Array of message objects, where each object contains:

| Property | Type | Description |
| :--- | :--- | :--- |
| **`role`** | `string` | The entity sending the message. Common values: `"system"`, `"user"`, `"assistant"`. |
| **`content`** | `string` | The text content of the message. |

> **Note:** For providers that require the system prompt to be a top-level field (like Anthropic), the *driver* is responsible for extracting the `"system"` message from this list and formatting it correctly.

#### 3. Options (`request.options`)
*Standardized hyperparameters supported by the majority of LLM providers. The Driver is responsible for mapping these standard keys to the specific API field names (e.g., mapping `max_tokens` to `max_completion_tokens`).*

| Property | Type | Description |
| :--- | :--- | :--- |
| **`temperature`** | `float` | Controls randomness (0.0 to 2.0). Lower values make output more deterministic; higher values make it more creative. |
| **`max_tokens`** | `integer` | The maximum number of tokens to generate in the response. |
| **`top_p`** | `float` | Nucleus sampling probability (0.0 to 1.0). An alternative to sampling with temperature. |
| **`stop`** | `table` | A list of strings (sequences) where the API will stop generating further tokens. |
| **`frequency_penalty`** | `float` | Penalizes new tokens based on their existing frequency in the text so far (typically -2.0 to 2.0). |
| **`presence_penalty`** | `float` | Penalizes new tokens based on whether they appear in the text so far (typically -2.0 to 2.0). |
| **`seed`** | `integer` | If specified, the system will make a best effort to sample deterministically. |
| **`tools`** | `table` | A list of tool definitions (function calling schemas) available to the model. |


### Example Configuration (Lua)

```lua
local req = {
  context = {
    provider = "openai",
    model = "gpt-4o",
    stream = true,
  },
  messages = {
    { role = "system", content = "You are a concise coding assistant." },
    { role = "user", content = "Explain the Single Responsibility Principle." }
  },
  options = {
    temperature = 0.5,
    max_tokens = 1000,
  }
}
```

### Template Pattern llm.lua
Use a single engine function that defines the algorithm steps and delegates
provider-specific steps to functions on the provider module.
This keeps the algorithm centralized while letting each provider supply the
details via its own functions.

## Class Diagram
```plantuml
@startuml
!theme reddress-darkgreen

class "llm" <<module>> {
    + send(request, callbacks) : abort
}

note left of llm: send the request using **vim.system**

interface "abort" <<function>> {
  + call() : void
}

class "driver_factory" << module >> {
    + get(provider) : driver
}

class "openai" << module >> {
    + new(api_key, base_url) : driver
}
class "gemini" << module >> {
    + new(api_key) : driver
}

class "driver" <<table>> {
    + spec(request) : {url, headers, body} 
    + parse(chunk) : string
}

class "request" <<table>> {
    + context: {provider, model, stream}
    + messages: [{role, content}]
    + options: {temp, top_p, ...}
}

' Relationships
llm ..> request : uses
llm ..> abort : returns
llm ..> driver_factory : uses

openai ..> driver : returns
gemini ..> driver : returns

driver_factory ..> openai : uses
driver_factory ..> gemini : uses

driver_factory ..> driver : returns

@enduml
```
