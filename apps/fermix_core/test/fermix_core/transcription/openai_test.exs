defmodule FermixCore.Transcription.OpenAITest do
  # async: false — exercises the real Whisper Req pipeline through an adapter seam
  # and reads/mutates the global `:providers`/`:transcription` app env.
  use ExUnit.Case, async: false

  alias FermixCore.Transcription.OpenAI

  setup do
    providers = Application.get_env(:fermix_core, :providers)
    transcription = Application.get_env(:fermix_core, :transcription)

    # Establish an empty providers baseline (mirrors the xAI/Deepgram suites) so
    # the "no key resolves" assertions can't be flipped by a leaked/test-env
    # openai provider key — the credential path falls through to `provider_key`.
    Application.put_env(:fermix_core, :providers, [])

    on_exit(fn ->
      restore(:providers, providers)
      restore(:transcription, transcription)
    end)

    :ok
  end

  describe "backend metadata" do
    test "declares its name and capability gate" do
      assert OpenAI.name() == :openai
      assert OpenAI.capabilities() == %{streaming?: false, local?: false}
    end

    test "configured?/1 reflects whether an api_key credential resolves" do
      assert :ok = OpenAI.configured?(auth_mode: :api_key, api_key: "sk-test")
      assert {:error, :not_configured} = OpenAI.configured?(auth_mode: :api_key, api_key: "")
    end

    test "rejects the unresolved @keyring sentinel as not_configured (§5.1)" do
      # A failed keychain read leaves the literal "@keyring" in the provider
      # config; it must be treated as absent, never sent as a bearer token.
      assert {:error, :not_configured} =
               OpenAI.configured?(auth_mode: :api_key, api_key: "@keyring")

      Application.put_env(:fermix_core, :providers, openai: [api_key: "@keyring"])
      assert {:error, :not_configured} = OpenAI.configured?(auth_mode: :api_key)
    end

    test "configured?/1 refuses a non-api_key auth mode loudly" do
      assert {:error, {:unsupported_auth_mode, :oauth}} = OpenAI.configured?(auth_mode: :oauth)
    end
  end

  describe "credential resolution order (transcription override → chat key)" do
    test "the transcription openai_api_key overrides the chat-provider key" do
      # A transcription-specific key wins even when the reused chat key is present.
      Application.put_env(:fermix_core, :providers, openai: [api_key: "sk-chat"])
      Application.put_env(:fermix_core, :transcription, openai_api_key: "sk-transcription")

      assert :ok = OpenAI.configured?(auth_mode: :api_key)
    end

    test "falls through to the reused openai chat-provider key when no override is set" do
      Application.put_env(:fermix_core, :providers, openai: [api_key: "sk-chat"])

      assert :ok = OpenAI.configured?(auth_mode: :api_key)
    end

    test "fails loud with :not_configured when neither the override nor the chat key resolves" do
      assert {:error, :not_configured} = OpenAI.configured?(auth_mode: :api_key)
    end

    test "rejects a blank/@keyring override sentinel (never sent as a bearer token)" do
      Application.put_env(:fermix_core, :transcription, openai_api_key: "@keyring")
      assert {:error, :not_configured} = OpenAI.configured?(auth_mode: :api_key)
    end
  end

  describe "transcribe/2 auth" do
    test "refuses a non-api_key auth mode instead of degrading" do
      assert {:error, {:unsupported_auth_mode, :oauth}} =
               OpenAI.transcribe("/tmp/clip.ogg", auth_mode: :oauth)
    end

    test "fails loud with :not_configured when no key resolves" do
      Application.put_env(:fermix_core, :providers, [])

      assert {:error, :not_configured} =
               OpenAI.transcribe("/tmp/clip.ogg", auth_mode: :api_key)
    end
  end

  describe "transcribe/2 HTTP round-trip" do
    test "posts multipart with the configured model + bearer and decodes text" do
      Application.put_env(:fermix_core, :transcription, model: "gpt-4o-mini-transcribe")
      tmp_dir = FermixTestSupport.SafeRm.make_tmp_dir!("transcription-openai-ok")

      try do
        path = Path.join(tmp_dir, "clip.ogg")
        File.write!(path, "OGGDATA")
        test_pid = self()
        test_id = :"transcription_openai_#{System.unique_integer([:positive])}"

        Req.Test.stub(test_id, fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn, length: 10_000_000)
          send(test_pid, {:request, %{body: body, headers: conn.req_headers}})

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, Jason.encode!(%{"text" => "hello world"}))
        end)

        assert {:ok, "hello world"} =
                 OpenAI.transcribe(path,
                   auth_mode: :api_key,
                   api_key: "sk-test",
                   req_options: [plug: {Req.Test, test_id}]
                 )

        assert_receive {:request, %{body: body, headers: headers}}
        assert {"authorization", "Bearer sk-test"} in headers
        # The multipart body carries the model and the streamed file part.
        assert body =~ "gpt-4o-mini-transcribe"
        assert body =~ "OGGDATA"
      after
        FermixTestSupport.SafeRm.rm_rf!(tmp_dir)
      end
    end

    test "maps a non-2xx to the shared tagged error vocabulary" do
      tmp_dir = FermixTestSupport.SafeRm.make_tmp_dir!("transcription-openai-err")

      try do
        path = Path.join(tmp_dir, "clip.ogg")
        File.write!(path, "OGGDATA")
        test_id = :"transcription_openai_err_#{System.unique_integer([:positive])}"

        Req.Test.stub(test_id, fn conn -> Plug.Conn.resp(conn, 401, "nope") end)

        assert {:error, message} =
                 OpenAI.transcribe(path,
                   auth_mode: :api_key,
                   api_key: "sk-test",
                   req_options: [plug: {Req.Test, test_id}]
                 )

        assert message =~ "auth_failed"
      after
        FermixTestSupport.SafeRm.rm_rf!(tmp_dir)
      end
    end
  end

  describe "transcribe/2 timeout wiring" do
    test "carries the transcription policy timeout into the Whisper request" do
      tmp_dir = FermixTestSupport.SafeRm.make_tmp_dir!("transcription-timeout")

      try do
        path = Path.join(tmp_dir, "clip.ogg")
        File.write!(path, "OGGDATA")
        test_pid = self()

        adapter = fn req ->
          send(test_pid, {:transcribe_receive_timeout, req.options[:receive_timeout]})
          {req, %Req.TransportError{reason: :timeout}}
        end

        {:error, _reason} =
          OpenAI.transcribe(path,
            auth_mode: :api_key,
            api_key: "sk-test",
            req_options: [adapter: adapter]
          )

        # A multi-minute voice note must not be capped at Req's silent 15s default.
        assert_received {:transcribe_receive_timeout, 120_000}
      after
        FermixTestSupport.SafeRm.rm_rf!(tmp_dir)
      end
    end

    test "an explicit req_options receive_timeout still overrides the policy" do
      tmp_dir = FermixTestSupport.SafeRm.make_tmp_dir!("transcription-timeout-override")

      try do
        path = Path.join(tmp_dir, "clip.ogg")
        File.write!(path, "OGGDATA")
        test_pid = self()

        adapter = fn req ->
          send(test_pid, {:transcribe_receive_timeout, req.options[:receive_timeout]})
          {req, %Req.TransportError{reason: :timeout}}
        end

        {:error, _reason} =
          OpenAI.transcribe(path,
            auth_mode: :api_key,
            api_key: "sk-test",
            req_options: [adapter: adapter, receive_timeout: 5_000]
          )

        assert_received {:transcribe_receive_timeout, 5_000}
      after
        FermixTestSupport.SafeRm.rm_rf!(tmp_dir)
      end
    end
  end

  defp restore(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore(key, value), do: Application.put_env(:fermix_core, key, value)
end
