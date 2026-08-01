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
  alias FermixCore.Capabilities.Deferral
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Plugins.PromptCatalog
  alias FermixCore.Prompt.Accounting
  alias FermixCore.Prompt.PromptComposer
  alias FermixCore.Prompt.RuntimeSections

  @type message :: %{role: String.t(), content: String.t()}

  @type profile :: %{
          trust: :operator | :guest,
          capabilities: [Capability.t()],
          dispatchable: [Capability.t()],
          runtime_message: message(),
          runtime_accounting: Accounting.entry()
        }

  @type t :: %__MODULE__{
          agent_id: String.t(),
          built_at_ms: integer(),
          base_messages: [message()],
          stable_messages: [message()],
          volatile_messages: [message()],
          base_accounting: [Accounting.entry()],
          available_skills: [AgentDefinition.t()],
          operator_profile: profile(),
          guest_profile: profile(),
          harness_free_profiles: %{(:operator | :guest) => profile()}
        }

  defstruct [
    :agent_id,
    :built_at_ms,
    :base_messages,
    :stable_messages,
    :volatile_messages,
    :base_accounting,
    :available_skills,
    :operator_profile,
    :guest_profile,
    :harness_free_profiles
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
      split = PromptComposer.export_split(base.parts)
      operator_profile = build_profile(:operator, available_skills, capability_registry)
      guest_profile = build_profile(:guest, available_skills, capability_registry)

      {:ok,
       %__MODULE__{
         agent_id: agent_id,
         built_at_ms: System.system_time(:millisecond),
         base_messages: split.stable ++ split.volatile,
         stable_messages: split.stable,
         volatile_messages: split.volatile,
         base_accounting: base.accounting,
         available_skills: available_skills,
         operator_profile: operator_profile,
         guest_profile: guest_profile,
         harness_free_profiles: %{
           operator: harness_free(operator_profile, available_skills, capability_registry),
           guest: harness_free(guest_profile, available_skills, capability_registry)
         }
       }}
    end
  end

  # The profile a client-owned channel runs on (MILESTONE_29_ACP_AGENT_SURFACE
  # §4, "Detached work"): an ACP session's conversation ends with the client, so
  # a coding run has nowhere to report back and every harness tool self-hides
  # there. The M28 lesson is that the PROSE must move with the wire — steering
  # repository work to `codex_run` while no harness tool is advertised sends the
  # model at a tool it cannot call — so this variant excludes the whole `:harness`
  # category from the ONE list the profile is built from, dropping the catalog
  # section and the advertised schemas together.
  #
  # Nothing to exclude ⇒ the base profile IS the variant, so a host without the
  # harness pays neither the second build nor a second copy of the prompt.
  defp harness_free(profile, available_skills, capability_registry) do
    if Enum.any?(profile.dispatchable, &(&1.metadata[:category] == :harness)) do
      build_profile(profile.trust, available_skills, capability_registry,
        excluded_categories: [:harness]
      )
    else
      profile
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

    # M10 §3.2 partition: the wire advertises only the non-deferred schemas;
    # the dispatchable surface keeps everything (advertised ∪ deferred), both
    # derived from the same trust-filtered list. The prompt prose (capability
    # catalog + plugin index) is built from the FULL list — names stay visible,
    # only schemas defer.
    %{advertised: advertised} = Deferral.partition(capabilities)

    runtime_content =
      RuntimeSections.build(available_skills,
        capabilities: capabilities,
        trust: trust,
        plugins: PromptCatalog.entries(capabilities, Enum.map(available_skills, & &1.name))
      )

    %{
      trust: trust,
      capabilities: advertised,
      dispatchable: capabilities,
      runtime_message: %{role: "system", content: runtime_content},
      runtime_accounting: Accounting.entry(:runtime, nil, runtime_content)
    }
  end

  @doc """
  Return the cached profile for `trust`.

  `harness_tools?: false` selects the client-owned-channel variant (see
  `harness_free/3`) — the same trust surface with the `:harness` category
  excluded from prompt and wire alike. Defaults to the base profile, so every
  ordinary channel is unchanged.
  """
  @spec profile_for(t(), :operator | :guest, GenServer.server(), keyword()) :: profile()
  def profile_for(%__MODULE__{} = ctx, trust, _registry, opts)
      when trust in [:operator, :guest] and is_list(opts) do
    if Keyword.get(opts, :harness_tools?, true),
      do: base_profile(ctx, trust),
      else: Map.fetch!(ctx.harness_free_profiles, trust)
  end

  defp base_profile(%__MODULE__{operator_profile: operator}, :operator), do: operator
  defp base_profile(%__MODULE__{guest_profile: guest}, :guest), do: guest

  @doc """
  Assemble the full message list for a turn, stable tier first
  (cache stratification — M10 P1):
  `stable ++ profile.runtime_message ++ volatile ++ history ++ [user_message]`.
  """
  @spec messages_for(t(), profile(), [map()], message()) :: [message()]
  def messages_for(
        %__MODULE__{} = ctx,
        %{runtime_message: runtime_message},
        history,
        user_message
      )
      when is_list(history) and is_map(user_message) do
    ctx.stable_messages ++
      [runtime_message] ++ ctx.volatile_messages ++ history ++ [user_message]
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
