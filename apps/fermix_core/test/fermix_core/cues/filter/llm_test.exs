defmodule FermixCore.Cues.Filter.LlmTest do
  # async: false — the default-route tests write the shared `[fermix_core.routing]`
  # and `[fermix_core.providers]` app env (established here, restored on exit).
  use ExUnit.Case, async: false

  alias FermixCore.Cues.Filter.Llm
  alias FermixCore.Providers.Error, as: ProviderError
  alias FermixTestSupport.TelemetryCapture

  # Stand-in for the adapter of whatever route resolved: forwards each call to
  # the test and answers with the reply the test put in `adapter_opts`.
  defmodule StubAdapter do
    @moduledoc false

    def chat(messages, capabilities, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:chat, messages, capabilities, opts})
      Keyword.fetch!(opts, :reply)
    end
  end

  # The first route's model times out at the transport; any other passes.
  defmodule FailoverAdapter do
    @moduledoc false
    alias FermixCore.Providers.Error, as: ProviderError

    def chat(_messages, [], opts) do
      case Keyword.fetch!(opts, :model) do
        "gpt-5.4-mini" ->
          {:error, ProviderError.transport(:openai, :responses, :timeout)}

        _next ->
          {:ok,
           %{
             content: ~s({"decision":"pass","reason":"x"}),
             tool_calls: [],
             provider_state: nil,
             usage: %{prompt_tokens: 1, completion_tokens: 1, total_tokens: 2},
             model: "stub-model"
           }}
      end
    end
  end

  setup do
    routing = Application.get_env(:fermix_core, :routing, [])
    providers = Application.get_env(:fermix_core, :providers, [])
    agent = Application.get_env(:fermix_core, :agent, [])

    on_exit(fn ->
      Application.put_env(:fermix_core, :routing, routing)
      Application.put_env(:fermix_core, :providers, providers)
      Application.put_env(:fermix_core, :agent, agent)
    end)

    # A primary that resolves, so a test that sees no adapter call proves the
    # filter never fell back to it.
    Application.put_env(:fermix_core, :routing, [])
    Application.put_env(:fermix_core, :providers, openai: [api_key: "sk-test", primary: true])
    :ok
  end

  defp turn(content, provider_state \\ nil) do
    {:ok,
     %{
       content: content,
       tool_calls: [],
       provider_state: provider_state,
       usage: %{prompt_tokens: 1, completion_tokens: 1, total_tokens: 2},
       model: "stub-model"
     }}
  end

  defp claim(watcher_overrides \\ %{}) do
    %{
      call_id: "cfc_llmtest",
      session_id: "cue_filter_cwt_llm_20261010_120000_a1b2c3",
      delivery: %{id: 11, cue_id: 5, source_ref: "eng", subject: nil, filter_attempts: 0},
      cue: %{
        id: 5,
        source_ref: "eng",
        item_id: "i-1",
        revision: "1",
        type: "feed.item",
        subject: nil,
        occurred_at: nil,
        received_at: ~U[2026-10-10 12:00:00.000000Z],
        payload: Jason.encode!("A new release"),
        snapshot: nil
      },
      watcher:
        Map.merge(
          %{
            id: "cwt_llm",
            name: "eng-news",
            purpose: "Releases.",
            filter_provider: "openai",
            filter_model: "gpt-5.4-mini",
            task_job_id: "job_llm"
          },
          watcher_overrides
        ),
      instructions: [],
      examples: []
    }
  end

  defp decide(claim, reply) do
    Llm.decide(claim,
      session_id: claim.session_id,
      adapter: StubAdapter,
      adapter_opts: [test_pid: self(), reply: reply],
      retry_delay_fn: fn _ms -> :ok end
    )
  end

  describe "the route (C54: never the primary)" do
    test "no watcher model and no default filter model: no_filter_model and no call" do
      watcher = %{filter_provider: nil, filter_model: nil}

      assert Llm.route(claim(watcher).watcher) == {:error, :no_filter_model}

      assert {:provider_failure, %{kind: :no_filter_model, message: message}} =
               decide(claim(watcher), turn(~s({"decision":"pass","reason":"x"})))

      assert message == Llm.no_filter_model_sentence()
      refute_received {:chat, _messages, _capabilities, _opts}
    end

    test "a provider default with no model is not a filter model" do
      Application.put_env(:fermix_core, :routing, filter_provider: "openai")

      assert Llm.route(claim(%{filter_provider: nil, filter_model: nil}).watcher) ==
               {:error, :no_filter_model}
    end

    test "the watcher's own model wins over the default" do
      Application.put_env(:fermix_core, :routing,
        filter_provider: "anthropic",
        filter_model: "claude-haiku-4-5"
      )

      assert {:pass, "Release.", nil} =
               decide(claim(), turn(~s({"decision":"pass","reason":"Release."})))

      assert_received {:chat, _messages, [], opts}
      assert Keyword.fetch!(opts, :model) == "gpt-5.4-mini"
    end

    test "with no watcher model the default filter model is used" do
      Application.put_env(:fermix_core, :routing,
        filter_provider: "anthropic",
        filter_model: "claude-haiku-4-5"
      )

      watcher = %{filter_provider: nil, filter_model: nil}
      assert {:drop, "No."} = decide(claim(watcher), turn(~s({"decision":"drop","reason":"No."})))
      assert_received {:chat, _messages, [], opts}
      assert Keyword.fetch!(opts, :model) == "claude-haiku-4-5"
    end

    test "an unknown provider on the watcher is a provider failure, no call" do
      assert {:provider_failure, %{kind: :no_route}} =
               decide(claim(%{filter_provider: "nope"}), turn("{}"))

      refute_received {:chat, _messages, _capabilities, _opts}
    end
  end

  describe "the call" do
    test "the session id and agent ride the call; no tools; output capped at 150" do
      decide(claim(), turn(~s({"decision":"pass","reason":"x"})))
      assert_received {:chat, [%{role: "system"}, %{role: "user"}], [], opts}
      assert Keyword.fetch!(opts, :session_id) == "cue_filter_cwt_llm_20261010_120000_a1b2c3"
      assert Keyword.fetch!(opts, :agent) == "cue_filter"
      assert Keyword.fetch!(opts, :max_tokens) == 150
      assert Keyword.fetch!(opts, :thinking) == :off
    end

    # `:none` omits the field on OpenAI, which leaves the model at its own
    # default effort; a yes-or-no question asks for the low end explicitly.
    test "an OpenAI Responses route asks for a JSON object and low effort" do
      decide(claim(), turn(~s({"decision":"pass","reason":"x"})))
      assert_received {:chat, _messages, [], opts}
      assert Keyword.fetch!(opts, :text_format) == %{type: "json_object"}
      refute Keyword.has_key?(opts, :response_format)
      assert Keyword.fetch!(opts, :reasoning_effort) == :low
    end

    test "an Anthropic route gets no format, low effort and no thinking" do
      watcher = %{filter_provider: "anthropic", filter_model: "claude-haiku-4-5"}
      decide(claim(watcher), turn(~s({"decision":"pass","reason":"x"})))
      assert_received {:chat, _messages, [], opts}
      refute Keyword.has_key?(opts, :text_format)
      refute Keyword.has_key?(opts, :response_format)
      assert Keyword.fetch!(opts, :reasoning_effort) == :low
      assert Keyword.fetch!(opts, :thinking) == :off
    end

    test "a configured filter effort is used instead of the default" do
      Application.put_env(:fermix_core, :routing, filter_reasoning_effort: "medium")
      decide(claim(), turn(~s({"decision":"pass","reason":"x"})))
      assert_received {:chat, _messages, [], opts}
      assert Keyword.fetch!(opts, :reasoning_effort) == :medium
    end

    # A watcher's filter resolves one route today; on a chain of two, the
    # failover event must land in the call's own trace, as its model call does.
    test "a failover event carries the call's session id" do
      TelemetryCapture.attach([[:fermix, :provider, :failover]], :emitter)
      claim = claim()
      {:ok, [first]} = Llm.route(claim.watcher)
      {:ok, [second]} = Llm.route(%{claim.watcher | filter_model: "gpt-5.4"})

      assert {:pass, "x", _hint} =
               Llm.decide(claim,
                 session_id: claim.session_id,
                 routes: [first, second],
                 adapter: FailoverAdapter,
                 retry_delay_fn: fn _ms -> :ok end
               )

      assert_received {:telemetry, [:fermix, :provider, :failover], _m, meta}
      assert meta.session_id == claim.session_id
      assert {meta.agent, meta.surface, meta.to_model} == {"cue_filter", :cue_filter, "gpt-5.4"}
    end
  end

  describe "classifying the outcome (C07)" do
    test "an invalid answer, an empty reply and a refusal are content failures" do
      assert {:content_failure, %{kind: :invalid_answer}} = decide(claim(), turn("I think so."))
      assert {:content_failure, %{kind: :empty_reply}} = decide(claim(), turn("  "))

      assert {:content_failure, %{kind: :refused}} =
               decide(claim(), turn("", %{stop_reason: "refusal", content: []}))
    end

    test "transport errors, rate limits, 5xx, auth and timeouts are provider failures" do
      transport = {:error, ProviderError.transport(:openai, :responses, :econnrefused)}
      rate = {:error, ProviderError.api(:openai, :responses, 429, %{"error" => "slow down"})}
      outage = {:error, ProviderError.api(:openai, :responses, 503, "")}
      auth = {:error, ProviderError.auth(:openai, :responses, "No key.")}
      timeout = {:error, ProviderError.transport(:openai, :responses, :timeout)}

      assert {:provider_failure, %{kind: :network}} = decide(claim(), transport)
      assert {:provider_failure, %{kind: :rate_limit}} = decide(claim(), rate)
      assert {:provider_failure, %{kind: :provider_unavailable}} = decide(claim(), outage)
      assert {:provider_failure, %{kind: :auth, message: "No key."}} = decide(claim(), auth)
      assert {:provider_failure, %{kind: :timeout}} = decide(claim(), timeout)
    end

    test "the provider refusing the input (a 400) and an oversized input are content failures" do
      refused =
        {:error,
         ProviderError.api(:openai, :responses, 400, %{
           "error" => %{"message" => "The input was refused."}
         })}

      assert {:content_failure, %{kind: :input_refused, message: "The input was refused."}} =
               decide(claim(), refused)

      assert {:content_failure, %{kind: :context_length}} =
               decide(claim(), {:error, :context_length_exceeded})
    end

    test "an error of no known shape is a content failure of its own kind" do
      assert {:content_failure, %{kind: :unclassified}} =
               decide(claim(), {:error, "Unexpected response format"})
    end
  end
end
