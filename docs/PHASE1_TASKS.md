# Fermix Phase 1 — Task Breakdown

**Scope:** MVP Telegram bot with OpenAI provider, basic agent loop, basic tools  
**Goal:** Single-agent Telegram bot that can chat and use shell/file/memory tools  
**Duration:** 2-3 weeks

---

## Task 1: Umbrella App Scaffold

**Description:** Create the Elixir umbrella app structure with four child apps.

**Files to create:**
- `mix.exs` (umbrella root)
- `apps/fermix_core/mix.exs`
- `apps/fermix_channels/mix.exs`
- `apps/fermix_web/mix.exs`
- `apps/fermix_nif/mix.exs`

**Implementation:**

```bash
# Run these commands in /Users/sujshe/projects/fermix
mix new . --umbrella
cd apps
mix new fermix_core --sup
mix new fermix_channels
mix phx.new fermix_web --no-ecto --no-mailer --no-dashboard
mix new fermix_nif
```

**Root mix.exs:**

```elixir
# mix.exs
defmodule Fermix.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: releases()
    ]
  end

  defp deps do
    []
  end

  defp aliases do
    [
      setup: ["deps.get", "cmd mix setup"],
      test: ["test --cover"],
      "format.all": ["format", "cmd --app fermix_core mix format", "cmd --app fermix_channels mix format"],
      quality: ["format --check-formatted", "credo --strict", "dialyzer"]
    ]
  end

  defp releases do
    [
      fermix: [
        applications: [
          fermix_core: :permanent,
          fermix_channels: :permanent,
          fermix_web: :permanent,
          fermix_nif: :permanent
        ],
        include_executables_for: [:unix],
        steps: [:assemble, :tar]
      ]
    ]
  end
end
```

**apps/fermix_core/mix.exs:**

```elixir
defmodule FermixCore.MixProject do
  use Mix.Project

  def project do
    [
      app: :fermix_core,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: dialyzer()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {FermixCore.Application, []}
    ]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp dialyzer do
    [
      plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
      plt_add_apps: [:mix, :ex_unit]
    ]
  end
end
```

**apps/fermix_channels/mix.exs:**

```elixir
defmodule FermixChannels.MixProject do
  use Mix.Project

  def project do
    [
      app: :fermix_channels,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:fermix_core, in_umbrella: true},
      {:fermix_nif, in_umbrella: true},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:plug, "~> 1.16"}
    ]
  end
end
```

**Dependencies:** None  
**Effort:** 30 minutes

---

## Task 2: Config System

**Description:** Set up runtime configuration for API keys, webhook URLs, and app config.

**Files to create:**
- `config/config.exs`
- `config/dev.exs`
- `config/test.exs`
- `config/prod.exs`
- `config/runtime.exs`

**Implementation:**

```elixir
# config/config.exs
import Config

config :fermix_core,
  providers: [
    openai: [
      base_url: "https://api.openai.com/v1",
      default_model: "gpt-4o-mini",
      default_temperature: 0.7
    ]
  ],
  max_conversation_history: 50,
  context_window_limit: 120_000

config :fermix_channels,
  telegram: [
    enabled: true,
    webhook_path: "/webhook/telegram"
  ]

# Import environment-specific config
import_config "#{config_env()}.exs"
```

```elixir
# config/dev.exs
import Config

config :logger, level: :debug

config :fermix_web, FermixWeb.Endpoint,
  http: [port: 4000],
  debug_errors: true,
  code_reloader: true,
  check_origin: false
```

```elixir
# config/test.exs
import Config

config :logger, level: :warning

config :fermix_web, FermixWeb.Endpoint,
  http: [port: 4002],
  server: false
```

```elixir
# config/prod.exs
import Config

config :logger, level: :info

config :fermix_web, FermixWeb.Endpoint,
  http: [port: {:system, "PORT"}],
  server: true,
  secret_key_base: {:system, "SECRET_KEY_BASE"}
```

```elixir
# config/runtime.exs
import Config

if config_env() == :prod do
  config :fermix_core,
    providers: [
      openai: [
        api_key: System.fetch_env!("OPENAI_API_KEY")
      ]
    ]

  config :fermix_channels,
    telegram: [
      bot_token: System.fetch_env!("TELEGRAM_BOT_TOKEN"),
      webhook_secret: System.get_env("TELEGRAM_WEBHOOK_SECRET")
    ]
else
  # Dev/test: allow .env file or fallback
  config :fermix_core,
    providers: [
      openai: [
        api_key: System.get_env("OPENAI_API_KEY", "")
      ]
    ]

  config :fermix_channels,
    telegram: [
      bot_token: System.get_env("TELEGRAM_BOT_TOKEN", ""),
      webhook_secret: System.get_env("TELEGRAM_WEBHOOK_SECRET")
    ]
end
```

**Dependencies:** Task 1  
**Effort:** 30 minutes

---

## Task 3: Tool Behaviour and Registry

**Description:** Define the Tool behaviour that all tools implement, plus a registry.

**Files to create:**
- `apps/fermix_core/lib/fermix_core/tools/tool.ex`
- `apps/fermix_core/lib/fermix_core/tools/registry.ex`

**Implementation:**

