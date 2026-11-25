defmodule FermixCore.Jobs.FailureTest do
  # M106 §5.2: a failed run's kind is read from its reason term, never from its
  # text, and whether the provider failed is decided by code. The terms below
  # are the ones that reach a run's settle: built by the provider modules'
  # own constructors, or the shapes the runner and the agent loop return.
  use ExUnit.Case, async: true

  alias FermixCore.Jobs.Failure
  alias FermixCore.Providers.Error, as: ProviderError

  defp api(status, body \\ %{}), do: ProviderError.api(:openai, :responses, status, body)
  defp transport(reason), do: ProviderError.transport(:anthropic, :messages, reason)

  defp hand_built_api(kind, status) do
    {:provider_error,
     %{
       provider: :openai,
       adapter: :openai,
       status: status,
       kind: kind,
       code: nil,
       message: "x",
       stage: :unknown
     }}
  end

  # Finch's own words when its pool has no connection to give.
  @pool_empty %RuntimeError{
    message:
      "Finch was unable to provide a connection within the timeout due to excess queuing " <>
        "for connections."
  }

  describe "kind/1" do
    test "a provider's failure takes its kind from the provider error's own kind" do
      for {reason, kind} <- [
            {api(429), :provider_rate_limit},
            {api(402), :provider_quota},
            {api(400, %{"error" => %{"message" => "Your credit balance is too low."}}),
             :provider_quota},
            {api(401), :provider_auth},
            {api(403), :provider_auth},
            {ProviderError.auth(:openai, :responses, "No API key is configured."),
             :provider_auth},
            {api(503), :provider_unavailable},
            {api(529, %{"error" => %{"message" => "Overloaded"}}), :provider_unavailable},
            {hand_built_api(:provider, 500), :provider_unavailable},
            {api(408), :provider_timeout},
            {transport(:timeout), :provider_timeout},
            {transport(:closed), :provider_transport},
            {transport(:econnrefused), :provider_transport},
            {transport(:connection_unavailable), :provider_transport},
            {transport(:proxy_unreachable), :provider_transport},
            {transport({:tls_alert, :bad_certificate}), :provider_transport},
            {@pool_empty, :provider_transport},
            {{:no_route, "scheduled job route selection failed: :no_primary"}, :no_route},
            {:no_routes, :no_route}
          ] do
        assert Failure.kind(reason) == kind, "#{inspect(reason)} should be #{kind}"
      end
    end

    test "a failover chain's kind is its last route's" do
      assert Failure.kind({:all_routes_failed, [{:openai, api(401)}, {:xai, api(429)}]}) ==
               :provider_rate_limit

      assert Failure.kind({:all_routes_failed, [{:openai, api(429)}, {:xai, transport(:closed)}]}) ==
               :provider_transport

      assert Failure.kind({:all_routes_failed, [{:openai, api(429)}, {:xai, :empty_body}]}) ==
               :other
    end

    test "the runner's watchdog, its checks before the loop, and the agent loop" do
      for {reason, kind} <- [
            {{:time_limit, 600_000}, :time_limit},
            {{:idle_limit, 90_000}, :idle_limit},
            {{:unknown_skill, "harbour_tides"}, :unknown_skill},
            {{:tools_unavailable, "This job can't use shell: ..."}, :tools_unavailable},
            {{:skill_grants_nothing, "Skill tides asks only for ..."}, :skill_grants_nothing},
            {{:context_recovery_failed, :empty_summary}, :context_recovery},
            {{:context_recovery_failed, api(503)}, :context_recovery},
            {{:agent_loop_exit, %RuntimeError{message: "adapter exploded"}}, :crashed},
            {{:agent_loop_exit, :killed}, :crashed},
            {{:tool_start_unrecorded, :repo_timeout}, :tool_start_unrecorded}
          ] do
        assert Failure.kind(reason) == kind, "#{inspect(reason)} should be #{kind}"
      end
    end

    # The loop detector and the iteration cap still return a sentence, and a
    # sentence is never read: they are `other`, with their text kept on the row.
    test "a reason the list does not name is other" do
      for reason <- [
            "Repeated tool call loop detected: web_fetch with {} reached 6 repeats",
            "Maximum iterations (50) reached",
            "Prompt setup error",
            :context_overflow_after_compaction,
            :context_length_exceeded,
            {:cue_history_lost, "Skill tides leaves a watcher's task without cue_history"},
            {:cue_run_context, :not_found},
            {:follow_up_trigger, :no_trigger},
            api(400),
            hand_built_api(:plan_not_eligible, 403),
            hand_built_api(:invalid_request, 400),
            ProviderError.not_implemented(:openai, :responses),
            %RuntimeError{message: "adapter exploded"},
            {:all_routes_failed, []},
            {:time_limit, "600000"}
          ] do
        assert Failure.kind(reason) == :other, "#{inspect(reason)} should be other"
      end
    end

    test "every kind it returns is on the closed list" do
      assert :other in Failure.kinds()
      assert :crashed in Failure.kinds()
      assert :reaped in Failure.kinds()
      assert Failure.kind({:time_limit, 1}) in Failure.kinds()
    end
  end

  describe "stored/1" do
    test "a kind on the list is stored as its name, and any other atom is refused" do
      assert Failure.stored(:time_limit) == "time_limit"
      assert Failure.stored(:reaped) == "reaped"
      assert Failure.stored(:provider_rate_limit) == "provider_rate_limit"

      assert_raise FunctionClauseError, fn -> Failure.stored(:timeout) end
    end
  end

  # The cue run's rule (design §9.4), moved here unchanged: the run kinds share
  # one answer to whether the provider failed.
  describe "provider_failure?/1" do
    test "a transport error, a rate limit, an exhausted account, a 5xx, a timeout, no route" do
      for reason <- [
            transport(:timeout),
            transport(:connection_unavailable),
            transport(:closed),
            api(429),
            api(402),
            api(503),
            hand_built_api(:provider, 500),
            api(408),
            {:all_routes_failed, [{:openai, api(429)}, {:anthropic, transport(:econnrefused)}]},
            {:context_recovery_failed, api(502)},
            {:no_route, "scheduled job route selection failed: :no_primary"},
            :no_routes,
            @pool_empty
          ] do
        assert Failure.provider_failure?(reason), "#{inspect(reason)} should be the provider's"
      end
    end

    test "a sign-in failure, a refused request, and every failure of the run's own is not" do
      for reason <- [
            api(401),
            ProviderError.auth(:openai, :responses, "No API key is configured."),
            api(400),
            hand_built_api(:invalid_request, 400),
            {:all_routes_failed, [{:openai, api(429)}, {:anthropic, api(401)}]},
            {:context_recovery_failed, :empty_summary},
            {:agent_loop_exit, :killed},
            {:tool_start_unrecorded, :repo_timeout},
            {:time_limit, 600_000},
            {:unknown_skill, "harbour_tides"},
            "Maximum iterations (50) reached",
            %RuntimeError{message: "adapter exploded"},
            :context_overflow_after_compaction
          ] do
        refute Failure.provider_failure?(reason),
               "#{inspect(reason)} should not be the provider's"
      end
    end
  end

  # M106 §5.4: the question a heal's subject turns on, of a stored kind. Not
  # the retry's question: a sign-in failure is one no model run can help with,
  # and still not a failure waiting clears.
  describe "model_cannot_help?/1" do
    test "every provider kind and no route, a sign-in failure included; no other" do
      cannot_help =
        ~w(provider_rate_limit provider_quota provider_auth provider_unavailable
           provider_timeout provider_transport no_route)a

      for kind <- Failure.kinds() do
        expected = kind in cannot_help
        assert {kind, Failure.model_cannot_help?(kind)} == {kind, expected}
        assert {kind, Failure.model_cannot_help?(Failure.stored(kind))} == {kind, expected}
      end

      refute Failure.provider_failure?(ProviderError.auth(:openai, :responses, "no key"))

      assert Failure.model_cannot_help?(
               Failure.kind(ProviderError.auth(:openai, :responses, "no key"))
             )
    end

    test "a text no kind stores is no kind" do
      refute Failure.model_cannot_help?("provider_said_no")
    end
  end

  describe "sentence/1" do
    test "a run the Scheduler settled, or stopped before a tool it could not record, is told in a sentence of its own" do
      for kind <- [:crashed, :reaped, :tool_start_unrecorded] do
        sentence = Failure.sentence(kind)
        assert sentence =~ ~r/^The run .+\.$/
        refute sentence =~ "reaped"
      end
    end

    # M106 §6 (stage S5): no reason maps to it; the settle of an ok run gives
    # it to the heal its trigger opens, and a model could help with it.
    test "a run that ended ok without working has a kind and a sentence of its own" do
      assert :tool_never_succeeded in Failure.kinds()
      assert Failure.stored(:tool_never_succeeded) == "tool_never_succeeded"
      refute Failure.model_cannot_help?(:tool_never_succeeded)

      sentence = Failure.sentence(:tool_never_succeeded)
      assert sentence =~ "every call"
      assert sentence =~ "last 3 runs"
      assert sentence =~ ~r/without an error\.$/
    end
  end

  # M106 §5.2, §5.8 (stage S4, round two): every kind on the closed list has
  # one plain sentence, built by code from the tagged reason, and none can
  # reach a generic line. The reasons below are one of each kind, as they
  # reach a run's settle; the table must name every kind on the list.
  describe "sentence/2: one plain sentence for every kind" do
    test "the table names every kind on the closed list, and each its own reason" do
      assert Enum.sort(Map.keys(reasons())) == Enum.sort(Failure.kinds())

      for {kind, reason} <- reasons(), kind not in [:reaped, :tool_never_succeeded] do
        assert Failure.kind(reason) == kind, "#{inspect(reason)} should be #{kind}"
      end
    end

    test "every kind's sentence is one plain sentence of its own, never a generic line" do
      sentences = Map.new(reasons(), fn {kind, reason} -> {kind, Failure.sentence(reason)} end)

      for {kind, sentence} <- sentences do
        assert sentence =~ ~r/^[A-Z].*[.]$/s, "#{kind}: #{inspect(sentence)}"
        refute sentence =~ "The run failed with an error", "#{kind}"
        refute sentence =~ ~r/\{:|%\{|ms\b/, "#{kind}: #{inspect(sentence)}"
      end

      assert sentences |> Map.values() |> Enum.uniq() |> length() == map_size(sentences)
    end

    test "a limit is stated in minutes, with the tool still running when there was one" do
      assert Failure.sentence({:time_limit, 600_000}) ==
               "The run stopped at its 10-minute time limit."

      assert Failure.sentence({:time_limit, 600_000}, in_flight: "web_fetch") ==
               ~s(The run stopped at its 10-minute time limit while its tool "web_fetch" ) <>
                 "was still running."

      assert Failure.sentence({:idle_limit, 300_000}) ==
               "The run stopped after 5 minutes with nothing happening."

      assert Failure.sentence({:time_limit, 90_000}) ==
               "The run stopped at its 90-second time limit."

      assert Failure.sentence({:time_limit, 1_000}) ==
               "The run stopped at its 1-second time limit."
    end

    test "a missing skill is named, a check's own sentence is stated, and a provider is named" do
      assert Failure.sentence({:unknown_skill, "lantern-rota-digest"}) ==
               ~s(The run could not start: the skill "lantern-rota-digest" it is bound to ) <>
                 "does not exist."

      assert Failure.sentence(reasons().tools_unavailable) ==
               "The job's tools are not available: tide_lookup is turned off."

      assert Failure.sentence(api(429)) == "OpenAI is limiting this account's requests."
      assert Failure.sentence(transport(:econnrefused)) == "Fermix could not reach Anthropic."
      assert Failure.sentence(@pool_empty) == "Fermix could not reach the model provider."
    end

    test "other is said to be other, and its text is kept for the row and quoted as its own" do
      assert Failure.sentence("Maximum iterations (100) reached") ==
               "The run stopped on an error Fermix has no sentence of its own for."

      assert Failure.other_text("Maximum iterations (100) reached") ==
               "Maximum iterations (100) reached"

      assert Failure.other_text({:cue_history_lost, "Skill plugin_helper drops cue_history."}) ==
               "Skill plugin_helper drops cue_history."

      assert Failure.other_text(:context_overflow_after_compaction) ==
               ":context_overflow_after_compaction"
    end
  end

  # A sentence must never be what takes a run's settle down: every kind
  # crossed with a reason of the wrong shape gets a sentence, the kind's
  # plainest, and a kind off the list gets other's.
  describe "the sentence is total" do
    @wrong [
      nil,
      :wrong,
      "text",
      42,
      %{},
      [],
      {:time_limit, "ten minutes"},
      {:idle_limit, nil},
      {:unknown_skill, 7},
      {:tools_unavailable, :gone},
      {:skill_grants_nothing, nil},
      {:provider_error, :x},
      {:no_route, 1}
    ]

    test "every kind crossed with a reason of the wrong shape gets a sentence" do
      for kind <- Failure.kinds(), reason <- @wrong, in_flight <- [nil, "web_fetch", 7] do
        sentence = Failure.kind_sentence(kind, reason, in_flight: in_flight)
        assert sentence =~ ~r/^[A-Z].*[.]$/s, "#{kind} #{inspect(reason)}: #{inspect(sentence)}"
      end

      for reason <- @wrong, do: assert(Failure.sentence(reason, in_flight: 7) =~ ~r/[.]$/)
    end

    test "a reason of the wrong shape gets its kind's plainest sentence" do
      assert Failure.kind_sentence(:time_limit, :wrong) == "The run stopped at its time limit."

      assert Failure.kind_sentence(:idle_limit, nil) ==
               "The run stopped after too long with nothing happening."

      assert Failure.kind_sentence(:unknown_skill, 7) ==
               "The run could not start: the skill it is bound to does not exist."

      assert Failure.kind_sentence(:tools_unavailable, :gone) ==
               "The run could not start: the tools the job names are not available to it."

      assert Failure.kind_sentence(:skill_grants_nothing, nil) ==
               "The run could not start: the skill it is bound to grants it no tool it can use."

      assert Failure.kind_sentence(:provider_quota, :x) ==
               "The model provider says this account is out of credit or over its usage limit."

      assert Failure.kind_sentence(:not_a_kind, :x) == Failure.sentence(:other)
    end
  end

  # One reason of each kind, as it reaches a run's settle.
  defp reasons do
    %{
      provider_rate_limit: api(429),
      provider_quota: api(402),
      provider_auth: api(401),
      provider_unavailable: api(503),
      provider_timeout: transport(:timeout),
      provider_transport: transport(:econnrefused),
      no_route: {:no_route, "scheduled job route selection failed: :no_primary"},
      time_limit: {:time_limit, 600_000},
      idle_limit: {:idle_limit, 300_000},
      unknown_skill: {:unknown_skill, "lantern-rota-digest"},
      tools_unavailable:
        {:tools_unavailable, "The job's tools are not available: tide_lookup is turned off."},
      skill_grants_nothing:
        {:skill_grants_nothing, "Skill quay-notes asks only for classes the job cannot have."},
      context_recovery: {:context_recovery_failed, :empty_summary},
      crashed: {:agent_loop_exit, {%RuntimeError{message: "adapter exploded"}, []}},
      reaped: :reaped,
      tool_start_unrecorded: {:tool_start_unrecorded, :busy},
      tool_never_succeeded: :tool_never_succeeded,
      other: "Maximum iterations (100) reached"
    }
  end
end
