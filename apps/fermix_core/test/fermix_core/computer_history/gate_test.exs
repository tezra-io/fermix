defmodule FermixCore.ComputerHistory.GateTest do
  @moduledoc """
  MILESTONE_32 §9 — the single resolver. Covers the whole-chain rule (§9.2),
  per-hop locality (§9.3), owner-only/attended trust (Decision 7), the provider
  tiers (§9.4), and the always-false telemetry sink (Decision 9). All snapshots
  inject `macos?: true` so the suite is hermetic on Linux CI.
  """
  use ExUnit.Case, async: false

  alias FermixCore.ComputerHistory.Gate

  # --- fixtures -----------------------------------------------------------

  defp local_route, do: {%{provider: :ollama, base_url: "http://localhost:11434/v1"}, []}
  defp non_loopback_ollama, do: {%{provider: :ollama, base_url: "http://10.0.0.5:11434/v1"}, []}

  defp remote_route(provider),
    do: {%{provider: provider, base_url: "https://api.#{provider}.example/v1"}, []}

  # An operator, attended, top-level turn (no depth keys ⇒ top-level).
  defp operator_ctx(chain),
    do: %{source_trust: :operator, computer_use_origin: :interactive, ordered_routes: chain}

  defp guest_ctx(chain),
    do: %{source_trust: :guest, computer_use_origin: :interactive, ordered_routes: chain}

  defp worker_ctx(chain),
    do: %{
      source_trust: :operator,
      computer_use_origin: :interactive,
      subagent_depth: 1,
      ordered_routes: chain
    }

  defp unattended_ctx(chain),
    do: %{source_trust: :operator, computer_use_origin: :unattended, ordered_routes: chain}

  setup do
    original = Application.get_env(:fermix_core, :computer_history)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:fermix_core, :computer_history)
        value -> Application.put_env(:fermix_core, :computer_history, value)
      end
    end)

    :ok
  end

  # Pin the summarizer to `:local` unless a test sets it, so the default
  # (`:default_provider`, §22.1) — which grants the primary provider — never
  # pollutes the granted set for the chain/realtime tests. Summarizer-target tests
  # set `summarizer:` explicitly and are unaffected.
  defp enable(kw) do
    kw = Keyword.put_new(kw, :summarizer, :local)
    Application.put_env(:fermix_core, :computer_history, [enabled: true] ++ kw)
  end

  defp snap(ctx), do: Gate.snapshot(ctx, macos?: true)

  # Pin every env key `Config.default_summarizer_provider/0` reads so the
  # resolved primary is :openai regardless of what ran before, restoring the
  # run's ambient values afterwards.
  defp establish_primary_openai do
    for {key, value} <- [
          routing: [],
          providers: [openai: [api_key: "test-key", primary: true]],
          agent: []
        ] do
      original = Application.get_env(:fermix_core, key)
      Application.put_env(:fermix_core, key, value)
      on_exit(fn -> restore_env(key, original) end)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore_env(key, kept), do: Application.put_env(:fermix_core, key, kept)

  # --- disabled / operative ----------------------------------------------

  describe "disabled or non-macOS" do
    test "every consumer sink is denied when disabled" do
      Application.put_env(:fermix_core, :computer_history, enabled: false)
      s = snap(operator_ctx([local_route()]))

      refute Gate.allow?(s, {:prompt_section, %{}})
      refute Gate.allow?(s, {:tool_advertise, %{}})
      refute Gate.allow?(s, {:tool_execute, %{}})
      refute Gate.allow?(s, {:llm_chain, [local_route()]})
      refute Gate.allow?(s, {:summarizer, local_route()})
      refute Gate.allow?(s, {:realtime_session, :openai})
    end

    test "enabled config on a non-macOS host is inert" do
      enable([])
      s = Gate.snapshot(operator_ctx([local_route()]), macos?: false)
      refute Gate.allow?(s, {:prompt_section, %{}})
      refute Gate.allow?(s, {:llm_chain, [local_route()]})
    end
  end

  # --- totality: malformed input denies, never crashes (§9.1) ------------

  describe "allow?/2 is total on malformed input" do
    test "a malformed summarizer route denies without crashing" do
      enable([])
      s = snap(operator_ctx([local_route()]))
      refute Gate.allow?(s, {:summarizer, nil})
      # A route_key missing :provider.
      refute Gate.allow?(s, {:summarizer, %{base_url: "http://localhost:11434/v1"}})
    end

    test "a chain hop with a non-atom provider denies without crashing" do
      enable([])
      chain = [%{provider: "ollama", base_url: "http://localhost:11434/v1"}]
      s = snap(operator_ctx(chain))
      refute Gate.allow?(s, {:llm_chain, chain})
    end

    test "an unknown sink denies" do
      enable([])
      s = snap(operator_ctx([local_route()]))
      refute Gate.allow?(s, {:something_unknown, %{}})
    end
  end

  # --- the replay/compaction sink (§13.6) --------------------------------

  describe "history_replay — the taint's replay sink" do
    test "mirrors chain_permits_history?/1 for the same grants" do
      enable(remote_summaries: [:anthropic])
      s = snap(operator_ctx([local_route()]))

      for chain <- [
            [local_route()],
            [remote_route(:anthropic)],
            [remote_route(:openai)],
            [local_route(), remote_route(:openai)],
            [non_loopback_ollama()],
            nil,
            []
          ] do
        assert Gate.allow?(s, {:history_replay, chain}) == Gate.chain_permits_history?(chain),
               "history_replay disagreed with chain_permits_history? on #{inspect(chain)}"
      end
    end

    test "is independent of operative? — a disabled feature still permits a local chain" do
      # The taint is a property of the message's ORIGIN, so masking must keep
      # working after `/history off`: the sink answers "may a tainted message
      # ride this chain", never "is the feature on". `{:llm_chain, _}` is false
      # in that posture, which is exactly why the taint cannot reuse it.
      enable([])
      s = snap(operator_ctx([local_route()]))
      Application.put_env(:fermix_core, :computer_history, enabled: false)
      disabled = snap(operator_ctx([local_route()]))

      assert Gate.allow?(s, {:history_replay, [local_route()]})
      assert Gate.allow?(disabled, {:history_replay, [local_route()]})
      refute Gate.allow?(disabled, {:llm_chain, [local_route()]})
    end

    test "an ungranted-remote hop denies; a granted one is permitted" do
      enable(remote_summaries: [:anthropic])
      s = snap(operator_ctx([local_route()]))

      assert Gate.allow?(s, {:history_replay, [remote_route(:anthropic)]})
      refute Gate.allow?(s, {:history_replay, [remote_route(:openai)]})
      refute Gate.allow?(s, {:history_replay, [remote_route(:anthropic), remote_route(:openai)]})
    end

    test "a nil, empty, or malformed chain fails closed" do
      enable([])
      s = snap(operator_ctx([local_route()]))

      refute Gate.allow?(s, {:history_replay, nil})
      refute Gate.allow?(s, {:history_replay, []})
      refute Gate.allow?(s, {:history_replay, [%{base_url: "http://localhost:11434/v1"}]})
      refute Gate.allow?(s, {:history_replay, :not_a_chain})
    end

    test "the frozen grant set wins over a mid-turn grant edit" do
      enable(remote_summaries: [:anthropic])
      s = snap(operator_ctx([local_route()]))

      Application.put_env(:fermix_core, :computer_history,
        enabled: true,
        summarizer: :local,
        remote_summaries: []
      )

      assert Gate.allow?(s, {:history_replay, [remote_route(:anthropic)]})
      refute Gate.chain_permits_history?([remote_route(:anthropic)])
    end
  end

  # --- the whole-chain rule (§9.2) ---------------------------------------

  describe "llm_chain — the whole-chain rule" do
    test "an all-local chain is permitted under local_only" do
      enable([])
      s = snap(operator_ctx([local_route()]))
      assert Gate.allow?(s, {:llm_chain, [local_route()]})
    end

    test "any ungranted-remote hop denies the whole turn" do
      enable([])
      s = snap(operator_ctx([remote_route(:anthropic), local_route()]))
      # Even though the chain ENDS local (Ollama last), a remote lead denies it.
      refute Gate.allow?(s, {:llm_chain, [remote_route(:anthropic), local_route()]})
    end

    test "the raw chain of a LOCAL lead with an ungranted-remote TAIL is denied (the resolved-head trap)" do
      # The realistic dangerous config: Ollama PRIMARY, remote fallback. The
      # resolved head is local, but failover re-sends to the identical messages
      # to the remote tail, so the chain AS GIVEN is denied. A regression that
      # trusted the head would pass every other test in this file — this is the
      # one that catches it. On an attended owner turn the ungranted tail is
      # pinned away instead (below), which is what makes the section legal there;
      # the sink itself never softens.
      enable([])
      chain = [local_route(), remote_route(:openai)]
      s = snap(operator_ctx(chain))
      refute Gate.allow?(s, {:llm_chain, chain})
    end

    test "an ungranted-remote TAIL keeps the section absent on a turn that cannot be pinned" do
      # A guest turn is never pinned (§9.4), so the whole-chain rule decides and
      # the consumer surfaces stay closed even though the lead is local.
      enable([])
      chain = [local_route(), remote_route(:openai)]
      s = snap(guest_ctx(chain))
      refute s.chain_ok?
      refute Gate.allow?(s, {:prompt_section, %{}})
      refute Gate.allow?(s, {:tool_advertise, %{}})
    end

    test "a remote-declared provider at a loopback URL is still remote" do
      # The "declared AND loopback" conjunct, exercised on the declaration side:
      # a remote provider pointed at localhost does not become local.
      enable([])
      chain = [{%{provider: :anthropic, base_url: "http://localhost:8080/v1"}, []}]
      s = snap(operator_ctx(chain))
      refute Gate.allow?(s, {:llm_chain, chain})
    end

    test "a remote hop that is granted (Tier 2) is permitted" do
      enable(remote_summaries: [:anthropic])
      s = snap(operator_ctx([remote_route(:anthropic), local_route()]))
      assert Gate.allow?(s, {:llm_chain, [remote_route(:anthropic), local_route()]})
    end

    test "a granted remote hop plus an UNgranted remote hop is still denied" do
      enable(remote_summaries: [:anthropic])
      chain = [remote_route(:anthropic), remote_route(:openai)]
      s = snap(operator_ctx(chain))
      refute Gate.allow?(s, {:llm_chain, chain})
    end

    test "a local-declared provider at a non-loopback URL is remote (unverifiable)" do
      enable([])
      s = snap(operator_ctx([non_loopback_ollama()]))
      refute Gate.allow?(s, {:llm_chain, [non_loopback_ollama()]})
    end

    test "a nil or empty chain is denied (unverifiable, fail closed)" do
      enable([])
      refute Gate.allow?(snap(operator_ctx(nil)), {:llm_chain, nil})
      refute Gate.allow?(snap(operator_ctx([])), {:llm_chain, []})
    end
  end

  # --- consumer surfaces: trust + chain ----------------------------------

  describe "section / tool surfaces require attended operator AND a permitted chain" do
    test "operator + all-local chain ⇒ section and tools available" do
      enable([])
      s = snap(operator_ctx([local_route()]))
      assert Gate.allow?(s, {:prompt_section, %{}})
      assert Gate.allow?(s, {:tool_advertise, %{}})
      assert Gate.allow?(s, {:tool_execute, %{}})
    end

    test "a guest sender never triggers the section or the tool (inv. 4/5)" do
      enable([])
      s = snap(guest_ctx([local_route()]))
      refute Gate.allow?(s, {:prompt_section, %{}})
      refute Gate.allow?(s, {:tool_advertise, %{}})
      refute Gate.allow?(s, {:tool_execute, %{}})
      # The chain itself is still local — trust is the separate gate.
      assert Gate.allow?(s, {:llm_chain, [local_route()]})
    end

    test "a subagent worker turn fails closed (inv. 5)" do
      enable([])
      s = snap(worker_ctx([local_route()]))
      refute Gate.allow?(s, {:prompt_section, %{}})
      refute Gate.allow?(s, {:tool_execute, %{}})
    end

    test "an unattended (background) origin fails closed for every consumer sink" do
      enable([])
      s = snap(unattended_ctx([local_route()]))
      refute Gate.allow?(s, {:prompt_section, %{}})
      refute Gate.allow?(s, {:tool_advertise, %{}})
      refute Gate.allow?(s, {:tool_execute, %{}})
    end

    test "operator on an ungranted-remote chain: section absent (chain rule, inv. 3)" do
      enable([])
      s = snap(operator_ctx([remote_route(:anthropic)]))
      refute Gate.allow?(s, {:prompt_section, %{}})
      refute Gate.allow?(s, {:tool_advertise, %{}})
    end
  end

  # --- summarizer route (§9.4, inv. 1 / 1b) ------------------------------

  describe "summarizer route" do
    test "local target permits a local route, denies any remote route" do
      enable([])
      s = snap(operator_ctx([local_route()]))
      assert Gate.allow?(s, {:summarizer, local_route()})
      refute Gate.allow?(s, {:summarizer, remote_route(:anthropic)})
    end

    test "default_provider permits the primary provider's route + grants it for recall (§22.1)" do
      # The default: summarize on the daemon's primary provider. The snapshot
      # resolves the primary, permits its summarizer route, AND grants it so recall
      # rides the same provider consistently.
      #
      # The primary is resolved from three GLOBAL env keys (routing subagent
      # override → providers primary flag → legacy agent.provider), and an
      # earlier module can leak any of them (CI 2026-08-26: a leaked override
      # resolved :openrouter here). A test asserting the resolved primary must
      # establish all three, not read whatever the run left behind.
      establish_primary_openai()
      enable(summarizer: :default_provider)
      s = snap(operator_ctx([remote_route(:openai)]))

      assert s.summarizer_target == {:provider, :openai}
      assert Gate.allow?(s, {:summarizer, remote_route(:openai)})
      # A different vendor is still not the resolved primary.
      refute Gate.allow?(s, {:summarizer, remote_route(:anthropic)})
      # The primary is granted, so an all-primary turn chain permits recall.
      assert MapSet.member?(s.granted, :openai)
      assert Gate.allow?(s, {:llm_chain, [remote_route(:openai)]})
    end

    test "Tier-3 pins to exactly the named provider (inv. 1b — no failover to another vendor)" do
      enable(summarizer: :anthropic)
      s = snap(operator_ctx([remote_route(:anthropic)]))
      assert Gate.allow?(s, {:summarizer, remote_route(:anthropic)})
      # A different vendor — even a failover target — is denied.
      refute Gate.allow?(s, {:summarizer, remote_route(:openai)})
      # And the local route is not the Tier-3 target either.
      refute Gate.allow?(s, {:summarizer, local_route()})
    end
  end

  # --- realtime voice (§11.3) --------------------------------------------

  describe "realtime session" do
    test "a remote voice provider is denied under Tier 1, permitted under a Tier-2 grant" do
      enable([])
      s1 = snap(operator_ctx([local_route()]))
      refute Gate.allow?(s1, {:realtime_session, :openai})

      enable(remote_summaries: [:openai])
      s2 = snap(operator_ctx([local_route()]))
      assert Gate.allow?(s2, {:realtime_session, :openai})
    end

    test "a guest never gets the voice tool even under a grant" do
      enable(remote_summaries: [:openai])
      s = snap(guest_ctx([local_route()]))
      refute Gate.allow?(s, {:realtime_session, :openai})
    end
  end

  # --- chain pinning for history-bearing owner turns (§9.4) ---------------

  describe "chain pinning" do
    test "an owner turn keeps the lead and the granted fallbacks, in order" do
      enable(remote_summaries: [:anthropic])

      chain = [
        remote_route(:anthropic),
        remote_route(:openai),
        local_route(),
        remote_route(:mistral)
      ]

      s = snap(operator_ctx(chain))

      assert s.routes == [remote_route(:anthropic), local_route()]
      assert s.dropped_hops == [:openai, :mistral]
      assert s.chain_ok?
      # `chain` stays the INPUT chain the taint/replay readers were handed.
      assert s.chain == chain
    end

    test "a chain that is already fully granted is left alone with no dropped hops" do
      enable(remote_summaries: [:anthropic])
      chain = [remote_route(:anthropic), local_route()]
      s = snap(operator_ctx(chain))

      assert s.routes == chain
      assert s.dropped_hops == []
      assert s.chain_ok?
    end

    test "a lead the grant set does not cover is never replaced" do
      # The load-bearing half of the rule: pinning narrows a permitted lead's
      # failover, it never promotes a granted fallback over the owner's primary.
      enable(remote_summaries: [:anthropic])
      chain = [remote_route(:openai), remote_route(:anthropic)]
      s = snap(operator_ctx(chain))

      assert s.routes == chain
      assert s.dropped_hops == []
      refute s.chain_ok?
    end

    test "history disabled leaves an ungranted chain untouched (failover semantics intact)" do
      Application.put_env(:fermix_core, :computer_history, enabled: false)
      chain = [remote_route(:anthropic), remote_route(:openai)]
      s = snap(operator_ctx(chain))

      assert s.routes == chain
      assert s.dropped_hops == []
      refute s.chain_ok?
    end

    test "a guest turn is never pinned" do
      enable(remote_summaries: [:anthropic])
      chain = [remote_route(:anthropic), remote_route(:openai)]
      s = snap(guest_ctx(chain))

      assert s.routes == chain
      assert s.dropped_hops == []
    end

    test "an unattended owner turn is never pinned" do
      enable(remote_summaries: [:anthropic])
      chain = [remote_route(:anthropic), remote_route(:openai)]
      s = snap(unattended_ctx(chain))

      assert s.routes == chain
      assert s.dropped_hops == []
    end

    test "a worker turn is never pinned" do
      enable(remote_summaries: [:anthropic])
      chain = [remote_route(:anthropic), remote_route(:openai)]
      s = snap(worker_ctx(chain))

      assert s.routes == chain
      assert s.dropped_hops == []
    end

    test "two ungranted hops on one provider are named once" do
      # A chain can carry the same provider twice (two models, two base URLs); the
      # sentence must read "failover to openai" once, not "openai, openai".
      enable(remote_summaries: [:anthropic])

      chain = [
        remote_route(:anthropic),
        remote_route(:openai),
        {%{provider: :openai, base_url: "https://api.openai.example/v2"}, []}
      ]

      s = snap(operator_ctx(chain))

      assert s.dropped_hops == [:openai]
    end

    test "a nil chain pins nothing (MainAgent's boot config-error path)" do
      enable(remote_summaries: [:anthropic])
      s = snap(operator_ctx(nil))

      assert s.routes == nil
      assert s.dropped_hops == []
      refute s.chain_ok?
    end

    test "a chain carrying an unclassifiable hop is never pinned and never surfaces" do
      # Fail closed rather than silently dropping a hop nobody can name: the
      # chain is left exactly as it is and history does not surface.
      enable(remote_summaries: [:anthropic])
      chain = [remote_route(:anthropic), %{provider: "openai"}]
      s = snap(operator_ctx(chain))

      assert s.routes == chain
      assert s.dropped_hops == []
      refute s.chain_ok?
    end
  end

  # --- the history grant set (§22.1) --------------------------------------

  describe "effective grant set" do
    test "the default summarizer grants BOTH the subagent provider and the primary" do
      # §22.1 folds the primary into the grant set; with a subagent provider
      # configured, the summarizer's provider and the primary differ, and a turn
      # runs on the primary — so granting only the summarizer's provider leaves
      # every owner turn unsurfaceable (the 2026-09-10 incident).
      establish_primary_openai()
      Application.put_env(:fermix_core, :routing, subagent_provider: :anthropic)
      enable(summarizer: :default_provider)

      s = snap(operator_ctx([remote_route(:openai)]))

      assert MapSet.member?(s.granted, :anthropic)
      assert MapSet.member?(s.granted, :openai)
      assert s.chain_ok?
    end

    test "Tier 1 (local summarizer) grants nothing implicitly" do
      establish_primary_openai()
      enable(summarizer: :local)

      s = snap(operator_ctx([remote_route(:openai)]))

      assert MapSet.size(s.granted) == 0
      refute s.chain_ok?
    end

    test "Tier 3 (a pinned provider) grants nothing implicitly" do
      establish_primary_openai()
      enable(summarizer: :anthropic)

      s = snap(operator_ctx([remote_route(:anthropic)]))

      assert MapSet.size(s.granted) == 0
      refute s.chain_ok?
    end
  end

  # --- chain posture, the status surfaces' one resolver (§9.4) ------------

  describe "chain_posture/1" do
    test "pinned names the lead, the effective chain, and the dropped hops" do
      enable(remote_summaries: [:openai_codex])
      chain = [remote_route(:openai_codex), remote_route(:openai), remote_route(:mistral)]

      posture = Gate.chain_posture(macos?: true, routes: {:ok, chain})

      assert posture.state == :pinned
      assert posture.lead == :openai_codex
      assert posture.routes == [:openai_codex]
      assert posture.dropped == [:openai, :mistral]

      sentence = Gate.chain_posture_sentence(posture)
      assert sentence =~ "history turns run on openai_codex"
      assert sentence =~ "failover to openai, mistral is off while history is on"
    end

    test "unsurfaceable names the LEAD of the chat chain and the grant that would surface it" do
      # "your primary" was wrong: `Selection` skips an unconfigured primary, so the
      # lead of the chain the turn actually runs on can be a fallback provider.
      enable(summarizer: :local)
      posture = Gate.chain_posture(macos?: true, routes: {:ok, [remote_route(:anthropic)]})

      assert posture.state == :unsurfaceable
      assert posture.lead == :anthropic

      sentence = Gate.chain_posture_sentence(posture)
      assert sentence =~ "history cannot surface"
      assert sentence =~ "the lead of your chat chain anthropic"
      refute sentence =~ "your primary anthropic"
      assert sentence =~ ~s(remote_summaries = ["anthropic"])
      assert sentence =~ ~s(summarizer = "default")
    end

    test "unsurfaceable omits the summarizer advice when the default summarizer is already on" do
      # Under `summarizer = "default"` the advice is a no-op: that posture already
      # grants the summarizer's provider and the primary, and the lead is neither.
      establish_primary_openai()
      enable(summarizer: :default_provider)
      posture = Gate.chain_posture(macos?: true, routes: {:ok, [remote_route(:mistral)]})

      assert posture.state == :unsurfaceable
      sentence = Gate.chain_posture_sentence(posture)

      assert sentence =~ "the lead of your chat chain mistral"
      assert sentence =~ ~s(remote_summaries = ["mistral"])
      refute sentence =~ ~s(summarizer = "default")
    end

    test "a hop with no provider id is its own posture, not a grant problem" do
      # Telling the operator to add a `remote_summaries` grant for a chain that
      # carries an unnameable hop sends them after the wrong config line.
      enable(remote_summaries: [:anthropic])
      chain = [remote_route(:anthropic), %{provider: "openai"}]

      posture = Gate.chain_posture(macos?: true, routes: {:ok, chain})

      assert posture.state == :unclassifiable_chain
      assert posture.lead == :anthropic
      assert posture.routes == [:anthropic, :unknown]

      sentence = Gate.chain_posture_sentence(posture)
      assert sentence =~ "a hop without a provider id"
      assert sentence =~ "[fermix_core.providers]"
      refute sentence =~ "remote_summaries"
    end

    test "off when history is disabled" do
      Application.put_env(:fermix_core, :computer_history, enabled: false)
      posture = Gate.chain_posture(macos?: true, routes: {:ok, [remote_route(:anthropic)]})

      assert posture.state == :off
      assert Gate.chain_posture_sentence(posture) =~ "history is off"
    end

    test "no_chain when the route chain could not be built" do
      enable(remote_summaries: [:anthropic])
      posture = Gate.chain_posture(macos?: true, routes: {:error, :multiple_primary})

      assert posture.state == :no_chain
      assert posture.lead == nil
      assert Gate.chain_posture_sentence(posture) =~ "provider chain"
    end

    test "off on a non-macOS host" do
      enable(remote_summaries: [:anthropic])
      posture = Gate.chain_posture(macos?: false, routes: {:ok, [remote_route(:anthropic)]})

      assert posture.state == :off
    end
  end
end