```elixir
# apps/fermix_core/lib/fermix_core/tools/tool.ex
defmodule FermixCore.Tools.Tool do
  @moduledoc """
  Behaviour for all tool implementations.

  Tools are functions that the agent can call during conversation loops.
  Each tool must provide a JSON Schema for its parameters and execute
  with the given arguments.
  """

  @type tool_result :: %{
          success: boolean(),
          output: String.t(),
          error: String.t() | nil
        }

  @type context :: %{
          agent_name: String.t(),
          conversation_key: term(),
          optional(atom()) => term()
        }

  @doc "Returns the tool's unique name (e.g., \"shell\", \"file_read\")"
  @callback name() :: String.t()

  @doc "Returns a human-readable description of what the tool does"
  @callback description() :: String.t()

  @doc "Returns the JSON Schema for the tool's parameters"
  @callback parameters() :: map()

  @doc "Executes the tool with the given arguments and context"
  @callback execute(map(), context()) :: {:ok, tool_result()} | {:error, term()}

  @doc """
  Formats a tool for LLM provider consumption.
  Returns OpenAI-compatible function calling format.
  """
  @spec format_for_llm(module()) :: map()
  def format_for_llm(tool_module) do
    %{
      type: "function",
      function: %{
        name: tool_module.name(),
        description: tool_module.description(),
        parameters: tool_module.parameters()
      }
    }
  end

  @doc """
  Builds a success result with output.
  """
  @spec success(String.t()) :: tool_result()
  def success(output) when is_binary(output) do
    %{success: true, output: output, error: nil}
  end

  @doc """
  Builds an error result.
  """
  @spec error(String.t()) :: tool_result()
  def error(message) when is_binary(message) do
    %{success: false, output: "", error: message}
  end
end
```

```elixir
# apps/fermix_core/lib/fermix_core/tools/registry.ex
defmodule FermixCore.Tools.Registry do
  @moduledoc """
  Central registry of all available tools.
  """

  alias FermixCore.Tools.{Shell, FileRead, FileWrite, MemoryStore, MemoryRecall}

  @tools [
    Shell,
    FileRead,
    FileWrite,
    MemoryStore,
    MemoryRecall
  ]

  @doc "Returns all registered tool modules"
  @spec all_tools() :: [module()]
  def all_tools, do: @tools

  @doc "Returns all tools formatted for LLM consumption"
  @spec all_tools_for_llm() :: [map()]
  def all_tools_for_llm do
    Enum.map(@tools, &FermixCore.Tools.Tool.format_for_llm/1)
  end

  @doc "Find a tool module by name"
  @spec find_tool(String.t()) :: {:ok, module()} | :error
  def find_tool(name) do
    case Enum.find(@tools, fn tool -> tool.name() == name end) do
      nil -> :error
      tool -> {:ok, tool}
    end
  end
end
```

**RustyClaw reference:** None (new abstraction)  
**Dependencies:** Task 1  
**Effort:** 45 minutes

---

## Task 4: Basic Tools — Shell

**Description:** Implement the `shell` tool for executing system commands.

**Files to create:**
- `apps/fermix_core/lib/fermix_core/tools/shell.ex`

**Implementation:**

```elixir
# apps/fermix_core/lib/fermix_core/tools/shell.ex
defmodule FermixCore.Tools.Shell do
  @moduledoc """
  Execute shell commands. Supports working directory, timeout, and environment variables.
  """

  @behaviour FermixCore.Tools.Tool

  alias FermixCore.Tools.Tool

  @impl true
  def name, do: "shell"

  @impl true
  def description do
    """
    Execute a shell command and return its output.
    Use for file operations, git commands, system queries, etc.
    """
  end

  @impl true
  def parameters do
    %{
      type: "object",
      required: ["command"],
      properties: %{
        command: %{
          type: "string",
          description: "The shell command to execute"
        },
        working_dir: %{
          type: "string",
          description: "Working directory (defaults to current directory)"
        },
        timeout_ms: %{
          type: "integer",
          description: "Timeout in milliseconds (default: 30000)"
        }
      }
    }
  end

  @impl true
  def execute(args, _context) do
    command = Map.fetch!(args, "command")
    working_dir = Map.get(args, "working_dir", File.cwd!())
    timeout = Map.get(args, "timeout_ms", 30_000)

    # Security: basic validation
    with :ok <- validate_command(command),
         :ok <- validate_working_dir(working_dir) do
      run_command(command, working_dir, timeout)
    else
      {:error, reason} -> {:ok, Tool.error(reason)}
    end
  end

  defp validate_command(command) when is_binary(command) and byte_size(command) > 0, do: :ok
  defp validate_command(_), do: {:error, "Command must be a non-empty string"}

  defp validate_working_dir(dir) do
    if File.dir?(dir) do
      :ok
    else
      {:error, "Working directory does not exist: #{dir}"}
    end
  end

  defp run_command(command, working_dir, timeout) do
    case System.cmd("sh", ["-c", command],
           cd: working_dir,
           stderr_to_stdout: true,
           timeout: timeout
         ) do
      {output, 0} ->
        {:ok, Tool.success(output)}

      {output, exit_code} ->
        {:ok, Tool.error("Command failed (exit code #{exit_code}):\n#{output}")}
    end
  rescue
    e in ErlangError ->
      cond do
        Exception.message(e) =~ "timeout" ->
          {:ok, Tool.error("Command timed out after #{timeout}ms")}

        true ->
          {:ok, Tool.error("Command execution failed: #{Exception.message(e)}")}
      end
  end
end
```

**RustyClaw reference:** `/Users/sujshe/projects/rustyclaw/src/tools/shell.rs` (patterns for timeout, working_dir)  
**Dependencies:** Task 3  
**Effort:** 1 hour

---

## Task 5: Basic Tools — File Read/Write

**Description:** Implement `file_read` and `file_write` tools.

**Files to create:**
- `apps/fermix_core/lib/fermix_core/tools/file_read.ex`
- `apps/fermix_core/lib/fermix_core/tools/file_write.ex`

**Implementation:**

