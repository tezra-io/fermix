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
  both exist. The all-hops rule therefore decides the turn: if **any** hop is
  ungranted-remote, the section is absent and the tools are un-advertised. One
  prompt per turn — it never builds a second prompt variant (Code Rule 12).

  What that rule is applied to is the **effective** chain (§9.4 pinning), which
  `snapshot/2` resolves once:

    * an attended owner turn whose LEAD hop is granted runs on the granted
      subset — `routes` keeps the lead plus the granted fallbacks in order,
      `dropped_hops` names the rest, and failover can no longer reach a provider
      the owner did not consent to. This is a narrowing of the chain, not a
      per-hop relaxation of the rule: the effective chain still has to pass it.
    * every other turn — a guest, a subagent worker, an unattended run, an
      ungranted lead (the lead is never replaced), a chain carrying a hop with no
      provider id, or history switched off — keeps the **full** chain and is
      denied exactly as before, with `dropped_hops` empty.

  A denial is no longer silent: `chain_posture/1` names the state on all three
  operator surfaces (`/history status`, the doctor row, the setup card).
  """

  alias FermixCore.ComputerHistory
  alias FermixCore.ComputerHistory.Config
  alias FermixCore.ComputerHistory.Gate.Snapshot
  alias FermixCore.ComputerHistory.Locality
  alias FermixCore.Providers.Descriptor
  alias FermixCore.Providers.PrimaryConfig
  alias FermixCore.Providers.Selection
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

  @type posture :: %{
          state: :pinned | :unsurfaceable | :unclassifiable_chain | :off | :no_chain,
          lead: atom() | nil,
          routes: [atom()],
          dropped: [atom()],
          summarizer: Config.summarizer()
        }

  @doc """
  Build the per-turn snapshot. `context` is the turn's plain context map; `opts`
  carries `:macos?` (defaults to `ComputerHistory.macos?/0`) and `:config` (the
  history config block, defaults to `Config.current/0`), so tests and the status
  surfaces inject the platform and the consent posture explicitly instead of
  depending on the host OS and on live app env.
  """
  @spec snapshot(map(), keyword()) :: Snapshot.t()
  def snapshot(context, opts \\ []) when is_map(context) and is_list(opts) do
    macos? = Keyword.get(opts, :macos?, ComputerHistory.macos?())
    config = Keyword.get_lazy(opts, :config, &Config.current/0)
    operative? = macos? and Config.enabled?(config)
    attended? = Access.attended_operator_turn?(context)

    chain = Map.get(context, :ordered_routes)

    # `granted` and `summarizer_target` both fold in the default summarizer's
    # provider and the primary (§22.1). This is the only IO-bearing resolution;
    # `allow?/2` stays pure on the result.
    granted = effective_history_granted(config)
    {routes, dropped_hops} = pin_chain(chain, granted, operative? and attended?)

    %Snapshot{
      operative?: operative?,
      attended_operator?: attended?,
      granted: granted,
      summarizer_target: default_summarizer_target(config),
      chain: chain,
      routes: routes,
      dropped_hops: dropped_hops,
      chain_ok?: operative? and chain_permitted?(routes, granted)
    }
  end

  # §9.4 chain pinning: on an attended owner turn with history operative, the
  # turn runs ONLY on the hops granted for history, keeping their order —
  # failover among granted hops still works, and if none of them is up the turn
  # fails with the ordinary "provider unavailable" reply rather than reaching a
  # hop the owner never consented to. The lead is never replaced: an ungranted
  # lead leaves the chain exactly as it arrived (history then does not surface).
  # A chain carrying a hop no reader can name is left alone too — pinning must
  # never silently remove a hop it cannot report — and stays unpermitted anyway.
  defp pin_chain([lead | rest] = chain, granted, true) do
    if pinnable?(chain, granted) do
      {kept, dropped} = Enum.split_with(rest, &hop_permitted?(&1, granted))
      # Deduplicated: a chain can carry one provider twice (two models, two base
      # URLs), and "failover to openai, openai" reads like a bug.
      {[lead | kept], dropped |> Enum.map(&hop_provider/1) |> Enum.uniq()}
    else
      {chain, []}
    end
  end

  defp pin_chain(chain, _granted, _pinning?), do: {chain, []}

  defp pinnable?([lead | _rest] = chain, granted),
    do: hop_permitted?(lead, granted) and Enum.all?(chain, &classifiable?/1)

  defp classifiable?(hop) do
    case hop_provider(hop) do
      provider when is_atom(provider) and not is_nil(provider) -> true
      _unclassifiable -> false
    end
  end

  defp hop_provider(hop), do: hop |> route_key() |> Map.get(:provider)

  # The provider set trusted for HISTORY egress: the Tier-2 grants PLUS — when the
  # default summarizer is in force (§22.1) — BOTH the summarizer's provider (the
  # subagent tier, which reads raw activity) and the PRIMARY provider (the chain
  # a recall turn actually runs on). The enable act discloses both; granting only
  # the summarizer's provider left every owner turn unsurfaceable whenever a
  # `subagent_provider` differed from the primary. Tier 1 (`:local`) and Tier 3
  # (`{:provider, _}`) keep explicit grants only — the primary must be named in
  # `remote_summaries` for history to surface in chat. One resolver so recall (the
  # snapshot), the turn chain (pinning) and taint masking
  # (`chain_permits_history?/1`) never disagree about those providers.
  defp effective_history_granted(config) do
    base = Config.granted_providers(config)

    # Gated on `enabled?`: the auto-grant is a CONSEQUENCE of running the default
    # summarizer, not an explicit grant — so it lapses the moment history is
    # disabled, reverting taint masking to the explicit Tier-2 grants only (§13.6:
    # a tainted turn must not reach an ungranted-remote provider after disabling).
    with true <- Config.enabled?(config),
         :default_provider <- Config.summarizer(config) do
      base
      |> put_resolved(Config.default_summarizer_provider())
      |> put_resolved(PrimaryConfig.primary())
    else
      _ -> base
    end
  end

  # An unresolved provider (no primary, or an ambiguous one) adds nothing.
  defp put_resolved(granted, {:ok, provider}) when is_atom(provider) and not is_nil(provider),
    do: MapSet.put(granted, provider)

  defp put_resolved(granted, {:error, _reason}), do: granted

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

  @doc """
  The chain posture the operator surfaces render — `/history status`, the
  `computer history` doctor row and the setup card (§9.4 "enabled but
  unsurfaceable", the failure that used to be silent). Builds the snapshot an
  attended owner turn would get and reduces it to one state:

    * `:pinned` — history surfaces; `routes` is the effective chain and
      `dropped` the failover hops that are off while history is on;
    * `:unsurfaceable` — the chain's LEAD is not granted, so nothing surfaces in
      chat (the lead may be a fallback: `Selection` skips an unconfigured primary);
    * `:unclassifiable_chain` — a hop names no provider id, so the chain cannot be
      classified at all; a grant would not fix it;
    * `:off` — history is disabled, or the host is not macOS;
    * `:no_chain` — the provider chain could not be built (a config error).

  `opts` carries `snapshot/2`'s `:macos?`/`:config` seams plus `:routes`, which
  takes `Selection.ordered_routes/0`'s own return shape so a tree-less CLI verb
  or a test passes a chain instead of resolving one.
  """
  @spec chain_posture(keyword()) :: posture()
  def chain_posture(opts \\ []) when is_list(opts) do
    config = Keyword.get_lazy(opts, :config, &Config.current/0)
    routes = Keyword.get_lazy(opts, :routes, &Selection.ordered_routes/0)

    %{
      source_trust: :operator,
      computer_use_origin: :interactive,
      ordered_routes: resolved_chain(routes)
    }
    |> snapshot(Keyword.take(opts, [:macos?]) ++ [config: config])
    |> posture(Config.summarizer(config))
  end

  @doc """
  The one sentence for a posture, so `/history status` and the doctor row never
  describe the same state in two different ways.
  """
  @spec chain_posture_sentence(posture()) :: String.t()
  def chain_posture_sentence(%{state: :off}),
    do: "Chat: nothing surfaces in replies while history is off."

  def chain_posture_sentence(%{state: :no_chain}),
    do:
      "Chat: the provider chain could not be built, so history cannot surface; " <>
        "fix the provider configuration."

  def chain_posture_sentence(%{state: :pinned, routes: routes, dropped: []}),
    do: "Chat: history turns run on #{provider_list(routes)}."

  def chain_posture_sentence(%{state: :pinned, routes: routes, dropped: dropped}),
    do:
      "Chat: history turns run on #{provider_list(routes)}; failover to " <>
        "#{provider_list(dropped)} is off while history is on."

  def chain_posture_sentence(%{state: :unclassifiable_chain}),
    do:
      "Chat: history cannot surface — the chat chain has a hop without a provider " <>
        "id; check [fermix_core.providers]."

  def chain_posture_sentence(%{state: :unsurfaceable} = posture),
    do:
      ~s(Chat: history cannot surface — the lead of your chat chain #{posture.lead} ) <>
        ~s(is not granted; add remote_summaries = ["#{posture.lead}"]) <>
        summarizer_advice(posture.summarizer)

  # Only worth saying when it would change something: under the default summarizer
  # that posture is already in force (and already grants its provider and the
  # primary), so repeating it as a remedy sends the operator in a circle.
  defp summarizer_advice(:default_provider), do: "."
  defp summarizer_advice(_other), do: ~s( or use summarizer = "default".)

  defp resolved_chain({:ok, routes}), do: routes
  defp resolved_chain({:error, _reason}), do: nil

  defp posture(%Snapshot{} = snapshot, summarizer) do
    %{
      state: posture_state(snapshot),
      lead: hop_provider_or_nil(snapshot.chain),
      routes: chain_providers(snapshot.routes),
      dropped: snapshot.dropped_hops,
      summarizer: summarizer
    }
  end

  defp posture_state(%Snapshot{operative?: false}), do: :off

  defp posture_state(%Snapshot{chain: [_hop | _rest] = chain} = snapshot) do
    cond do
      not Enum.all?(chain, &classifiable?/1) -> :unclassifiable_chain
      snapshot.chain_ok? -> :pinned
      true -> :unsurfaceable
    end
  end

  defp posture_state(%Snapshot{}), do: :no_chain

  defp hop_provider_or_nil([lead | _rest]), do: hop_provider(lead)
  defp hop_provider_or_nil(_absent), do: nil

  # `posture.routes` is a provider list the surfaces render, so a hop that names
  # no provider id is `:unknown` rather than a stray string in an atom list.
  defp chain_providers(routes) when is_list(routes), do: Enum.map(routes, &named_provider/1)
  defp chain_providers(_absent), do: []

  defp named_provider(hop) do
    case hop_provider(hop) do
      provider when is_atom(provider) and not is_nil(provider) -> provider
      _unclassifiable -> :unknown
    end
  end

  defp provider_list(providers), do: Enum.map_join(providers, ", ", &to_string/1)

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
