defmodule FermixCore.Providers.FailoverTest do
  use ExUnit.Case, async: true

  alias FermixCore.Providers.Error
  alias FermixCore.Providers.Failover

  describe "eligible?/1 — eligible kinds" do
    test "rate limit, quota, timeout, and provider-unavailable api errors are eligible" do
      for status <- [429, 402, 408, 503] do
        assert Failover.eligible?(Error.api(:openai, OpenAI, status, %{}))
      end
    end

    test "transport errors before any response are eligible" do
      assert Failover.eligible?(Error.transport(:openai, OpenAI, :timeout))
      assert Failover.eligible?(Error.transport(:openai, OpenAI, :closed))
      assert Failover.eligible?(Error.transport(:openai, OpenAI, :econnrefused))
    end

    test "a residual oauth auth failure is eligible (the adapter already refreshed)" do
      {:provider_error, error} = Error.api(:anthropic, Messages, 401, %{})

      assert Failover.eligible?({:provider_error, Map.put(error, :auth_mode, :oauth)})
    end

    test "an oauth refresh-machinery failure (status nil) is eligible" do
      {:provider_error, error} = Error.auth(:openai_codex, Codex, "refresh failed")

      assert Failover.eligible?({:provider_error, Map.put(error, :auth_mode, :oauth)})
    end

    test "the stage tag alone does not block kind-eligibility" do
      # The user-visible streaming boundary is owned by the agent loop's
      # emitted? gate; raw mid-stream chunks nobody saw (no stream callback,
      # or a callback that never emitted) must not strand a configured
      # fallback on jobs/review/compaction/non-streaming surfaces.
      assert Failover.eligible?(
               Error.transport(:openai_codex, Codex, :closed, stage: :mid_stream)
             )

      assert Failover.eligible?(Error.api(:openai_codex, Codex, 503, %{}, stage: :mid_stream))
    end

    test "an image turn on a non-vision route is eligible (fail over to seek a vision route)" do
      assert Failover.eligible?({:image_unsupported, :ollama, "llama3.3:70b"})
    end
  end

  describe "eligible?/1 — not eligible" do
    test "api-key auth failure stops immediately" do
      refute Failover.eligible?(Error.api(:openai, OpenAI, 401, %{}))

      {:provider_error, error} = Error.api(:xai, Responses, 401, %{})
      refute Failover.eligible?({:provider_error, Map.put(error, :auth_mode, :api_key)})
    end

    test "an oauth 403 (entitlement denial, not a stale token) stops immediately" do
      {:provider_error, error} = Error.api(:xai, Responses, 403, %{})

      refute Failover.eligible?({:provider_error, Map.put(error, :auth_mode, :oauth)})
    end

    test "context length, plain strings, and unknown shapes are not eligible" do
      refute Failover.eligible?(:context_length_exceeded)
      refute Failover.eligible?("some provider error string")
      refute Failover.eligible?({:error, :anything})
      refute Failover.eligible?(Error.api(:openai, OpenAI, 400, %{}))
    end

    test "a connection-unavailable transport error is terminal for failover" do
      # Pool-checkout exhaustion means the host could not get *any* connection,
      # which on a wake-from-sleep race is true for every provider at once.
      # Sweeping the chain would burn ~20s of doomed attempts; failover stays
      # out of it and the runner's transient backoff owns recovery instead.
      refute Failover.eligible?(Error.transport(:openai_codex, :codex, :connection_unavailable))
    end
  end

  describe "run_chain/3" do
    defp route(provider, model) do
      {%{provider: provider, model: model, auth_mode: :api_key, base_url: "https://x/v1"},
       [model: model]}
    end

    defp attach_failover_handler do
      handler_id = "failover-test-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:fermix, :provider, :failover],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
    end

    test "returns the first success without trying fallbacks" do
      test_pid = self()

      attempt = fn {key, _opts} ->
        send(test_pid, {:attempt, key.provider})
        {:ok, :result}
      end

      assert {:ok, :result} =
               Failover.run_chain([route(:openai, "m1"), route(:xai, "m2")], attempt)

      assert_received {:attempt, :openai}
      refute_received {:attempt, :xai}
    end

    test "fails over past an eligible error and emits one failover event" do
      attach_failover_handler()

      attempt = fn {key, _opts} ->
        case key.provider do
          :anthropic -> {:error, Error.transport(:anthropic, Messages, :timeout)}
          :openai -> {:ok, :recovered}
        end
      end

      assert {:ok, :recovered} =
               Failover.run_chain(
                 [route(:anthropic, "claude-x"), route(:openai, "gpt-x")],
                 attempt,
                 telemetry: %{agent: "main"}
               )

      assert_received {:telemetry, [:fermix, :provider, :failover], %{count: 1}, metadata}
      assert metadata.from_provider == :anthropic
      assert metadata.from_model == "claude-x"
      assert metadata.to_provider == :openai
      assert metadata.to_model == "gpt-x"
      assert metadata.reason_kind == :timeout
      assert metadata.agent == "main"
    end

    test "an ineligible error stops immediately without attempting fallbacks" do
      test_pid = self()

      attempt = fn {key, _opts} ->
        send(test_pid, {:attempt, key.provider})
        {:error, Error.api(:openai, OpenAI, 401, %{})}
      end

      assert {:error, {:provider_error, %{kind: :auth}}} =
               Failover.run_chain([route(:openai, "m1"), route(:xai, "m2")], attempt)

      assert_received {:attempt, :openai}
      refute_received {:attempt, :xai}
    end

    test "all routes failing returns attempted providers and reasons" do
      attempt = fn {key, _opts} ->
        {:error, Error.transport(key.provider, Adapter, :timeout)}
      end

      assert {:error, {:all_routes_failed, attempted}} =
               Failover.run_chain([route(:anthropic, "m1"), route(:openai, "m2")], attempt)

      assert [{:anthropic, _}, {:openai, _}] = attempted
    end

    test "a single-route chain returns the bare reason" do
      reason = Error.transport(:openai, OpenAI, :timeout)
      attempt = fn _route -> {:error, reason} end

      assert {:error, ^reason} = Failover.run_chain([route(:openai, "m1")], attempt)
    end

    test "an empty chain returns no_routes" do
      assert {:error, :no_routes} = Failover.run_chain([], fn _route -> {:ok, :never} end)
    end

    test "a custom eligible? predicate can veto failover" do
      test_pid = self()

      attempt = fn {key, _opts} ->
        send(test_pid, {:attempt, key.provider})
        {:error, Error.transport(:openai, OpenAI, :timeout)}
      end

      assert {:error, {:provider_transport_error, _}} =
               Failover.run_chain(
                 [route(:openai, "m1"), route(:xai, "m2")],
                 attempt,
                 eligible?: fn _reason -> false end
               )

      refute_received {:attempt, :xai}
    end
  end

  describe "run_chain/3 — same-provider retry" do
    test "retries a transient connection_unavailable on a single route, then succeeds" do
      conn = Error.transport(:openai_codex, Codex, :connection_unavailable)

      {attempt, calls} =
        stub_attempt(%{openai_codex: [{:error, conn}, {:error, conn}, {:ok, :done}]})

      assert {:ok, :done} =
               Failover.run_chain([route(:openai_codex, "m")], attempt,
                 retry_delay_fn: fn _ms -> :ok end
               )

      assert calls.() == %{openai_codex: 3}
    end

    test "bounds retries by max_retries then surfaces the error" do
      conn = Error.transport(:openai_codex, Codex, :connection_unavailable)
      {attempt, calls} = stub_attempt(%{openai_codex: [{:error, conn}]})

      assert {:error, ^conn} =
               Failover.run_chain([route(:openai_codex, "m")], attempt,
                 max_retries: 2,
                 retry_delay_fn: fn _ms -> :ok end
               )

      # 1 initial attempt + 2 retries
      assert calls.() == %{openai_codex: 3}
    end

    test "connection_unavailable retries the same route and never fails over (network-wide)" do
      conn = Error.transport(:openai_codex, Codex, :connection_unavailable)

      {attempt, calls} =
        stub_attempt(%{openai_codex: [{:error, conn}, {:ok, :done}], openai: [{:ok, :never}]})

      assert {:ok, :done} =
               Failover.run_chain([route(:openai_codex, "m1"), route(:openai, "m2")], attempt,
                 retry_delay_fn: fn _ms -> :ok end
               )

      # route 2 is never attempted
      assert calls.() == %{openai_codex: 2}
    end

    test "a retryable+eligible kind with more routes fails over instead of same-retry" do
      timeout = Error.transport(:openai_codex, Codex, :timeout)

      {attempt, calls} =
        stub_attempt(%{openai_codex: [{:error, timeout}], openai: [{:ok, :done}]})

      assert {:ok, :done} =
               Failover.run_chain([route(:openai_codex, "m1"), route(:openai, "m2")], attempt,
                 retry_delay_fn: fn _ms -> :ok end
               )

      # no same-retry on route 1: one attempt each
      assert calls.() == %{openai_codex: 1, openai: 1}
    end

    test "a vetoing retryable? predicate (e.g. content already streamed) blocks retry" do
      conn = Error.transport(:openai_codex, Codex, :connection_unavailable)
      {attempt, calls} = stub_attempt(%{openai_codex: [{:error, conn}]})

      assert {:error, ^conn} =
               Failover.run_chain([route(:openai_codex, "m")], attempt,
                 retryable?: fn _reason -> false end,
                 retry_delay_fn: fn _ms -> :ok end
               )

      assert calls.() == %{openai_codex: 1}
    end
  end

  # Stub attempt_fn backed by an Agent: pops the next response per provider,
  # repeats the last response once exhausted, and records call counts.
  defp stub_attempt(responses) do
    {:ok, agent} = start_supervised({Agent, fn -> %{remaining: responses, calls: %{}} end})

    attempt = fn {route_key, _opts} ->
      Agent.get_and_update(agent, &pop_response(&1, route_key.provider))
    end

    {attempt, fn -> Agent.get(agent, & &1.calls) end}
  end

  defp pop_response(st, provider) do
    {result, rest} = next_response(Map.fetch!(st.remaining, provider))

    st = %{
      st
      | remaining: Map.put(st.remaining, provider, rest),
        calls: Map.update(st.calls, provider, 1, &(&1 + 1))
    }

    {result, st}
  end

  defp next_response([only]), do: {only, [only]}
  defp next_response([head | tail]), do: {head, tail}
end