```elixir
# apps/fermix_core/lib/fermix_core/tools/file_read.ex
defmodule FermixCore.Tools.FileRead do
  @moduledoc """
  Read file contents. Supports offset/limit for large files.
  """

  @behaviour FermixCore.Tools.Tool

  alias FermixCore.Tools.Tool

  @impl true
  def name, do: "file_read"

  @impl true
  def description do
    "Read the contents of a file. Supports line offset and limit for large files."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      required: ["path"],
      properties: %{
        path: %{
          type: "string",
          description: "Path to the file to read"
        },
        offset: %{
          type: "integer",
          description: "Line number to start reading from (1-indexed, default: 1)"
        },
        limit: %{
          type: "integer",
          description: "Maximum number of lines to read (default: all)"
        }
      }
    }
  end

  @impl true
  def execute(args, _context) do
    path = Map.fetch!(args, "path")
    offset = Map.get(args, "offset", 1)
    limit = Map.get(args, "limit")

    with :ok <- validate_path(path),
         {:ok, content} <- File.read(path) do
      lines = String.split(content, "\n")
      result = slice_lines(lines, offset, limit)
      {:ok, Tool.success(Enum.join(result, "\n"))}
    else
      {:error, :enoent} ->
        {:ok, Tool.error("File not found: #{path}")}

      {:error, :eisdir} ->
        {:ok, Tool.error("Path is a directory: #{path}")}

      {:error, reason} ->
        {:ok, Tool.error("Failed to read file: #{inspect(reason)}")}
    end
  end

  defp validate_path(path) when is_binary(path) and byte_size(path) > 0, do: :ok
  defp validate_path(_), do: {:error, "Path must be a non-empty string"}

  defp slice_lines(lines, offset, nil) do
    Enum.drop(lines, offset - 1)
  end

  defp slice_lines(lines, offset, limit) do
    lines
    |> Enum.drop(offset - 1)
    |> Enum.take(limit)
  end
end
```

```elixir
# apps/fermix_core/lib/fermix_core/tools/file_write.ex
defmodule FermixCore.Tools.FileWrite do
  @moduledoc """
  Write content to a file. Creates parent directories if needed.
  """

  @behaviour FermixCore.Tools.Tool

  alias FermixCore.Tools.Tool

  @impl true
  def name, do: "file_write"

  @impl true
  def description do
    "Write content to a file. Creates the file if it doesn't exist, overwrites if it does."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      required: ["path", "content"],
      properties: %{
        path: %{
          type: "string",
          description: "Path to the file to write"
        },
        content: %{
          type: "string",
          description: "Content to write to the file"
        },
        create_dirs: %{
          type: "boolean",
          description: "Create parent directories if they don't exist (default: true)"
        }
      }
    }
  end

  @impl true
  def execute(args, _context) do
    path = Map.fetch!(args, "path")
    content = Map.fetch!(args, "content")
    create_dirs = Map.get(args, "create_dirs", true)

    with :ok <- validate_path(path) do
      if create_dirs do
        path |> Path.dirname() |> File.mkdir_p!()
      end

      case File.write(path, content) do
        :ok ->
          byte_size = byte_size(content)
          {:ok, Tool.success("Wrote #{byte_size} bytes to #{path}")}

        {:error, reason} ->
          {:ok, Tool.error("Failed to write file: #{inspect(reason)}")}
      end
    else
      {:error, reason} -> {:ok, Tool.error(reason)}
    end
  end

  defp validate_path(path) when is_binary(path) and byte_size(path) > 0, do: :ok
  defp validate_path(_), do: {:error, "Path must be a non-empty string"}
end
```

**RustyClaw reference:** `/Users/sujshe/projects/rustyclaw/src/tools/file_ops.rs`  
**Dependencies:** Task 3  
**Effort:** 1 hour

---

## Task 6: ConversationStore — Per-Chat History

**Description:** GenServer to store conversation history per chat, with compaction support.

**Files to create:**
- `apps/fermix_core/lib/fermix_core/memory/conversation_store.ex`

**Implementation:**

```elixir
# apps/fermix_core/lib/fermix_core/memory/conversation_store.ex
defmodule FermixCore.Memory.ConversationStore do
  @moduledoc """
  Stores conversation history per chat.

  Each conversation is keyed by {channel, chat_id}.
  Maintains a rolling window of messages with automatic compaction.
  """

  use GenServer

  require Logger

  @type conversation_key :: {channel :: String.t(), chat_id :: String.t()}
  @type message :: %{
          role: String.t(),
          content: String.t(),
          timestamp: DateTime.t()
        }

  @max_messages_default 50

  ## Client API

  @doc "Start the conversation store"
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Add a message to a conversation"
  @spec add_message(conversation_key(), String.t(), String.t()) :: :ok
  def add_message(conversation_key, role, content) do
    GenServer.cast(__MODULE__, {:add_message, conversation_key, role, content})
  end

  @doc "Get conversation history (most recent first)"
  @spec get_history(conversation_key(), pos_integer()) :: [message()]
  def get_history(conversation_key, limit \\ @max_messages_default) do
    GenServer.call(__MODULE__, {:get_history, conversation_key, limit})
  end

  @doc "Clear a conversation's history"
  @spec clear(conversation_key()) :: :ok
  def clear(conversation_key) do
    GenServer.cast(__MODULE__, {:clear, conversation_key})
  end

  @doc "Get all active conversation keys"
  @spec list_conversations() :: [conversation_key()]
  def list_conversations do
    GenServer.call(__MODULE__, :list_conversations)
  end

  ## GenServer Callbacks

  @impl true
  def init(_opts) do
    # State: %{conversation_key => [message, ...]}
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:add_message, key, role, content}, state) do
    message = %{
      role: role,
      content: content,
      timestamp: DateTime.utc_now()
    }

    messages = Map.get(state, key, [])
    updated = [message | messages] |> Enum.take(@max_messages_default)

    {:noreply, Map.put(state, key, updated)}
  end

  def handle_cast({:clear, key}, state) do
    {:noreply, Map.delete(state, key)}
  end

  @impl true
  def handle_call({:get_history, key, limit}, _from, state) do
    messages =
      state
      |> Map.get(key, [])
      |> Enum.take(limit)
      |> Enum.reverse()

    {:reply, messages, state}
  end

  def handle_call(:list_conversations, _from, state) do
    {:reply, Map.keys(state), state}
  end
end
```

