defmodule FermixCore.Tools.Media.SupportTest do
  # async: false — the credential/telemetry tests mutate global `:providers`
  # and `:telemetry` app env.
  use ExUnit.Case, async: false

  alias FermixCore.Tools.Media.Support

  setup do
    providers = Application.get_env(:fermix_core, :providers)
    telemetry = Application.get_env(:fermix_core, :telemetry)

    on_exit(fn ->
      restore(:providers, providers)
      restore(:telemetry, telemetry)
    end)

    :ok
  end

  describe "provider_credential/3" do
    test "honors an explicit opts api_key (test/override seam)" do
      assert {:ok, "sk-explicit"} =
               Support.provider_credential([api_key: "sk-explicit"], :openai, "OPENAI_API_KEY")
    end

    test "falls through to the configured provider key when no opts key is given" do
      Application.put_env(:fermix_core, :providers, openai: [api_key: "sk-configured"])

      assert {:ok, "sk-configured"} =
               Support.provider_credential([], :openai, "OPENAI_API_KEY")
    end

    test "treats empty and unresolved-@keyring opts keys as absent" do
      Application.put_env(:fermix_core, :providers, openai: [api_key: "sk-configured"])

      assert {:ok, "sk-configured"} =
               Support.provider_credential([api_key: ""], :openai, "OPENAI_API_KEY")

      assert {:ok, "sk-configured"} =
               Support.provider_credential([api_key: "@keyring"], :openai, "OPENAI_API_KEY")
    end

    test "fails loud with the labeled key when nothing is configured" do
      Application.put_env(:fermix_core, :providers, [])

      assert {:error, "auth_failed: OPENAI_API_KEY is not set. Run `fermix setup` to add it."} =
               Support.provider_credential([], :openai, "OPENAI_API_KEY")
    end
  end

  describe "config_credential/3" do
    test "resolves a tool-block secret by keyword" do
      assert {:ok, "g-key"} =
               Support.config_credential(
                 [google_api_key: "g-key"],
                 :google_api_key,
                 "GOOGLE_API_KEY"
               )
    end

    test "rejects empty and unresolved-@keyring sentinels loudly" do
      assert {:error, "auth_failed: GOOGLE_API_KEY is not set. Run `fermix setup` to add it."} =
               Support.config_credential([google_api_key: ""], :google_api_key, "GOOGLE_API_KEY")

      assert {:error, "auth_failed: GOOGLE_API_KEY is not set. Run `fermix setup` to add it."} =
               Support.config_credential(
                 [google_api_key: "@keyring"],
                 :google_api_key,
                 "GOOGLE_API_KEY"
               )
    end

    test "fails loud when the key is missing" do
      assert {:error, "auth_failed: GOOGLE_API_KEY is not set. Run `fermix setup` to add it."} =
               Support.config_credential([], :google_api_key, "GOOGLE_API_KEY")
    end
  end

  describe "decode_base64/1" do
    test "decodes a valid base64 payload to raw bytes" do
      assert {:ok, "hello"} = Support.decode_base64(Base.encode64("hello"))
    end

    test "rejects invalid base64 as parser drift" do
      assert {:error, message} = Support.decode_base64("not valid base64 !!!")
      assert message =~ "parser_changed"
    end

    test "rejects an empty or non-string payload as parser drift" do
      assert {:error, message} = Support.decode_base64("")
      assert message =~ "parser_changed"
      assert {:error, _} = Support.decode_base64(nil)
    end
  end

  describe "with_provider_call/5 telemetry" do
    setup do
      handler_id = "media-support-provider-call-#{System.unique_integer([:positive])}"
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

    test "emits a provider call with no token cost and a byte-size output preview" do
      Application.put_env(:fermix_core, :telemetry, capture_content: true)

      request = %{prompt: "a watercolor fox"}
      context = %{session_id: "sess-1", parent_session: "parent-1", agent_name: "main"}
      artifact = {:ok, %{bytes: "PNG", mime: "image/png"}, %{}}

      assert ^artifact =
               Support.with_provider_call(:openai, "gpt-image-2", request, context, fn ->
                 artifact
               end)

      assert_receive {:provider_call, %{duration_ms: duration_ms}, metadata}
      assert is_integer(duration_ms) and duration_ms >= 0
      assert metadata.provider == :openai
      assert metadata.model == "gpt-image-2"
      assert metadata.status == :ok
      assert metadata.tokens == %{}
      assert metadata.reasoning_effort == nil
      # Adapter-qualified span name: llm:openai:gpt-image-2, distinct from chat llm spans.
      assert metadata.adapter == :openai
      # A successful call carries no error fields (so Opik renders it green, not red).
      refute Map.has_key?(metadata, :error_code)
      refute Map.has_key?(metadata, :error_summary)
      # Correlation nests the span under the turn trace.
      assert metadata.session_id == "sess-1"
      assert metadata.parent_session == "parent-1"
      # Agent attribution matches every other provider call (TELEMETRY_CONTRACT).
      assert metadata.agent == "main"
      # Output preview is the byte-size summary string, never raw image bytes.
      assert metadata.output == "image/png 3 bytes"
      assert metadata.input == "a watercolor fox"
    end

    test "marks the call status :error and previews the error reason" do
      Application.put_env(:fermix_core, :telemetry, capture_content: true)

      result = {:error, "rate_limited: HTTP 429", %{}}

      assert ^result =
               Support.with_provider_call(:openai, "gpt-image-2", %{prompt: "x"}, %{}, fn ->
                 result
               end)

      assert_receive {:provider_call, _measurements, metadata}
      assert metadata.status == :error
      assert metadata.output == "rate_limited: HTTP 429"
      # Failure is flagged with the error class + full reason so Opik renders it red,
      # matching how chat-provider errors set :error_code/:error.
      assert metadata.adapter == :openai
      assert metadata.error_code == "rate_limited"
      assert metadata.error_summary == "rate_limited: HTTP 429"
    end

    test "a missing credential emits a symmetric error span (no HTTP made)" do
      Application.put_env(:fermix_core, :telemetry, capture_content: true)

      reason = "auth_failed: OPENAI_API_KEY is not set. Run `fermix setup` to add it."

      result =
        Support.provider_call_error(
          :openai,
          "gpt-image-2",
          %{prompt: "x"},
          %{session_id: "s"},
          reason
        )

      # Returns the same {:error, reason, %{}} shape the backend would have returned.
      assert result == {:error, reason, %{}}

      # The missing-key path produces the SAME span shape as a vendor-rejected key —
      # the two auth-failure modes are no longer asymmetric in the trace.
      assert_receive {:provider_call, _measurements, metadata}
      assert metadata.status == :error
      assert metadata.adapter == :openai
      assert metadata.error_code == "auth_failed"
      assert metadata.error_summary == reason
      assert metadata.output == reason
      assert metadata.session_id == "s"
    end

    test "omits input/output previews when content capture is off (production default)" do
      Application.put_env(:fermix_core, :telemetry, capture_content: false)

      artifact = {:ok, %{bytes: "PNG", mime: "image/png"}, %{}}

      Support.with_provider_call(
        :openai,
        "gpt-image-2",
        %{prompt: "secret"},
        %{session_id: "s"},
        fn ->
          artifact
        end
      )

      assert_receive {:provider_call, _measurements, metadata}
      assert metadata.session_id == "s"
      assert metadata.tokens == %{}
      refute Map.has_key?(metadata, :input)
      refute Map.has_key?(metadata, :output)
      # Nil-safe: a context without :agent_name never emits a nil :agent.
      refute Map.has_key?(metadata, :agent)
    end
  end

  describe "with_provider_call/5 failure logging" do
    test "logs a warning naming the provider, model, and reason when the call fails" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Support.with_provider_call(:openai, "gpt-image-2", %{prompt: "x"}, %{}, fn ->
            {:error, "auth_failed: HTTP 401", %{}}
          end)
        end)

      assert log =~ "media provider call failed"
      assert log =~ "auth_failed: HTTP 401"
      assert log =~ "provider=openai"
      assert log =~ "model=gpt-image-2"
    end

    test "does not log on a successful provider call" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Support.with_provider_call(:openai, "gpt-image-2", %{prompt: "x"}, %{}, fn ->
            {:ok, %{bytes: "PNG", mime: "image/png"}, %{}}
          end)
        end)

      refute log =~ "media provider call failed"
    end
  end

  describe "resolve_edit_image/2 — inbound channel images" do
    test "ingests the last inbound image to the sandbox floor" do
      tmp_dir = FermixTestSupport.SafeRm.make_tmp_dir!("media-resolve-inbound")

      try do
        context =
          sandbox_context(tmp_dir,
            inbound_images: [
              %{type: :image, mime_type: "image/png", data: "FIRST"},
              %{type: :image, mime_type: "image/png", data: "LAST"}
            ]
          )

        assert {:ok, %{bytes: "LAST", mime: "image/png", filename: "inbound.png"}} =
                 Support.resolve_edit_image("inbound:last", context)

        # The ingest wrote a copy under the sandbox media floor.
        assert [_one] = Path.wildcard(Path.join([tmp_dir, "media", "inbound-*.png"]))
      after
        FermixTestSupport.SafeRm.rm_rf!(tmp_dir)
      end
    end

    test "selects an inbound image by 1-based index" do
      tmp_dir = FermixTestSupport.SafeRm.make_tmp_dir!("media-resolve-inbound-idx")

      try do
        context =
          sandbox_context(tmp_dir,
            inbound_images: [
              %{type: :image, mime_type: "image/jpeg", data: "ONE"},
              %{type: :image, mime_type: "image/png", data: "TWO"}
            ]
          )

        assert {:ok, %{bytes: "ONE", mime: "image/jpeg"}} =
                 Support.resolve_edit_image("inbound:1", context)
      after
        FermixTestSupport.SafeRm.rm_rf!(tmp_dir)
      end
    end

    test "fails loud when there is no inbound image to edit" do
      context = sandbox_context(System.tmp_dir!(), inbound_images: [])

      assert {:error, message} = Support.resolve_edit_image("inbound", context)
      assert message =~ "no inbound image is attached"
    end

    test "fails loud when the inbound index is out of range" do
      context =
        sandbox_context(System.tmp_dir!(),
          inbound_images: [%{type: :image, mime_type: "image/png", data: "ONE"}]
        )

      assert {:error, message} = Support.resolve_edit_image("inbound:5", context)
      assert message =~ "out of range"
    end

    test "fails loud when more inbound images than the cap are attached (Rule #2)" do
      images =
        for _ <- 1..11, do: %{type: :image, mime_type: "image/png", data: "X"}

      context = sandbox_context(System.tmp_dir!(), inbound_images: images)

      assert {:error, message} = Support.resolve_edit_image("inbound:last", context)
      assert message =~ "too many inbound images"
      assert message =~ "maximum is 10"
    end
  end

  describe "resolve_edit_image/2 — sandbox paths" do
    test "reads an in-sandbox source image" do
      tmp_dir = FermixTestSupport.SafeRm.make_tmp_dir!("media-resolve-path")

      try do
        File.write!(Path.join(tmp_dir, "src.png"), "PNGDATA")
        context = sandbox_context(tmp_dir)

        assert {:ok, %{bytes: "PNGDATA", mime: "image/png", filename: "src.png"}} =
                 Support.resolve_edit_image("src.png", context)
      after
        FermixTestSupport.SafeRm.rm_rf!(tmp_dir)
      end
    end

    test "normalizes a sandbox denial into a one-line error" do
      tmp_dir = FermixTestSupport.SafeRm.make_tmp_dir!("media-resolve-denied")

      try do
        root = Path.join(tmp_dir, "root")
        File.mkdir_p!(root)
        outside = Path.join(tmp_dir, "outside.png")
        File.write!(outside, "NOPE")

        context = sandbox_context(root)

        assert {:error, message} = Support.resolve_edit_image(outside, context)
        assert message =~ "outside the sandbox roots"
      after
        FermixTestSupport.SafeRm.rm_rf!(tmp_dir)
      end
    end
  end

  describe "write_bytes/3" do
    test "writes media bytes under the sandbox floor and returns the absolute path" do
      tmp_dir = FermixTestSupport.SafeRm.make_tmp_dir!("media-write-bytes")

      try do
        context = sandbox_context(tmp_dir)

        assert {:ok, abs} = Support.write_bytes(Path.join("media", "x.png"), "BYTES", context)
        assert File.read!(abs) == "BYTES"
        # Resolved under the workspace `media/` floor (basename compare — macOS
        # resolves /var/folders to /private/var through the sandbox canonicalize).
        assert Path.basename(abs) == "x.png"
        assert Path.basename(Path.dirname(abs)) == "media"
      after
        FermixTestSupport.SafeRm.rm_rf!(tmp_dir)
      end
    end
  end

  describe "materialize_url/2" do
    # A minimal valid-magic PNG so the MIME is sniffed from the bytes.
    @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>> <> "pixels"

    test "downloads the URL and sniffs the image MIME from the bytes" do
      test_id = :"materialize_ok_#{System.unique_integer([:positive])}"

      Req.Test.stub(test_id, fn conn ->
        # The header lies (octet-stream); the sniff must trust the bytes.
        conn
        |> Plug.Conn.put_resp_content_type("application/octet-stream")
        |> Plug.Conn.resp(200, @png)
      end)

      assert {:ok, %{bytes: @png, mime: "image/png"}} =
               Support.materialize_url("https://cdn.example/i.png", plug: {Req.Test, test_id})
    end

    test "refuses a zero-byte body as parser drift" do
      test_id = :"materialize_empty_#{System.unique_integer([:positive])}"
      Req.Test.stub(test_id, fn conn -> Plug.Conn.resp(conn, 200, "") end)

      assert {:error, message} =
               Support.materialize_url("https://cdn.example/empty.png", plug: {Req.Test, test_id})

      assert message =~ "parser_changed"
    end

    test "maps a non-2xx and a transport failure to network errors" do
      not_found = :"materialize_404_#{System.unique_integer([:positive])}"
      Req.Test.stub(not_found, fn conn -> Plug.Conn.resp(conn, 404, "gone") end)

      assert {:error, message} =
               Support.materialize_url("https://cdn.example/gone.png",
                 plug: {Req.Test, not_found}
               )

      assert message =~ "network"
      assert message =~ "404"

      transport = :"materialize_transport_#{System.unique_integer([:positive])}"
      Req.Test.stub(transport, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, message} =
               Support.materialize_url("https://cdn.example/x.png", plug: {Req.Test, transport})

      assert message =~ "network"
    end

    test "halts and refuses a body that exceeds the byte cap before buffering it" do
      test_id = :"materialize_cap_#{System.unique_integer([:positive])}"
      oversized = String.duplicate("x", 25 * 1024 * 1024 + 1)
      Req.Test.stub(test_id, fn conn -> Plug.Conn.resp(conn, 200, oversized) end)

      assert {:error, message} =
               Support.materialize_url("https://cdn.example/huge.png", plug: {Req.Test, test_id})

      assert message =~ "exceeds"
      assert message =~ "cap"
    end
  end

  describe "http_error_message/2 and network_error_message/1" do
    test "tag the shared error vocabulary used by every backend" do
      assert Support.http_error_message(401, %{}) =~ "auth_failed"
      assert Support.http_error_message(403, %{}) =~ "auth_failed"
      assert Support.http_error_message(429, %{}) =~ "rate_limited"

      # Nested (OpenAI/Google) and flat (xAI) vendor message shapes both surface.
      assert Support.http_error_message(400, %{"error" => %{"message" => "nested msg"}}) =~
               "nested msg"

      assert Support.http_error_message(500, %{"error" => "flat msg"}) =~ "flat msg"
      assert Support.network_error_message(:econnrefused) =~ "network"
    end
  end

  describe "pure helpers" do
    test "ext_for_mime/1 maps known image types and defaults to bin" do
      assert Support.ext_for_mime("image/png") == "png"
      assert Support.ext_for_mime("image/jpeg") == "jpg"
      assert Support.ext_for_mime("image/webp") == "webp"
      assert Support.ext_for_mime("image/gif") == "gif"
      assert Support.ext_for_mime("application/pdf") == "bin"
    end

    test "image_mime_for_path/1 maps extensions and defaults to octet-stream" do
      assert Support.image_mime_for_path("/a/b.png") == "image/png"
      assert Support.image_mime_for_path("/a/b.JPG") == "image/jpeg"
      assert Support.image_mime_for_path("/a/b.heic") == "application/octet-stream"
    end

    test "sandbox_error/1 renders each denial reason on one line" do
      assert Support.sandbox_error({:protected_path, "/p"}) =~ "protected"
      assert Support.sandbox_error({:outside_root, "/p"}) =~ "outside the sandbox roots"
      assert Support.sandbox_error({:blocked_root, "/p"}) =~ "blocked root"
      assert Support.sandbox_error({:too_many_symlinks, "/p"}) =~ "symlinks"
      assert Support.sandbox_error("already a string") == "already a string"
    end

    test "token/1 is short and URL-safe" do
      token = Support.token()
      assert is_binary(token)
      refute String.contains?(token, ["+", "/", "="])
    end
  end

  defp sandbox_context(root, extra \\ []) do
    %{
      agent_name: "main",
      conversation_key: :test,
      cwd: root,
      sandbox_config: %{mode: :strict, workspace_root: root, allowed_roots: [root]}
    }
    |> Map.merge(Map.new(extra))
  end

  defp restore(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore(key, value), do: Application.put_env(:fermix_core, key, value)
end
