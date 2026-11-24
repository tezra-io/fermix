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
            {{:agent_loop_exit, :killed}, :crashed}
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
end