**RustyClaw reference:** None (new for Fermix)  
**Dependencies:** Task 1  
**Effort:** 1 hour

---

## Task 7: Memory Tools — Store/Recall

**Description:** Implement `memory_store` and `memory_recall` tools backed by ConversationStore.

**Files to create:**
- `apps/fermix_core/lib/fermix_core/tools/memory_store.ex`
- `apps/fermix_core/lib/fermix_core/tools/memory_recall.ex`

**Implementation:**

```elixir
# apps/fermix_core/lib/fermix_core/tools/memory_store.ex
defmodule FermixCore.Tools.MemoryStore do
  @moduledoc """
  Store a fact to the agent's memory.
  For MVP, this is just a simple key-value store in ConversationStore metadata.
  """

  @behaviour FermixCore.Tools.Tool

  alias FermixCore.Tools.Tool

  @impl true
  def name, do: "memory_store"

  @impl true
  def description do
    "Store a fact or piece of information to the agent's long-term memory."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      required: ["key", "value"],
      properties: %{
        key: %{
          type: "string",
          description: "A unique key for this memory (e.g., 'user_timezone', 'project_name')"
        },
        value: %{
          type: "string",
          description: "The value to store"
        }
      }
    }
  end

  @impl true
  def execute(args, context) do
    key = Map.fetch!(args, "key")
    value = Map.fetch!(args, "value")
    conversation_key = Map.fetch!(context, :conversation_key)

    # For MVP: store in ETS table
    :ets.insert(:fermix_memory, {{conversation_key, key}, value, DateTime.utc_now()})

    {:ok, Tool.success("Stored memory: #{key} = #{value}")}
  end
end
```

```elixir
# apps/fermix_core/lib/fermix_core/tools/memory_recall.ex
defmodule FermixCore.Tools.MemoryRecall do
  @moduledoc """
  Recall a previously stored fact from memory.
  """

  @behaviour FermixCore.Tools.Tool

  alias FermixCore.Tools.Tool

  @impl true
  def name, do: "memory_recall"

  @impl true
  def description do
    "Recall a previously stored fact from the agent's long-term memory."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      required: ["key"],
      properties: %{
        key: %{
          type: "string",
          description: "The key of the memory to recall"
        }
      }
    }
  end

  @impl true
  def execute(args, context) do
    key = Map.fetch!(args, "key")
    conversation_key = Map.fetch!(context, :conversation_key)

    case :ets.lookup(:fermix_memory, {conversation_key, key}) do
      [{_, value, _timestamp}] ->
        {:ok, Tool.success(value)}

      [] ->
        {:ok, Tool.error("No memory found for key: #{key}")}
    end
  end
end
```

**RustyClaw reference:** `/Users/sujshe/projects/rustyclaw/src/tools/memory.rs` (concept only, not direct port)  
**Dependencies:** Task 3, Task 6  
**Effort:** 45 minutes

---

## Task 8: OpenAI Provider

**Description:** Implement the OpenAI chat completions provider with function calling support.

**Files to create:**
- `apps/fermix_core/lib/fermix_core/providers/provider.ex`
- `apps/fermix_core/lib/fermix_core/providers/openai.ex`

**Implementation:**

```elixir
# apps/fermix_core/lib/fermix_core/providers/provider.ex
defmodule FermixCore.Providers.Provider do
  @moduledoc """
  Behaviour for LLM providers.
  """

  @type chat_message :: %{
          role: String.t(),
          content: String.t(),
          optional(:tool_call_id) => String.t(),
          optional(:tool_calls) => [map()]
        }

  @type chat_opts :: [
          model: String.t(),
          temperature: float(),
          tools: [map()],
          max_tokens: pos_integer()
        ]

  @type response :: %{
          content: String.t(),
          tool_calls: [map()],
          usage: %{
            prompt_tokens: non_neg_integer(),
            completion_tokens: non_neg_integer(),
            total_tokens: non_neg_integer()
          },
          model: String.t()
        }

  @doc "Send a chat request and get a response"
  @callback chat([chat_message()], chat_opts()) :: {:ok, response()} | {:error, term()}

  @doc "List available models"
  @callback models() :: {:ok, [String.t()]} | {:error, term()}
end
```

