defmodule FermixCore.ComputerHistory.Gate do
  @moduledoc """
  The single gating resolver for Computer History (MILESTONE_32 §9). Every
  egress sink — the turn's LLM chain, the Recent Activity prompt section, the
  `recall_activity` tool advertisement and execution, the summarizer run, a
  realtime voice session, and telemetry — asks this one module "may history
  flow into *this*." Nothing else reads the history config for a flow decision,
  so the prompt and the wire cannot disagree ("the prompt must follow the
  wire").

  Two calls:

    * `snapshot/2` — computed **once per turn** from inputs the turn already
      carries (`ordered_routes`, `source_trust`, depth markers). Reads app env
      and the attended-operator predicate here, so `allow?/2` stays pure.
    * `allow?/2` — pure, total, no IO. Given a snapshot and a sink, yes/no.

  The load-bearing rule (§9.2): "local-only" is a property of the **whole
  route chain**, never the resolved head. `Failover.run_chain/3` re-sends the
  identical message list to later hops, and the descriptor convention puts
  Ollama *last* — so a chain that begins remote and a chain that ends remote
  both exist. If **any** hop is ungranted-remote, the whole turn is denied:
  the section is absent and the tools are un-advertised. It never strips hops
  or builds a second prompt variant (one prompt per turn, Code Rule 12).
  """

  alias FermixCore.ComputerHistory
  alias FermixCore.ComputerHistory.Config
  alias FermixCore.ComputerHistory.Gate.Snapshot
  alias FermixCore.ComputerHistory.Locality
  alias FermixCore.Providers.Descriptor
  alias FermixCore.Temporal.Access

  @type route_key :: %{required(:provider) => atom(), optional(:base_url) => String.t() | nil}
  @type route :: route_key() | {route_key(), keyword()}

  @type sink ::
          {:llm_chain, [route()] | nil}
          | {:history_replay, [route()] | nil}
          | {:prompt_section, map()}
          | {:tool_advertise, map()}
          | {:tool_execute, map()}
          | {:summarizer, route()}
          | {:realtime_session, atom()}

  @doc """
  Build the per-turn snapshot. `context` is the turn's plain context map;
  `opts` carries only `:macos?` (defaults to `ComputerHistory.macos?/0`), so
  tests inject the platform explicitly instead of depending on the host OS.
  """
  @spec snapshot(map(), keyword()) :: Snapshot.t()
  def snapshot(context, opts \\ []) when is_map(context) and is_list(opts) do
    macos? = Keyword.get(opts, :macos?, ComputerHistory.macos?())
    config = Config.current()
    operative? = macos? and Config.enabled?(config)

    chain = Map.get(context, :ordered_routes)

    # `granted` and `summarizer_target` both fold in the default-summarizer's
    # primary (§22.1). This is the only IO-bearing resolution; `allow?/2` stays
    # pure on the result.
    granted = effective_history_granted(config)

    %Snapshot{
      operative?: operative?,
      attended_operator?: Access.attended_operator_turn?(context),
      granted: granted,
      summarizer_target: default_summarizer_target(config),
      chain: chain,
      chain_ok?: operative? and chain_permitted?(chain, granted)
    }
  end

  # The provider set trusted for HISTORY egress: the Tier-2 grants PLUS — when the
  # default summarizer is in force (§22.1) — the primary provider (the enable act's
  # consent). One resolver so recall (the snapshot), the turn chain, and taint
  # masking (`chain_permits_history?/1`) never disagree about that provider.
  defp effective_history_granted(config) do
    base = Config.granted_providers(config)

    # Gated on `enabled?`: the auto-grant is a CONSEQUENCE of running the default
    # summarizer, not an explicit grant — so it lapses the moment history is
    # disabled, reverting taint masking to the explicit Tier-2 grants only (§13.6:
    # a tainted turn must not reach an ungranted-remote provider after disabling).
    with true <- Config.enabled?(config),
         :default_provider <- Config.summarizer(config),
         {:ok, provider} <- Config.default_summarizer_provider() do
      MapSet.put(base, provider)
    else
      _ -> base
    end
  end

  # `:default_provider` resolves to the summarizer's provider (subagent → primary,
  # §22.1). An unresolved provider stays `:default_provider`, which no
  # `summarizer_route_permitted?` clause accepts — so it denies, fail-closed.
  defp default_summarizer_target(config) do
    with :default_provider <- Config.summarizer(config),
         {:ok, provider} <- Config.default_summarizer_provider() do
      {:provider, provider}
    else
      {:error, _reason} -> :default_provider
      other -> other
    end
  end

  @doc """
  Whether a history-**tainted** message may ride `routes` — the chain rule
  (every hop local-or-granted) evaluated against the *current* grant set,
  **independent of `enabled?`** (§13.6). Used by the compaction/replay taint
  filter: the taint is a property of the message's origin, so a tainted turn
  must not reach an ungranted-remote provider even after history is disabled. A
  `nil`/empty/unclassifiable chain fails closed (mask).
  """
  @spec chain_permits_history?([route()] | nil) :: boolean()
  def chain_permits_history?(routes),
    do: chain_permitted?(routes, effective_history_granted(Config.current()))

  @doc "Whether history may flow into `sink` under `snapshot`. Pure and total."
  @spec allow?(Snapshot.t(), sink()) :: boolean()
  def allow?(snapshot, sink)

  # Note (§20.0 decision 3, owner-resolved 2026-08-15): telemetry is deliberately
  # NOT a Gate sink. History I/O flows into the local trace and local Opik under
  # the normal `capture_content` posture — the operator chose debuggability, and
  # traces/Opik default to on-device (localhost). If the operator points Opik at
  # Opik-Cloud, that content egresses there — their own observability choice.

  # The whole-chain rule: every hop local-or-granted, else the turn is denied.
  def allow?(%Snapshot{operative?: false}, {:llm_chain, _routes}), do: false

  def allow?(%Snapshot{granted: granted}, {:llm_chain, routes}),
    do: chain_permitted?(routes, granted)

  # The replay/compaction sink (§13.6): may a history-TAINTED message ride
  # `routes`? Deliberately NOT `{:llm_chain, routes}` — that sink is false
  # whenever the feature is not operative, but the taint is a property of the
  # message's ORIGIN, so a tainted turn must keep being masked on an
  # ungranted-remote chain after `/history off` rather than becoming sendable.
  # Same rule as the live `chain_permits_history?/1`, read from the turn's
  # frozen grant set so every mask in one turn decides against one grant set.
  def allow?(%Snapshot{granted: granted}, {:history_replay, routes}),
    do: chain_permitted?(routes, granted)

  # Consumer surfaces that carry derived summaries into the turn's LLM chain:
  # the section, the tool advertisement, and (belt-and-braces) tool execution.
  # All three require an attended operator turn AND a permitted chain.
  def allow?(%Snapshot{} = snapshot, {:prompt_section, ctx}) when is_map(ctx),
    do: consumer_permitted?(snapshot)

  def allow?(%Snapshot{} = snapshot, {:tool_advertise, ctx}) when is_map(ctx),
    do: consumer_permitted?(snapshot)

  def allow?(%Snapshot{} = snapshot, {:tool_execute, ctx}) when is_map(ctx),
    do: consumer_permitted?(snapshot)

  # The summarizer's single pinned route: local under Tier 1/2 (raw stays on
  # device), or exactly the one named provider under Tier 3. Any other route —
  # including a failover to a different vendor — is denied (inv. 1b).
  def allow?(%Snapshot{operative?: false}, {:summarizer, _route}), do: false

  def allow?(%Snapshot{summarizer_target: target}, {:summarizer, route}),
    do: summarizer_route_permitted?(route, target)

  # A realtime voice session advertises the tool only when the voice provider
  # is itself local-or-granted (OpenAI realtime is remote ⇒ Tier 2 grant), on
  # an attended operator turn.
  def allow?(%Snapshot{} = snapshot, {:realtime_session, provider}) when is_atom(provider) do
    consumer_base_permitted?(snapshot) and provider_permitted?(provider, snapshot.granted)
  end

  def allow?(%Snapshot{}, _unknown_sink), do: false

  # --- derivations --------------------------------------------------------

  # The section / tool surfaces additionally require the turn's own chain to be
  # permitted, because whatever they inject rides that chain.
  defp consumer_permitted?(snapshot),
    do: consumer_base_permitted?(snapshot) and snapshot.chain_ok?

  defp consumer_base_permitted?(%Snapshot{operative?: operative?, attended_operator?: attended?}),
    do: operative? and attended?

  # A missing/empty chain is unverifiable ⇒ denied (fail closed). Every present
  # hop must be local or in the Tier-2 grant set.
  defp chain_permitted?(nil, _granted), do: false
  defp chain_permitted?([], _granted), do: false

  defp chain_permitted?(routes, granted) when is_list(routes),
    do: Enum.all?(routes, &hop_permitted?(&1, granted))

  defp chain_permitted?(_other, _granted), do: false

  defp hop_permitted?({route_key, _opts}, granted), do: hop_permitted?(route_key, granted)

  defp hop_permitted?(%{provider: provider} = route_key, granted) when is_atom(provider) do
    local_route?(route_key) or MapSet.member?(granted, provider)
  end

  # A hop with no `:provider`, or a non-atom one (a legacy/hand-edited route),
  # is unclassifiable ⇒ deny. `allow?/2` stays total: it never crashes a turn.
  defp hop_permitted?(_malformed, _granted), do: false

  # A route is local only when the provider *declares* local loopback AND its
  # effective base URL actually resolves to loopback (§9.3).
  defp local_route?(%{provider: provider} = route_key) when is_atom(provider) do
    Descriptor.locality(provider) == :local_loopback and
      Locality.loopback?(Map.get(route_key, :base_url))
  end

  defp local_route?(_malformed), do: false

  defp summarizer_route_permitted?(route, :local), do: local_route?(route_key(route))

  defp summarizer_route_permitted?(route, {:provider, named}) do
    case route_key(route) do
      %{provider: provider} -> provider == named
      _malformed -> false
    end
  end

  # Totality: an unresolved `:default_provider` (no/ambiguous primary) or any
  # other shape denies — the summarizer never runs against an unverified target.
  defp summarizer_route_permitted?(_route, _target), do: false

  defp route_key({route_key, _opts}) when is_map(route_key), do: route_key
  defp route_key(route_key) when is_map(route_key), do: route_key
  defp route_key(_malformed), do: %{}

  # A realtime voice provider carries no per-route base URL, so its loopback
  # cannot be verified — "declared locality" alone is not enough under §9.3.
  # A realtime session is a remote vendor (OpenAI realtime), so the tool is
  # advertised in voice only under an explicit Tier-2 grant (§11.3); a
  # hypothetical local realtime provider would fail closed until granted.
  defp provider_permitted?(provider, granted), do: MapSet.member?(granted, provider)
end
