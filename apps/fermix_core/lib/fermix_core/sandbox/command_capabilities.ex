defmodule FermixCore.Sandbox.CommandCapabilities do
  @moduledoc """
  Registers operator-declared local commands as built-in capabilities.
  """

  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Sandbox.CommandTool
  alias FermixCore.Sandbox.Config

  require Logger

  @preset_specs %{
    "ai_tools" => [
      %{
        name: "codex",
        command: "codex",
        args: [],
        pass_env: ["OPENAI_API_KEY"],
        description: "Run Codex with a one-shot prompt."
      },
      %{
        name: "claude_code",
        command: "claude",
        args: [],
        pass_env: ["ANTHROPIC_API_KEY"],
        description: "Run Claude Code with a one-shot prompt."
      }
    ],
    "dev_tools" => [
      %{name: "git", command: "git", args: [], pass_env: [], description: "Run git."},
      %{name: "gh", command: "gh", args: [], pass_env: [], description: "Run GitHub CLI."},
      %{name: "make", command: "make", args: [], pass_env: [], description: "Run make."}
    ]
  }

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :transient
    }
  end

  @spec start_link(keyword()) :: :ignore
  def start_link(opts \\ []) do
    opts
    |> Keyword.get(:capability_registry, CapabilityRegistry)
    |> refresh(Config.current())

    :ignore
  end

  @spec refresh(GenServer.server(), Config.t() | map() | keyword()) :: :ok
  def refresh(server, config) do
    config = Config.normalize(config)
    CapabilityRegistry.unregister_kind(server, :builtin, metadata: %{sandbox_command?: true})

    config
    |> descriptors()
    |> Enum.each(&register(server, &1))

    :ok
  end

  @spec descriptors(Config.t() | map() | keyword()) :: [map()]
  def descriptors(config) do
    config = Config.normalize(config)

    preset_descriptors(config) ++ explicit_descriptors(config)
  end

  defp preset_descriptors(%Config{commands: %{profile: :bare}}), do: []

  defp preset_descriptors(config) do
    config.commands.presets
    |> Enum.flat_map(&Map.get(@preset_specs, &1, []))
    |> Enum.map(&normalize_descriptor/1)
    |> Enum.filter(&command_available?/1)
  end

  defp explicit_descriptors(config) do
    config.commands.explicit
    |> Enum.filter(fn {_name, spec} -> spec.enabled end)
    |> Enum.map(fn {name, spec} -> normalize_descriptor(Map.put(spec, :name, name)) end)
    |> Enum.filter(&command_available?/1)
  end

  defp normalize_descriptor(spec) do
    %{
      name: Map.fetch!(spec, :name),
      command: Map.fetch!(spec, :command),
      args: Map.get(spec, :args, []),
      pass_env: Map.get(spec, :pass_env, []),
      timeout_ms: Map.get(spec, :timeout_ms, 30_000),
      description: Map.get(spec, :description) || "Run #{Map.fetch!(spec, :command)}."
    }
  end

  defp command_available?(%{command: "/" <> _rest = command}), do: File.exists?(command)
  defp command_available?(%{command: command}), do: not is_nil(System.find_executable(command))

  defp register(server, spec) do
    case CapabilityRegistry.register(server, capability(spec)) do
      :ok ->
        :ok

      {:error, {:duplicate_name, name}} ->
        Logger.warning("Sandbox command capability #{inspect(name)} already registered; skipping.")
    end
  end

  defp capability(spec) do
    Capability.new(%{
      name: spec.name,
      description: spec.description,
      parameters: parameters(),
      kind: :builtin,
      executor: {CommandTool, :execute, [spec]},
      policy_class: :exec,
      requires_approval?: false,
      metadata: %{
        sandbox_command?: true,
        category: :system,
        when_to_use: spec.description,
        examples: [%{args: %{"prompt" => "summarize this repo"}, note: "one-shot prompt"}],
        failure_modes: [
          %{tag: "missing_env", description: "configured pass_env value could not be resolved"},
          %{tag: "command_failed", description: "local command exited non-zero"}
        ]
      }
    })
  end

  defp parameters do
    %{
      type: "object",
      required: ["prompt"],
      properties: %{
        prompt: %{type: "string", description: "Prompt or task to pass to the command."},
        args: %{type: "array", items: %{type: "string"}, description: "Extra structured args."}
      }
    }
  end
end