```elixir
# apps/fermix_core/lib/fermix_core/providers/openai.ex
defmodule FermixCore.Providers.OpenAI do
  @moduledoc """
  OpenAI Chat Completions API provider.
  Supports function calling (tool use).

  Reference: /Users/sujshe/projects/rustyclaw/src/providers/openai.rs
  """

  @behaviour FermixCore.Providers.Provider

  require Logger

  @base_url "https://api.openai.com/v1"

  @impl true
  def chat(messages, opts \\ []) do
    api_key = get_api_key()
    model = Keyword.get(opts, :model, "gpt-4o-mini")
    temperature = Keyword.get(opts, :temperature, 0.7)
    tools = Keyword.get(opts, :tools)

    body =
      %{
        model: model,
        messages: format_messages(messages),
        temperature: temperature
      }
      |> maybe_add_tools(tools)

    url = "#{@base_url}/chat/completions"

    case Req.post(url,
           json: body,
           headers: [
             {"authorization", "Bearer #{api_key}"},
             {"content-type", "application/json"}
           ]
         ) do
      {:ok, %{status: 200, body: response}} ->
        parse_response(response)

      {:ok, %{status: status, body: body}} ->
        Logger.error("OpenAI API error: #{status} - #{inspect(body)}")
        {:error, "OpenAI API error: #{status}"}

      {:error, reason} ->
        Logger.error("OpenAI request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl true
  def models do
    # For MVP, return static list
    {:ok, ["gpt-4o", "gpt-4o-mini", "gpt-4-turbo", "gpt-3.5-turbo"]}
  end

  ## Internals

  defp get_api_key do
    Application.get_env(:fermix_core, :providers)
    |> Keyword.get(:openai)
    |> Keyword.fetch!(:api_key)
  end

  defp format_messages(messages) do
    Enum.map(messages, fn msg ->
      base = %{role: msg.role, content: msg.content}

      base
      |> maybe_add_field(:tool_call_id, Map.get(msg, :tool_call_id))
      |> maybe_add_field(:tool_calls, Map.get(msg, :tool_calls))
    end)
  end

  defp maybe_add_field(map, _key, nil), do: map
  defp maybe_add_field(map, key, value), do: Map.put(map, key, value)

  defp maybe_add_tools(body, nil), do: body

  defp maybe_add_tools(body, tools) when is_list(tools) and length(tools) > 0 do
    Map.put(body, :tools, tools)
  end

  defp maybe_add_tools(body, _), do: body

  defp parse_response(%{"choices" => [choice | _], "usage" => usage}) do
    message = choice["message"]
    content = message["content"] || ""
    tool_calls = message["tool_calls"] || []

    {:ok,
     %{
       content: content,
       tool_calls: tool_calls,
       usage: %{
         prompt_tokens: usage["prompt_tokens"] || 0,
         completion_tokens: usage["completion_tokens"] || 0,
         total_tokens: usage["total_tokens"] || 0
       },
       model: choice["model"] || "unknown"
     }}
  end

  defp parse_response(response) do
    Logger.error("Unexpected OpenAI response format: #{inspect(response)}")
    {:error, "Unexpected response format"}
  end
end
```

**RustyClaw reference:** `/Users/sujshe/projects/rustyclaw/src/providers/openai.rs:1-200`  
**Dependencies:** Task 1, Task 2  
**Effort:** 2 hours

---

## Task 9: Agent Loop — Core Conversation Loop

**Description:** Implement the recursive agent loop that calls LLM → executes tools → loops until done.

**Files to create:**
- `apps/fermix_core/lib/fermix_core/agent_loop.ex`

**Implementation:**

```elixir
# apps/fermix_core/lib/fermix_core/agent_loop.ex
defmodule FermixCore.AgentLoop do
  @moduledoc """
  Core LLM conversation loop with tool execution.

  This is the heart of the agent: it calls the LLM with conversation history,
  checks for tool calls in the response, executes them, appends results to
  the conversation, and loops until the LLM returns a final response with no
  tool calls.

  Reference: /Users/sujshe/projects/rustyclaw/src/agent/loop_.rs (~4000 lines)
  This is a simplified Elixir version focusing on MVP functionality.
  """

  require Logger

  alias FermixCore.Providers.OpenAI
  alias FermixCore.Tools.Registry

  @max_iterations 25

  @type loop_opts :: [
          messages: [map()],
          tools: [map()],
          provider: module(),
          model: String.t(),
          temperature: float(),
          max_iterations: pos_integer(),
          context: map()
        ]

  @type loop_result :: %{
          response: String.t(),
          iterations: pos_integer(),
          total_tokens: non_neg_integer()
        }

  @doc """
  Run the agent loop.

  Options:
  - messages: List of conversation messages
  - tools: List of tool definitions (formatted for LLM)
  - provider: Provider module (default: OpenAI)
  - model: Model name
  - temperature: Sampling temperature
  - max_iterations: Maximum loop iterations
  - context: Context map passed to tools
  """
  @spec run(loop_opts()) :: {:ok, loop_result()} | {:error, term()}
  def run(opts) do
    messages = Keyword.fetch!(opts, :messages)
    tools = Keyword.get(opts, :tools, [])
    provider = Keyword.get(opts, :provider, OpenAI)
    model = Keyword.get(opts, :model, "gpt-4o-mini")
    temperature = Keyword.get(opts, :temperature, 0.7)
    max_iterations = Keyword.get(opts, :max_iterations, @max_iterations)
    context = Keyword.get(opts, :context, %{})

    do_loop(messages, tools, provider, model, temperature, max_iterations, context, 0, 0)
  end

  ## Internal loop

  defp do_loop(messages, tools, provider, model, temp, max_iter, context, iteration, total_tokens)
       when iteration < max_iter do
    Logger.debug("Agent loop iteration #{iteration + 1}")

    # 1. Call LLM
    case provider.chat(messages, model: model, temperature: temp, tools: tools) do
      {:ok, response} ->
        new_total = total_tokens + response.usage.total_tokens

        # 2. Check for tool calls
        case response.tool_calls do
          [] ->
            # No tool calls — final response
            Logger.debug("Agent loop finished in #{iteration + 1} iterations")

            {:ok,
             %{
               response: response.content,
               iterations: iteration + 1,
               total_tokens: new_total
             }}

          tool_calls ->
            # 3. Execute tools
            Logger.debug("Executing #{length(tool_calls)} tool calls")
            tool_results = execute_tool_calls(tool_calls, context)

            # 4. Build new messages with assistant response + tool results
            assistant_message = %{
              role: "assistant",
              content: response.content,
              tool_calls: tool_calls
            }

            tool_messages =
              Enum.map(tool_results, fn {tool_call_id, result_content} ->
                %{
                  role: "tool",
                  tool_call_id: tool_call_id,
                  content: result_content
                }
              end)

            new_messages = messages ++ [assistant_message] ++ tool_messages

            # 5. Loop
            do_loop(
              new_messages,
              tools,
              provider,
              model,
              temp,
              max_iter,
              context,
              iteration + 1,
              new_total
            )
        end

      {:error, reason} ->
        Logger.error("LLM call failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp do_loop(_messages, _tools, _provider, _model, _temp, max_iter, _context, iteration, _total)
       when iteration >= max_iter do
    {:error, "Maximum iterations (#{max_iter}) reached"}
  end

  ## Tool execution

  defp execute_tool_calls(tool_calls, context) do
    Enum.map(tool_calls, fn tool_call ->
      tool_call_id = tool_call["id"]
      function = tool_call["function"]
      tool_name = function["name"]
      arguments = parse_arguments(function["arguments"])

      result = execute_tool(tool_name, arguments, context)
      {tool_call_id, result}
    end)
  end

  defp parse_arguments(json_string) when is_binary(json_string) do
    case Jason.decode(json_string) do
      {:ok, args} -> args
      {:error, _} -> %{}
    end
  end

  defp parse_arguments(args) when is_map(args), do: args
  defp parse_arguments(_), do: %{}

  defp execute_tool(tool_name, arguments, context) do
    case Registry.find_tool(tool_name) do
      {:ok, tool_module} ->
        case tool_module.execute(arguments, context) do
          {:ok, result} ->
            if result.success do
              result.output
            else
              "Error: #{result.error}"
            end

          {:error, reason} ->
            "Error executing tool: #{inspect(reason)}"
        end

      :error ->
        "Error: Tool '#{tool_name}' not found"
    end
  end
end
```

