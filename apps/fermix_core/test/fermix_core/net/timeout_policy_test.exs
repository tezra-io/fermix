defmodule FermixCore.Net.TimeoutPolicyTest do
  # async: false — the integration tier drives a real backend through the shared
  # provider-call wrapper (telemetry); the pure tier is order-independent but the
  # file's async setting is per-module, so the conservative choice covers both.
  use ExUnit.Case, async: false

  alias FermixCore.Net.TimeoutPolicy
  alias FermixCore.Tools.Media.Backends.OpenAIImage

  # The bug this policy closes: requests that set no `receive_timeout` silently
  # inherit Req's 15s default. Image generation and buffered LLM turns routinely
  # run longer than 15s, so 15s must never be the effective ceiling for them.
  @req_default_ms 15_000

  describe "receive_timeout_for/1" do
    test "image generation gets a generous budget, never Req's 15s default" do
      timeout = TimeoutPolicy.receive_timeout_for(:image_generation)
      assert timeout == 300_000
      assert timeout > @req_default_ms
    end

    test "a buffered LLM turn gets the same ceiling as a streaming one, not 15s" do
      assert TimeoutPolicy.receive_timeout_for(:llm_buffered) == 240_000
      assert TimeoutPolicy.receive_timeout_for(:llm_buffered) > @req_default_ms
    end

    test "a media download gets a 120s idle window, never 15s" do
      timeout = TimeoutPolicy.receive_timeout_for(:media_download)
      assert timeout == 120_000
      assert timeout > @req_default_ms
    end

    test "audio transcription gets a buffered budget, never 15s for a long voice note" do
      timeout = TimeoutPolicy.receive_timeout_for(:transcription)
      assert timeout == 120_000
      assert timeout > @req_default_ms
    end

    test "an unknown request kind fails loud — no silent default (Rule #12)" do
      # apply/3 keeps the kind opaque to the typechecker; a bare literal call here
      # is a provable type violation (zero overlap with the 3 known kinds) and
      # would fail the warnings-as-errors gate. The runtime behavior is the point.
      assert_raise FunctionClauseError, fn ->
        apply(TimeoutPolicy, :receive_timeout_for, [:not_a_real_kind])
      end
    end
  end

  describe "image generation wiring" do
    test "the OpenAI image backend carries the policy timeout into the request" do
      test_pid = self()

      adapter = fn req ->
        send(test_pid, {:image_receive_timeout, req.options[:receive_timeout]})
        {req, %Req.TransportError{reason: :timeout}}
      end

      {:error, _message, _trace} =
        OpenAIImage.run(:generate, %{prompt: "a watercolor fox"},
          api_key: "sk-test",
          context: %{req_options: [adapter: adapter]}
        )

      assert_received {:image_receive_timeout, 300_000}
    end

    test "an explicit req_options receive_timeout still overrides the policy" do
      test_pid = self()

      adapter = fn req ->
        send(test_pid, {:image_receive_timeout, req.options[:receive_timeout]})
        {req, %Req.TransportError{reason: :timeout}}
      end

      {:error, _message, _trace} =
        OpenAIImage.run(:generate, %{prompt: "x"},
          api_key: "sk-test",
          context: %{req_options: [adapter: adapter, receive_timeout: 5_000]}
        )

      assert_received {:image_receive_timeout, 5_000}
    end
  end
end
