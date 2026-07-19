defmodule FermixCore.Transcription.SupportTest do
  # async: false — the credential/telemetry tests mutate global `:providers`,
  # `:transcription`, and `:telemetry` app env.
  use ExUnit.Case, async: false

  alias FermixCore.Transcription.Support

  setup do
    providers = Application.get_env(:fermix_core, :providers)
    transcription = Application.get_env(:fermix_core, :transcription)
    telemetry = Application.get_env(:fermix_core, :telemetry)

    on_exit(fn ->
      restore(:providers, providers)
      restore(:transcription, transcription)
      restore(:telemetry, telemetry)
    end)

    :ok
  end

  describe "opts_key/1" do
    test "honors an explicit opts api_key (test/override seam)" do
      assert {:ok, "sk-explicit"} = Support.opts_key(api_key: "sk-explicit")
    end

    test "treats blank and unresolved-@keyring sentinels as absent" do
      assert :absent = Support.opts_key(api_key: "")
      assert :absent = Support.opts_key(api_key: "@keyring")
      assert :absent = Support.opts_key([])
    end
  end

  describe "provider_key/1" do
    test "resolves a reused chat-provider key" do
      Application.put_env(:fermix_core, :providers, xai: [api_key: "xai-provider"])
      assert {:ok, "xai-provider"} = Support.provider_key(:xai)
    end

    test "is absent when the provider is unconfigured" do
      Application.put_env(:fermix_core, :providers, [])
      assert :absent = Support.provider_key(:xai)
    end
  end

  describe "block_config_key/1" do
    test "resolves the named per-backend transcription block key" do
      Application.put_env(:fermix_core, :transcription, deepgram_api_key: "dg-block")
      assert {:ok, "dg-block"} = Support.block_config_key(:deepgram_api_key)
    end

    test "reads only the requested sub-key (each backend has its own slot)" do
      Application.put_env(:fermix_core, :transcription, openai_api_key: "sk-block")
      assert {:ok, "sk-block"} = Support.block_config_key(:openai_api_key)
      assert :absent = Support.block_config_key(:xai_api_key)
    end

    test "is absent for blank/@keyring/missing block key" do
      Application.put_env(:fermix_core, :transcription, deepgram_api_key: "@keyring")
      assert :absent = Support.block_config_key(:deepgram_api_key)

      Application.put_env(:fermix_core, :transcription, [])
      assert :absent = Support.block_config_key(:deepgram_api_key)
    end
  end

  describe "with_provider_call/4 telemetry" do
    setup do
      handler_id = "transcription-support-provider-call-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:fermix, :provider, :call],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:provider_call, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      :ok
    end

    test "emits a provider call with no token cost and a transcript output preview" do
      Application.put_env(:fermix_core, :telemetry, capture_content: true)

      opts = [session_id: "sess-1", parent_session: "parent-1"]
      result = {:ok, "the transcript"}

      assert ^result =
               Support.with_provider_call(:xai, "grok-stt", opts, fn -> result end)

      assert_receive {:provider_call, %{duration_ms: duration_ms}, metadata}
      assert is_integer(duration_ms) and duration_ms >= 0
      assert metadata.provider == :xai
      assert metadata.model == "grok-stt"
      assert metadata.status == :ok
      assert metadata.tokens == %{}
      assert metadata.reasoning_effort == nil
      # Distinguishes transcription provider calls from chat/media ones downstream.
      assert metadata.purpose == :transcription
      # Adapter-qualified span name: llm:xai:grok-stt.
      assert metadata.adapter == :xai
      # A successful call carries no error fields (so Opik renders it green).
      refute Map.has_key?(metadata, :error_code)
      refute Map.has_key?(metadata, :error_summary)
      # Correlation nests the span under a run when present.
      assert metadata.session_id == "sess-1"
      assert metadata.parent_session == "parent-1"
      assert metadata.output == "the transcript"
    end

    test "marks a tagged-string failure :error and previews the reason" do
      Application.put_env(:fermix_core, :telemetry, capture_content: true)

      result = {:error, "rate_limited: HTTP 429"}

      assert ^result =
               Support.with_provider_call(:deepgram, "nova-3", [], fn -> result end)

      assert_receive {:provider_call, _measurements, metadata}
      assert metadata.status == :error
      assert metadata.adapter == :deepgram
      assert metadata.error_code == "rate_limited"
      assert metadata.error_summary == "rate_limited: HTTP 429"
      assert metadata.output == "rate_limited: HTTP 429"
    end

    test "a missing-key preflight emits a symmetric auth_failed error span" do
      Application.put_env(:fermix_core, :telemetry, capture_content: true)

      result =
        Support.provider_call_error(:deepgram, "nova-3", [session_id: "s"], :not_configured)

      assert result == {:error, :not_configured}

      assert_receive {:provider_call, _measurements, metadata}
      assert metadata.status == :error
      assert metadata.adapter == :deepgram
      # The not-configured atom maps to the shared auth_failed class.
      assert metadata.error_code == "auth_failed"
      assert metadata.error_summary == "transcription backend is not configured"
      assert metadata.session_id == "s"
    end

    test "omits the transcript preview when content capture is off (production default)" do
      Application.put_env(:fermix_core, :telemetry, capture_content: false)

      Support.with_provider_call(:openai, "gpt-4o-mini-transcribe", [session_id: "s"], fn ->
        {:ok, "a secret transcript"}
      end)

      assert_receive {:provider_call, _measurements, metadata}
      assert metadata.session_id == "s"
      assert metadata.tokens == %{}
      refute Map.has_key?(metadata, :input)
      refute Map.has_key?(metadata, :output)
    end
  end

  describe "with_provider_call/4 failure logging" do
    test "logs a warning naming the provider, model, and reason on failure" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Support.with_provider_call(:xai, "grok-stt", [], fn ->
            {:error, "auth_failed: HTTP 401"}
          end)
        end)

      assert log =~ "transcription provider call failed"
      assert log =~ "auth_failed: HTTP 401"
      assert log =~ "provider=xai"
      assert log =~ "model=grok-stt"
    end

    test "does not log on a successful provider call" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Support.with_provider_call(:openai, "gpt-4o-mini-transcribe", [], fn ->
            {:ok, "ok"}
          end)
        end)

      refute log =~ "transcription provider call failed"
    end
  end

  describe "http_error_message/2 and network_error_message/1" do
    test "tag the shared error vocabulary used by every backend" do
      assert Support.http_error_message(401, %{}) =~ "auth_failed"
      assert Support.http_error_message(403, %{}) =~ "auth_failed"
      assert Support.http_error_message(429, %{}) =~ "rate_limited"

      # Nested (OpenAI/xAI) and flat (Deepgram) vendor message shapes both surface.
      assert Support.http_error_message(400, %{"error" => %{"message" => "nested msg"}}) =~
               "nested msg"

      assert Support.http_error_message(500, %{"err_msg" => "flat msg"}) =~ "flat msg"
      assert Support.network_error_message(:econnrefused) =~ "network"
    end
  end

  describe "infer_mime_type/2" do
    test "prefers the attachment mime, falls back to the extension" do
      assert Support.infer_mime_type("/a/clip.ogg",
               metadata: %{attachment: %{mime_type: "audio/x"}}
             ) ==
               "audio/x"

      assert Support.infer_mime_type("/a/clip.ogg", []) == "audio/ogg"
      assert Support.infer_mime_type("/a/note.mp4", []) == "video/mp4"
      assert Support.infer_mime_type("/a/clip.m4a", []) == "audio/mp4"
      assert Support.infer_mime_type("/a/clip.unknown", []) == "application/octet-stream"
    end
  end

  defp restore(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore(key, value), do: Application.put_env(:fermix_core, key, value)
end