**RustyClaw reference:** `/Users/sujshe/projects/rustyclaw/src/agent/loop_.rs` (concept, not line-by-line)  
**Dependencies:** Task 3, Task 8  
**Effort:** 3 hours

---

## Task 10: Main Agent GenServer

**Description:** Implement the persistent Main Agent GenServer that receives messages and delegates to the agent loop.

**Files to create:**
- `apps/fermix_core/lib/fermix_core/agents/main_agent.ex`

**Implementation:**

```elixir
# apps/fermix_core/lib/fermix_core/agents/main_agent.ex
defmodule FermixCore.Agents.MainAgent do
  @moduledoc """
  Persistent Main Agent — the user's chief of staff.

  Started by Application supervisor with :permanent restart.
  Receives all inbound messages from channels.
  Maintains conversation state per chat.

  Reference: /Users/sujshe/projects/rustyclaw/elixir/.../agent_server.ex
  This is a simplified version focused on single-agent MVP.
  """

  use GenServer, restart: :permanent

  require Logger

  alias FermixCore.{AgentLoop, Memory.ConversationStore, Tools.Registry}
  alias FermixCore.Providers.OpenAI

  @type channel_message :: %{
          id: String.t(),
          content: String.t(),
          sender: String.t(),
          channel: String.t(),
          chat_id: String.t(),
          reply_target: String.t()
        }

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Handle an incoming message from a channel"
  @spec handle_message(channel_message()) :: :ok
  def handle_message(channel_message) do
    GenServer.cast(__MODULE__, {:handle_message, channel_message})
  end

  ## GenServer Callbacks

  @impl true
  def init(_opts) do
    Logger.info("Main Agent started")
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:handle_message, msg}, state) do
    Logger.info("Main Agent received message from #{msg.channel}/#{msg.chat_id}")

    # Run agent loop in a Task to avoid blocking
    Task.start(fn -> process_message(msg) end)

    {:noreply, state}
  end

  ## Internals

  defp process_message(msg) do
    conversation_key = {msg.channel, msg.chat_id}

    # 1. Get conversation history
    history = ConversationStore.get_history(conversation_key)

    # 2. Build system prompt
    system_message = %{
      role: "system",
      content: build_system_prompt()
    }

    # 3. Build user message
    user_message = %{
      role: "user",
      content: msg.content
    }

    messages = [system_message] ++ history ++ [user_message]

    # 4. Get available tools
    tools = Registry.all_tools_for_llm()

    # 5. Run agent loop
    context = %{
      agent_name: "main",
      conversation_key: conversation_key
    }

    case AgentLoop.run(
           messages: messages,
           tools: tools,
           provider: OpenAI,
           context: context
         ) do
      {:ok, result} ->
        Logger.info("Agent loop completed in #{result.iterations} iterations, #{result.total_tokens} tokens")

        # 6. Store conversation
        ConversationStore.add_message(conversation_key, "user", msg.content)
        ConversationStore.add_message(conversation_key, "assistant", result.response)

        # 7. Send response back via channel
        send_reply(msg, result.response)

      {:error, reason} ->
        Logger.error("Agent loop failed: #{inspect(reason)}")
        send_reply(msg, "Sorry, I encountered an error: #{inspect(reason)}")
    end
  end

  defp build_system_prompt do
    """
    You are a helpful AI assistant with access to tools.

    You can execute shell commands, read and write files, and store/recall memories.

    When you need to perform an action, use the appropriate tool. Think step by step.
    """
  end

  defp send_reply(msg, response) do
    # Delegate to channel module
    case Application.get_env(:fermix_channels, :telegram) do
      nil ->
        Logger.warning("No Telegram config found")

      _config ->
        FermixChannels.Telegram.send_message(msg.chat_id, response)
    end
  end
end
```

**RustyClaw reference:** `/Users/sujshe/projects/rustyclaw/elixir/.../agent_server.ex`  
**Dependencies:** Task 6, Task 9  
**Effort:** 2 hours

---

## Task 11: Telegram Channel — Behaviour

