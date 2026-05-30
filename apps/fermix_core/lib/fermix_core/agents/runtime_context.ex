defmodule FermixCore.Agents.RuntimeContext do
  @moduledoc """
  Cached runtime context owned by `FermixCore.Agents.MainAgent`.

  Holds the file-backed prompt base (bootstrap + USER.md/MEMORY.md), the
  prompt accounting, the available-skills snapshot, and enumerated text
  profiles (filtered capabilities + generated runtime section). The cache
  is built lazily on the first inbound message inside the MainAgent
  GenServer and reused across messages for the server runtime epoch.
  Source changes are picked up by restarting Fermix or by an explicit skill
  reload, which invalidates this cache before the next message.

  ## Ownership model

  Mutation happens only inside the MainAgent GenServer. Spawned message
  tasks receive an **immutable snapshot** of the context through
  `task_runtime_state/1` and read from it; they never write back.

  See `docs/MAIN_AGENT_RUNTIME_CONTEXT_CACHE.md`.
  """

  alias FermixCore.Agents.AgentDefinition
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Plugins.PromptCatalog
  alias FermixCore.Prompt.Accounting
  alias FermixCore.Prompt.PromptComposer
  alias FermixCore.Prompt.RuntimeSections

  @type message :: %{role: String.t(), content: String.t()}

  @type profile :: %{
          trust: :operator | :guest,
          capabilities: [Capability.t()],
          runtime_message: message(),
          runtime_accounting: Accounting.entry()
        }

  @type t :: %__MODULE__{
          agent_id: String.t(),
          built_at_ms: integer(),
          base_messages: [message()],
          base_accounting: [Accounting.entry()],
          available_skills: [AgentDefinition.t()],
          operator_profile: profile(),
          guest_profile: profile()
        }

  defstruct [
    :agent_id,
    :built_at_ms,
    :base_messages,
    :base_accounting,
    :available_skills,
    :operator_profile,
    :guest_profile
  ]

  @doc """
  Build a fresh runtime context for `agent_id`. Operator and guest
  profiles are built eagerly. Returns `{:error, reason}` if the prompt
  base cannot be composed (typically a malformed prompt file).

  Options:

    * `:agent_id` — required, binary
    * `:available_skills` — list of `AgentDefinition.t()`
    * `:capability_registry` — server name/pid (default
      `FermixCore.Capabilities.Registry`)
  """
  @spec build(keyword()) :: {:ok, t()} | {:error, term()}
  def build(opts) when is_list(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    available_skills = Keyword.get(opts, :available_skills, [])
    capability_registry = Keyword.get(opts, :capability_registry, CapabilityRegistry)

    with {:ok, base} <- PromptComposer.compose_base_with_metadata(opts) do
      base_messages = PromptComposer.export_parts(base.parts)
      operator_profile = build_profile(:operator, available_skills, capability_registry)
      guest_profile = build_profile(:guest, available_skills, capability_registry)

      {:ok,
       %__MODULE__{
         agent_id: agent_id,
         built_at_ms: System.system_time(:millisecond),
         base_messages: base_messages,
         base_accounting: base.accounting,
         available_skills: available_skills,
         operator_profile: operator_profile,
         guest_profile: guest_profile
       }}
    end
  end

  @doc """
  Build a single profile (capabilities + runtime section) for a trust
  level. Used by `build/1` for the enumerated profiles.

  Caller is expected to pass any additional filter knobs already
  resolved (allowed_tools, excluded_categories) for callers that need
  them; the default profile only constrains by trust.
  """
  @spec build_profile(:operator | :guest, [AgentDefinition.t()], GenServer.server(), keyword()) ::
          profile()
  def build_profile(trust, available_skills, capability_registry, opts \\ [])
      when trust in [:operator, :guest] and is_list(available_skills) and is_list(opts) do
    filter =
      [trust: trust]
      |> maybe_put(:allowed_tools, Keyword.get(opts, :allowed_tools))
      |> maybe_put(:excluded_categories, Keyword.get(opts, :excluded_categories))

    capabilities = CapabilityRegistry.list_for(capability_registry, filter)

    runtime_content =
      RuntimeSections.build(available_skills,
        capabilities: capabilities,
        trust: trust,
        plugins: PromptCatalog.entries(capabilities, Enum.map(available_skills, & &1.name))
      )

    %{
      trust: trust,
      capabilities: capabilities,
      runtime_message: %{role: "system", content: runtime_content},
      runtime_accounting: Accounting.entry(:runtime, nil, runtime_content)
    }
  end

  @doc """
  Return the cached profile for `trust`.
  """
  @spec profile_for(t(), :operator | :guest, GenServer.server(), keyword()) :: profile()
  def profile_for(%__MODULE__{operator_profile: operator}, :operator, _registry, _opts),
    do: operator

  def profile_for(%__MODULE__{guest_profile: guest}, :guest, _registry, _opts), do: guest

  @doc """
  Assemble the full message list for a turn:
  `base ++ profile.runtime_message ++ history ++ [user_message]`.
  """
  @spec messages_for(t(), profile(), [map()], message()) :: [message()]
  def messages_for(
        %__MODULE__{} = ctx,
        %{runtime_message: runtime_message},
        history,
        user_message
      )
      when is_list(history) and is_map(user_message) do
    ctx.base_messages ++ [runtime_message] ++ history ++ [user_message]
  end

  @doc """
  Compose the accounting list reported by `[:fermix, :agent, :prompt_context]`
  telemetry: base accounting + the runtime section accounting for the
  profile used on this turn.
  """
  @spec accounting_for(t(), profile()) :: [Accounting.entry()]
  def accounting_for(%__MODULE__{base_accounting: base}, %{runtime_accounting: runtime}) do
    base ++ [runtime]
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
