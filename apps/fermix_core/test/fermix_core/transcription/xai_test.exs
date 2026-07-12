defmodule FermixCore.Transcription.XAITest do
  # async: false — credential tests mutate global `:providers`/`:transcription`.
  use ExUnit.Case, async: false

  alias FermixCore.Transcription.XAI

  setup do
    providers = Application.get_env(:fermix_core, :providers)
    transcription = Application.get_env(:fermix_core, :transcription)

    # Force an empty providers baseline so the "no key resolves" assertions can't
    # be flipped by a leaked/test-env xAI provider key — xai reuses the `:xai`
    # chat-provider key, so it must start absent for those cases.
    Application.put_env(:fermix_core, :providers, [])
    Application.put_env(:fermix_core, :transcription, [])

    on_exit(fn ->
      restore(:providers, providers)
      restore(:transcription, transcription)
    end)

    :ok
  end

  describe "backend metadata" do
    test "declares its name and batch-only capability gate (streaming lands later)" do
      assert XAI.name() == :xai
      assert XAI.capabilities() == %{streaming?: false, local?: false}
    end
  end

  describe "configured?/1 credential resolution" do
    test "the transcription xai_api_key overrides the chat-provider key" do
      # SpaceXAI STT needs an API key even when the chat provider is on OAuth; the
      # transcription-specific key wins over the reused chat key when both are set.
      Application.put_env(:fermix_core, :providers, xai: [api_key: "xai-chat"])
      Application.put_env(:fermix_core, :transcription, xai_api_key: "xai-transcription")
      assert :ok = XAI.configured?([])
    end

    test "falls through to the reused SpaceXAI (xai) chat-provider key when no override is set" do
      Application.put_env(:fermix_core, :providers, xai: [api_key: "xai-provider"])
      assert :ok = XAI.configured?([])
    end

    test "honors the opts api_key seam first" do
      assert :ok = XAI.configured?(api_key: "xai-opts")
    end

    test "the legacy shared api_key block key does NOT configure it" do
      # The removed single `api_key` key is dead; only the dedicated `xai_api_key`
      # slot (or the reused chat key) counts.
      Application.put_env(:fermix_core, :transcription, api_key: "block-key")
      assert {:error, :not_configured} = XAI.configured?([])
    end

    test "rejects blank/@keyring sentinels and fails loud when nothing is set" do
      Application.put_env(:fermix_core, :providers, xai: [api_key: "@keyring"])
      Application.put_env(:fermix_core, :transcription, xai_api_key: "@keyring")
      assert {:error, :not_configured} = XAI.configured?(api_key: "")
    end
  end

  describe "transcribe/2" do
    test "posts modelless multipart to /v1/stt with format=true, file last, and bearer" do
      tmp_dir = FermixTestSupport.SafeRm.make_tmp_dir!("transcription-xai-ok")

      try do
        path = Path.join(tmp_dir, "clip.ogg")
        File.write!(path, "OGGDATA")
        test_pid = self()
        test_id = :"transcription_xai_#{System.unique_integer([:positive])}"

        Req.Test.stub(test_id, fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn, length: 10_000_000)

          send(
            test_pid,
            {:request, %{path: conn.request_path, body: body, headers: conn.req_headers}}
          )

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(
            200,
            # `language`, `duration`, `words` are present but ignored — only the
            # top-level `text` is read.
            Jason.encode!(%{
              "text" => "xai transcript",
              "language" => "en",
              "duration" => 1.2,
              "words" => []
            })
          )
        end)

        assert {:ok, "xai transcript"} =
                 XAI.transcribe(path,
                   api_key: "xai-opts",
                   req_options: [plug: {Req.Test, test_id}]
                 )

        assert_receive {:request, %{path: path_seen, body: body, headers: headers}}
        assert path_seen == "/v1/stt"
        assert {"authorization", "Bearer xai-opts"} in headers
        # The `format` form field is present; NO model string is ever sent
        # (xai is modelless — no `grok-stt`, no OpenAI-shaped model id).
        assert body =~ "format"
        refute body =~ "grok-stt"
        assert body =~ "OGGDATA"
        # The audio `file` part comes last — its content-disposition appears after
        # the `format` field's in the body byte stream.
        {format_pos, _len} = :binary.match(body, "name=\"format\"")
        {file_pos, _len} = :binary.match(body, "name=\"file\"")
        assert format_pos < file_pos
      after
        FermixTestSupport.SafeRm.rm_rf!(tmp_dir)
      end
    end

    test "sends an optional language field before the file when one is supplied" do
      tmp_dir = FermixTestSupport.SafeRm.make_tmp_dir!("transcription-xai-lang")

      try do
        path = Path.join(tmp_dir, "clip.ogg")
        File.write!(path, "OGGDATA")
        test_pid = self()
        test_id = :"transcription_xai_lang_#{System.unique_integer([:positive])}"

        Req.Test.stub(test_id, fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn, length: 10_000_000)
          send(test_pid, {:request, %{body: body}})

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, Jason.encode!(%{"text" => "hola"}))
        end)

        assert {:ok, "hola"} =
                 XAI.transcribe(path,
                   api_key: "xai-opts",
                   language: "es",
                   req_options: [plug: {Req.Test, test_id}]
                 )

        assert_receive {:request, %{body: body}}
        assert body =~ "name=\"language\""
        assert body =~ "es"
        # Still file-last: the language field precedes the file part.
        {language_pos, _len} = :binary.match(body, "name=\"language\"")
        {file_pos, _len} = :binary.match(body, "name=\"file\"")
        assert language_pos < file_pos
      after
        FermixTestSupport.SafeRm.rm_rf!(tmp_dir)
      end
    end

    test "a missing key fails loud without making an HTTP call" do
      tmp_dir = FermixTestSupport.SafeRm.make_tmp_dir!("transcription-xai-nokey")

      try do
        path = Path.join(tmp_dir, "clip.ogg")
        File.write!(path, "OGGDATA")
        test_pid = self()
        test_id = :"transcription_xai_nokey_#{System.unique_integer([:positive])}"

        Req.Test.stub(test_id, fn conn ->
          send(test_pid, :unexpected_request)
          Plug.Conn.resp(conn, 200, "{}")
        end)

        assert {:error, :not_configured} =
                 XAI.transcribe(path, req_options: [plug: {Req.Test, test_id}])

        refute_received :unexpected_request
      after
        FermixTestSupport.SafeRm.rm_rf!(tmp_dir)
      end
    end

    test "maps a non-2xx to the shared tagged error vocabulary" do
      tmp_dir = FermixTestSupport.SafeRm.make_tmp_dir!("transcription-xai-err")

      try do
        path = Path.join(tmp_dir, "clip.ogg")
        File.write!(path, "OGGDATA")
        test_id = :"transcription_xai_err_#{System.unique_integer([:positive])}"

        Req.Test.stub(test_id, fn conn -> Plug.Conn.resp(conn, 429, "slow down") end)

        assert {:error, message} =
                 XAI.transcribe(path,
                   api_key: "xai-opts",
                   req_options: [plug: {Req.Test, test_id}]
                 )

        assert message =~ "rate_limited"
      after
        FermixTestSupport.SafeRm.rm_rf!(tmp_dir)
      end
    end
  end

  defp restore(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore(key, value), do: Application.put_env(:fermix_core, key, value)
end