**Description:** Define the Channel behaviour and shared types.

**Files to create:**
- `apps/fermix_channels/lib/fermix_channels/channel.ex`

**Implementation:**

```elixir
# apps/fermix_channels/lib/fermix_channels/channel.ex
defmodule FermixChannels.Channel do
  @moduledoc """
  Behaviour for channel integrations (Telegram, WhatsApp, Discord, etc.)
  """

  @type message :: %{
          id: String.t(),
          content: String.t(),
          sender: String.t(),
          channel: String.t(),
          chat_id: String.t(),
          reply_target: String.t(),
          thread_ts: String.t() | nil
        }

  @type send_opts :: [
          reply_to: String.t(),
          parse_mode: String.t()
        ]

  @doc "Parse a webhook payload into messages"
  @callback parse_webhook(map()) :: {:ok, [message()]} | {:error, term()}

  @doc "Send a message to a chat"
  @callback send_message(String.t(), String.t(), send_opts()) :: :ok | {:error, term()}

  @doc "Verify webhook authenticity (HMAC, token, etc.)"
  @callback verify_webhook(Plug.Conn.t()) :: :ok | {:error, term()}

  @doc "Start typing indicator (optional)"
  @callback start_typing(String.t()) :: :ok
end
```

**Dependencies:** Task 1  
**Effort:** 15 minutes

---

## Task 12: Telegram Channel — Implementation

**Description:** Implement Telegram webhook parsing and message sending via Bot API.

**Files to create:**
- `apps/fermix_channels/lib/fermix_channels/telegram.ex`

**Implementation:**

```elixir
# apps/fermix_channels/lib/fermix_channels/telegram.ex
defmodule FermixChannels.Telegram do
  @moduledoc """
  Telegram Bot API integration.

  Reference: /Users/sujshe/projects/rustyclaw/src/channels/telegram.rs:1-200
  """

  @behaviour FermixChannels.Channel

  require Logger

  @bot_api_base "https://api.telegram.org"

  ## Behaviour Callbacks

  @impl true
  def parse_webhook(params) do
    cond do
      Map.has_key?(params, "message") ->
        parse_message(params["message"])

      Map.has_key?(params, "edited_message") ->
        parse_message(params["edited_message"])

      true ->
        {:ok, []}
    end
  end

  @impl true
  def send_message(chat_id, text, opts \\ []) do
    token = get_bot_token()
    url = "#{@bot_api_base}/bot#{token}/sendMessage"

    body = %{
      chat_id: chat_id,
      text: text,
      parse_mode: Keyword.get(opts, :parse_mode, "Markdown")
    }

    case Req.post(url, json: body) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: status, body: response}} ->
        Logger.error("Telegram sendMessage failed: #{status} - #{inspect(response)}")
        {:error, "Telegram API error: #{status}"}

      {:error, reason} ->
        Logger.error("Telegram request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl true
  def verify_webhook(_conn) do
    # For MVP: no verification (add webhook secret later)
    :ok
  end

  @impl true
  def start_typing(chat_id) do
    token = get_bot_token()
    url = "#{@bot_api_base}/bot#{token}/sendChatAction"

    body = %{
      chat_id: chat_id,
      action: "typing"
    }

    Req.post(url, json: body)
    :ok
  end

  ## Internals

  defp get_bot_token do
    Application.get_env(:fermix_channels, :telegram)
    |> Keyword.fetch!(:bot_token)
  end

  defp parse_message(msg) do
    chat_id = to_string(msg["chat"]["id"])
    sender = msg["from"]["username"] || msg["from"]["first_name"] || "unknown"
    content = msg["text"] || msg["caption"] || ""

    message = %{
      id: to_string(msg["message_id"]),
      content: content,
      sender: sender,
      channel: "telegram",
      chat_id: chat_id,
      reply_target: chat_id,
      thread_ts: nil
    }

    {:ok, [message]}
  end
end
```

**RustyClaw reference:** `/Users/sujshe/projects/rustyclaw/src/channels/telegram.rs:1-200`  
**Dependencies:** Task 11  
**Effort:** 2 hours

---

## Task 13: Phoenix App Setup

**Description:** Set up Phoenix with router, endpoint, and webhook controller.

**Files to create:**
- `apps/fermix_web/lib/fermix_web/router.ex`
- `apps/fermix_web/lib/fermix_web/endpoint.ex`
- `apps/fermix_web/lib/fermix_web/controllers/webhook_controller.ex`
- `apps/fermix_web/lib/fermix_web/controllers/health_controller.ex`

**Implementation:**

```elixir
# apps/fermix_web/lib/fermix_web/router.ex
defmodule FermixWeb.Router do
  use FermixWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", FermixWeb do
    pipe_through :api

    # Health check
    get "/health", HealthController, :index

    # Telegram webhook
    post "/webhook/telegram", WebhookController, :telegram
  end
end
```

```elixir
# apps/fermix_web/lib/fermix_web/endpoint.ex
defmodule FermixWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :fermix_web

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["*/*"],
    json_decoder: Jason

  plug Plug.MethodOverride
  plug Plug.Head
  plug FermixWeb.Router
end
```

```elixir
# apps/fermix_web/lib/fermix_web/controllers/webhook_controller.ex
defmodule FermixWeb.WebhookController do
  use FermixWeb, :controller

  require Logger

  def telegram(conn, params) do
    Logger.debug("Telegram webhook received: #{inspect(params)}")

    with :ok <- FermixChannels.Telegram.verify_webhook(conn),
         {:ok, messages} <- FermixChannels.Telegram.parse_webhook(params) do
      # Forward each message to Main Agent
      for msg <- messages do
        FermixCore.Agents.MainAgent.handle_message(msg)
      end

      json(conn, %{ok: true})
    else
      {:error, reason} ->
        Logger.error("Webhook processing failed: #{inspect(reason)}")

        conn
        |> put_status(400)
        |> json(%{error: "Invalid webhook"})
    end
  end
end
```

