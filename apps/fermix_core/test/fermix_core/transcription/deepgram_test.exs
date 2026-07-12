defmodule FermixCore.Transcription.DeepgramTest do
  # async: false — credential tests mutate global `:transcription`.
  use ExUnit.Case, async: false

  alias FermixCore.Transcription.Deepgram

  @ok_body %{
    "results" => %{
      "channels" => [%{"alternatives" => [%{"transcript" => "deepgram transcript"}]}]
    }
  }

  setup do
    transcription = Application.get_env(:fermix_core, :transcription)
    # Baseline so `model()` falls to Deepgram's own default.
    Application.put_env(:fermix_core, :transcription, [])

    on_exit(fn -> restore(:transcription, transcription) end)
    :ok
  end

  describe "backend metadata" do
    test "declares its name and batch-only capability gate (streaming lands later)" do
      assert Deepgram.name() == :deepgram
      assert Deepgram.capabilities() == %{streaming?: false, local?: false}
    end
  end

  describe "configured?/1 credential resolution" do
    test "resolves the dedicated deepgram_api_key block key" do
      Application.put_env(:fermix_core, :transcription, deepgram_api_key: "dg-block")
      assert :ok = Deepgram.configured?([])
    end

    test "the legacy shared api_key block key no longer configures it" do
      # Deepgram now reads only its own `deepgram_api_key` slot — the removed
      # single `api_key` key is dead (Rule #12, no leftover dual path).
      Application.put_env(:fermix_core, :transcription, api_key: "dg-block")
      assert {:error, :not_configured} = Deepgram.configured?([])
    end

    test "honors the opts api_key seam first" do
      assert :ok = Deepgram.configured?(api_key: "dg-opts")
    end

    test "rejects blank/@keyring sentinels and fails loud when nothing is set" do
      Application.put_env(:fermix_core, :transcription, deepgram_api_key: "@keyring")
      assert {:error, :not_configured} = Deepgram.configured?(api_key: "")
    end
  end

  describe "transcribe/2" do
    test "posts the raw body to /v1/listen?model=nova-3&smart_format=true with Token auth and parses the transcript" do
      tmp_dir = FermixTestSupport.SafeRm.make_tmp_dir!("transcription-deepgram-ok")

      try do
        path = Path.join(tmp_dir, "clip.ogg")
        File.write!(path, "OGGDATA")
        test_pid = self()
        test_id = :"transcription_deepgram_#{System.unique_integer([:positive])}"

        Req.Test.stub(test_id, fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn, length: 10_000_000)

          send(
            test_pid,
            {:request,
             %{
               path: conn.request_path,
               query: conn.query_string,
               body: body,
               headers: conn.req_headers
             }}
          )

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, Jason.encode!(@ok_body))
        end)

        assert {:ok, "deepgram transcript"} =
                 Deepgram.transcribe(path,
                   api_key: "dg-opts",
                   req_options: [plug: {Req.Test, test_id}]
                 )

        assert_receive {:request, req}
        assert req.path == "/v1/listen"
        assert req.query =~ "model=nova-3"
        # `smart_format=true` is required so the transcript is punctuated like the
        # OpenAI/xAI backends, not Deepgram's default word stream.
        assert req.query =~ "smart_format=true"
        assert {"authorization", "Token dg-opts"} in req.headers
        assert {"content-type", "audio/ogg"} in req.headers
        # Raw audio bytes are the request body (no multipart wrapping).
        assert req.body == "OGGDATA"
      after
        FermixTestSupport.SafeRm.rm_rf!(tmp_dir)
      end
    end

    test "a missing key fails loud without making an HTTP call" do
      tmp_dir = FermixTestSupport.SafeRm.make_tmp_dir!("transcription-deepgram-nokey")

      try do
        path = Path.join(tmp_dir, "clip.ogg")
        File.write!(path, "OGGDATA")
        test_pid = self()
        test_id = :"transcription_deepgram_nokey_#{System.unique_integer([:positive])}"

        Req.Test.stub(test_id, fn conn ->
          send(test_pid, :unexpected_request)
          Plug.Conn.resp(conn, 200, "{}")
        end)

        assert {:error, :not_configured} =
                 Deepgram.transcribe(path, req_options: [plug: {Req.Test, test_id}])

        refute_received :unexpected_request
      after
        FermixTestSupport.SafeRm.rm_rf!(tmp_dir)
      end
    end

    test "maps a non-2xx to the shared tagged error vocabulary" do
      tmp_dir = FermixTestSupport.SafeRm.make_tmp_dir!("transcription-deepgram-err")

      try do
        path = Path.join(tmp_dir, "clip.ogg")
        File.write!(path, "OGGDATA")
        test_id = :"transcription_deepgram_err_#{System.unique_integer([:positive])}"

        Req.Test.stub(test_id, fn conn -> Plug.Conn.resp(conn, 403, "forbidden") end)

        assert {:error, message} =
                 Deepgram.transcribe(path,
                   api_key: "dg-opts",
                   req_options: [plug: {Req.Test, test_id}]
                 )

        assert message =~ "auth_failed"
      after
        FermixTestSupport.SafeRm.rm_rf!(tmp_dir)
      end
    end

    test "an unexpected response shape fails loud as parser drift" do
      tmp_dir = FermixTestSupport.SafeRm.make_tmp_dir!("transcription-deepgram-shape")

      try do
        path = Path.join(tmp_dir, "clip.ogg")
        File.write!(path, "OGGDATA")
        test_id = :"transcription_deepgram_shape_#{System.unique_integer([:positive])}"

        Req.Test.stub(test_id, fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, Jason.encode!(%{"results" => %{}}))
        end)

        assert {:error, message} =
                 Deepgram.transcribe(path,
                   api_key: "dg-opts",
                   req_options: [plug: {Req.Test, test_id}]
                 )

        assert message =~ "parser_changed"
      after
        FermixTestSupport.SafeRm.rm_rf!(tmp_dir)
      end
    end
  end

  defp restore(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore(key, value), do: Application.put_env(:fermix_core, key, value)
end
