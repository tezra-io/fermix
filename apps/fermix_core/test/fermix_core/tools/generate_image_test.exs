defmodule FermixCore.Tools.GenerateImageTest do
  # async: false — drives the tool through the global `:fermix_core, :tools`
  # config, which each test sets and `setup` restores.
  use ExUnit.Case, async: false

  alias FermixCore.Tools.GenerateImage

  setup do
    tools = Application.get_env(:fermix_core, :tools)
    on_exit(fn -> restore(:tools, tools) end)
    :ok
  end

  describe "metadata" do
    test "is a media-category builtin that needs no per-tool setup block" do
      assert GenerateImage.name() == "generate_image"
      assert GenerateImage.category() == :media
      assert GenerateImage.requires_setup() == nil
      assert "prompt" in GenerateImage.parameters().required
    end
  end

  describe "execute/2 — not configured" do
    test "fails loud and points at setup when no image backend is configured" do
      Application.put_env(:fermix_core, :tools, [])

      assert {:ok, %{success: false, error: error}} =
               GenerateImage.execute(%{"prompt" => "a fox"}, base_context(System.tmp_dir!()))

      assert error =~ "not configured"
      assert error =~ "fermix setup"
    end
  end

  describe "execute/2 — generate" do
    test "generates an image, writes it under the sandbox and sends it to the channel" do
      tmp_dir = FermixTestSupport.SafeRm.make_tmp_dir!("generate-image-generate")
      test_pid = self()
      handler_id = attach_tool_telemetry()

      try do
        configure_openai(tmp_dir, %{"data" => [%{"b64_json" => Base.encode64("PNGOUT")}]})

        context = channel_context(tmp_dir, test_pid)

        assert {:ok, %{success: true, output: output, error: nil}} =
                 GenerateImage.execute(%{"prompt" => "a watercolor fox"}, context)

        assert output =~ "sent the image"

        assert_receive {:reply, {:media, %{kind: :image, mime_type: "image/png", path: path}}}
        assert File.read!(path) == "PNGOUT"
        # Under the workspace `media/` floor (basename compare — macOS resolves
        # /var/folders to /private/var through the sandbox canonicalize).
        assert Path.basename(Path.dirname(path)) == "media"

        # Tool execution telemetry fires with the right tool name and success.
        assert_receive {:telemetry, %{tool: "generate_image", success: true}}
      after
        :telemetry.detach(handler_id)
        FermixTestSupport.SafeRm.rm_rf!(tmp_dir)
      end
    end

    test "reports a saved file path when no channel is available (subagent/job)" do
      tmp_dir = FermixTestSupport.SafeRm.make_tmp_dir!("generate-image-no-channel")

      try do
        configure_openai(tmp_dir, %{"data" => [%{"b64_json" => Base.encode64("PNGOUT")}]})

        # No reply_fn in the context — file-only delivery.
        context = base_context(tmp_dir)

        assert {:ok, %{success: true, output: output}} =
                 GenerateImage.execute(%{"prompt" => "a fox"}, context)

        assert output =~ "saved it to"
        assert output =~ "no chat channel"
      after
        FermixTestSupport.SafeRm.rm_rf!(tmp_dir)
      end
    end
  end

  describe "execute/2 — edit" do
    test "edits the last inbound channel image and sends the result" do
      tmp_dir = FermixTestSupport.SafeRm.make_tmp_dir!("generate-image-edit")
      test_pid = self()

      try do
        configure_openai(tmp_dir, %{"data" => [%{"b64_json" => Base.encode64("EDITED")}]})

        context =
          channel_context(tmp_dir, test_pid)
          |> Map.put(:inbound_images, [%{type: :image, mime_type: "image/png", data: "INBOUND"}])

        args = %{
          "prompt" => "make the sky stormy",
          "operation" => "edit",
          "input_image" => "inbound:last"
        }

        assert {:ok, %{success: true, output: output}} = GenerateImage.execute(args, context)
        assert output =~ "Edited"
        assert_receive {:reply, {:media, %{kind: :image}}}
      after
        FermixTestSupport.SafeRm.rm_rf!(tmp_dir)
      end
    end

    test "fails loud when an edit references an inbound image that is not attached" do
      tmp_dir = FermixTestSupport.SafeRm.make_tmp_dir!("generate-image-edit-missing")

      try do
        configure_openai(tmp_dir, %{"data" => [%{"b64_json" => Base.encode64("X")}]})

        context = channel_context(tmp_dir, self())

        args = %{"prompt" => "x", "operation" => "edit", "input_image" => "inbound:last"}

        assert {:ok, %{success: false, error: error}} = GenerateImage.execute(args, context)
        assert error =~ "no inbound image is attached"
      after
        FermixTestSupport.SafeRm.rm_rf!(tmp_dir)
      end
    end
  end

  describe "execute/2 — provider errors surface" do
    test "an auth failure from the backend surfaces as a tool error" do
      tmp_dir = FermixTestSupport.SafeRm.make_tmp_dir!("generate-image-auth")

      try do
        test_id = unique_id()
        Req.Test.stub(test_id, fn conn -> Plug.Conn.resp(conn, 401, "") end)

        Application.put_env(:fermix_core, :tools,
          generate_image: [backend: "openai", api_key: "sk-test"]
        )

        context = base_context(tmp_dir) |> Map.put(:req_options, plug: {Req.Test, test_id})

        assert {:ok, %{success: false, error: error}} =
                 GenerateImage.execute(%{"prompt" => "a fox"}, context)

        assert error =~ "auth_failed"
      after
        FermixTestSupport.SafeRm.rm_rf!(tmp_dir)
      end
    end
  end

  describe "execute/2 — capability gating" do
    test "rejects a mask on a backend that does not support masks, before any HTTP call" do
      tmp_dir = FermixTestSupport.SafeRm.make_tmp_dir!("generate-image-mask-gate")
      test_pid = self()
      test_id = unique_id()

      try do
        # xAI advertises `mask: false`; the tool must reject the mask loudly
        # rather than silently dropping it or calling the backend.
        Req.Test.stub(test_id, fn conn ->
          send(test_pid, :unexpected_request)
          json_response(conn, %{})
        end)

        Application.put_env(:fermix_core, :tools,
          generate_image: [backend: "xai", api_key: "sk-test"]
        )

        context =
          base_context(tmp_dir)
          |> Map.put(:req_options, plug: {Req.Test, test_id})
          |> Map.put(:inbound_images, [%{type: :image, mime_type: "image/png", data: "INBOUND"}])

        args = %{
          "prompt" => "swap the background",
          "operation" => "edit",
          "input_image" => "inbound:last",
          "mask" => "mask.png"
        }

        assert {:ok, %{success: false, error: error}} = GenerateImage.execute(args, context)
        assert error =~ "Mask editing is only supported by the OpenAI backend"
        refute_received :unexpected_request
      after
        FermixTestSupport.SafeRm.rm_rf!(tmp_dir)
      end
    end
  end

  # --- helpers -------------------------------------------------------------

  defp configure_openai(_tmp_dir, response_data) do
    test_id = unique_id()
    Req.Test.stub(test_id, fn conn -> json_response(conn, response_data) end)

    Application.put_env(:fermix_core, :tools,
      generate_image: [backend: "openai", api_key: "sk-test"]
    )

    Process.put(:openai_test_id, test_id)
    :ok
  end

  defp base_context(root) do
    %{
      agent_name: "main",
      conversation_key: :test,
      cwd: root,
      sandbox_config: %{mode: :strict, workspace_root: root, allowed_roots: [root]},
      req_options: [plug: {Req.Test, Process.get(:openai_test_id)}]
    }
  end

  defp channel_context(root, test_pid) do
    Map.put(base_context(root), :reply_fn, fn part ->
      send(test_pid, {:reply, part})
      :ok
    end)
  end

  defp json_response(conn, body) do
    {:ok, _body, conn} = Plug.Conn.read_body(conn, length: 10_000_000)

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(body))
  end

  defp attach_tool_telemetry do
    handler_id = "generate-image-telemetry-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:fermix, :tool, :exec],
      fn _event, _measurements, metadata, _config ->
        if metadata.tool == "generate_image", do: send(test_pid, {:telemetry, metadata})
      end,
      nil
    )

    handler_id
  end

  defp unique_id, do: :"generate_image_#{System.unique_integer([:positive])}"

  defp restore(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore(key, value), do: Application.put_env(:fermix_core, key, value)
end