```elixir
# apps/fermix_web/lib/fermix_web/controllers/health_controller.ex
defmodule FermixWeb.HealthController do
  use FermixWeb, :controller

  def index(conn, _params) do
    json(conn, %{
      status: "ok",
      app: "fermix",
      version: "0.1.0",
      timestamp: DateTime.utc_now()
    })
  end
end
```

**Dependencies:** Task 1, Task 12  
**Effort:** 1.5 hours

---

## Task 14: Application Supervisors

**Description:** Wire up the application supervisors to start all services.

**Files to create:**
- `apps/fermix_core/lib/fermix_core/application.ex`
- `apps/fermix_web/lib/fermix_web/application.ex`

**Implementation:**

```elixir
# apps/fermix_core/lib/fermix_core/application.ex
defmodule FermixCore.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Create ETS table for memory storage (MVP)
    :ets.new(:fermix_memory, [:named_table, :public, :set])

    children = [
      # Conversation store
      FermixCore.Memory.ConversationStore,

      # Main Agent (permanent)
      FermixCore.Agents.MainAgent
    ]

    opts = [strategy: :one_for_one, name: FermixCore.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

```elixir
# apps/fermix_web/lib/fermix_web/application.ex
defmodule FermixWeb.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      FermixWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: FermixWeb.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    FermixWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
```

**Dependencies:** Task 6, Task 10  
**Effort:** 30 minutes

---

## Task 15: Integration Test — End-to-End

**Description:** Write an integration test that simulates a Telegram webhook → agent loop → tool execution.

**Files to create:**
- `apps/fermix_web/test/fermix_web/integration_test.exs`

**Implementation:**

```elixir
# apps/fermix_web/test/fermix_web/integration_test.exs
defmodule FermixWeb.IntegrationTest do
  use FermixWeb.ConnCase

  @moduletag :integration

  describe "Telegram webhook → agent loop → tool execution" do
    test "receives message, executes shell tool, responds", %{conn: conn} do
      # Simulate Telegram webhook payload
      payload = %{
        "message" => %{
          "message_id" => 123,
          "chat" => %{"id" => 456},
          "from" => %{"username" => "test_user"},
          "text" => "Run command: echo hello"
        }
      }

      conn = post(conn, ~p"/webhook/telegram", payload)

      assert json_response(conn, 200) == %{"ok" => true}

      # Give the async task time to process
      Process.sleep(100)

      # Check conversation store was updated
      history = FermixCore.Memory.ConversationStore.get_history({"telegram", "456"})
      assert length(history) > 0
    end
  end
end
```

**Dependencies:** All tasks  
**Effort:** 1 hour

---

## Task 16: Documentation — README and Setup Guide

**Description:** Write README.md with setup instructions, architecture overview, and usage examples.

**Files to create:**
- `README.md`
- `docs/SETUP.md`

**Implementation:**

```markdown
# Fermix

**Elixir-native multi-agent AI platform**

Phoenix gateway, OTP-supervised agents, Rustler NIFs for crypto/tokenization only.

## Phase 1 MVP

Single-agent Telegram bot with:
- OpenAI provider (gpt-4o-mini)
- Basic tools: shell, file_read, file_write, memory
- Per-chat conversation history

## Setup

### Prerequisites

- Elixir 1.17+
- Erlang/OTP 27+
- Telegram Bot Token (from @BotFather)
- OpenAI API Key

### Installation

```bash
# Clone repo
git clone https://github.com/tezra-io/fermix
cd fermix

# Install dependencies
mix deps.get

# Set environment variables
export TELEGRAM_BOT_TOKEN="your-token"
export OPENAI_API_KEY="your-key"

# Run Phoenix server
mix phx.server
```

Server runs on http://localhost:4000

### Telegram Webhook Setup

```bash
# Set webhook (replace YOUR_DOMAIN and YOUR_TOKEN)
curl -X POST "https://api.telegram.org/botYOUR_TOKEN/setWebhook" \
  -d "url=https://YOUR_DOMAIN/webhook/telegram"
```

## Usage

Send a message to your Telegram bot:

```
Run command: ls -la
```

The agent will:
1. Parse the message
2. Call OpenAI with tool definitions
3. Execute the `shell` tool
4. Return the output

## Architecture

See [docs/PROJECT_PLAN.md](docs/PROJECT_PLAN.md) for full details.

## Testing

```bash
mix test                    # All tests
mix test --only integration # Integration tests
```

## License

MIT
```

**Dependencies:** All tasks  
**Effort:** 1 hour

---

## Summary

**Total Tasks:** 16  
**Estimated Total Effort:** ~20-24 hours  
**Timeline:** 2-3 weeks at 10-15 hrs/week

**Task Order (dependency-aware):**

1. Task 1: Umbrella scaffold
2. Task 2: Config system
3. Task 3: Tool behaviour + registry
4. Task 4: Shell tool
5. Task 5: File read/write tools
6. Task 6: ConversationStore
7. Task 7: Memory tools
8. Task 8: OpenAI provider
9. Task 9: Agent loop
10. Task 10: Main Agent
11. Task 11: Channel behaviour
12. Task 12: Telegram implementation
13. Task 13: Phoenix app
14. Task 14: Application supervisors
15. Task 15: Integration test
16. Task 16: Documentation

**Next Steps After Phase 1:**

- Add Anthropic provider
- Port AgentServer/AgentSupervisor for multi-agent
- Add more tools (web_fetch, git, file_edit)
- Implement three-tier memory system
- Add WhatsApp and Discord channels
