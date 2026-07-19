defmodule FermixCore.Tools.Media.Backends.CodexImageTest do
  # async: true — auth is an OAuth token seam / explicit fake path, never global
  # env or the real auth store (hermetic-tests rule).
  use ExUnit.Case, async: true

  alias FermixCore.Tools.Media.Backends.CodexImage

  describe "metadata" do
    test "declares its name, modality, capability gate and image model" do
      assert CodexImage.name() == :codex_image
      assert CodexImage.modality() == :image
      assert CodexImage.supported_models() == ["gpt-image-2"]

      assert CodexImage.capabilities() == %{
               ops: [:generate, :edit],
               mask: false,
               multi_image_ref: false,
               async: false
             }
    end

    test "configured? is true with an access token and false with no resolvable token" do
      assert CodexImage.configured?(access_token: "chatgpt-oauth-token")
      refute CodexImage.configured?(fermix_auth_path: missing_auth_path())
    end
  end

  describe "run(:generate, ...)" do
    test "posts the confirmed Codex responses body and decodes the image result" do
      png = "\x89PNG-bytes"

      {result, req} =
        run_generate(%{prompt: "a watercolor fox"}, image_sse(png))

      assert {:ok, %{bytes: ^png, mime: "image/png", ext: "png"}, %{}} = result

      # Top-level router model + the image model carried on the tool.
      assert req.body["model"] == "gpt-5.6-terra"
      assert req.body["store"] == false
      assert req.body["stream"] == true
      assert req.body["tool_choice"] == "auto"

      tool = hd(req.body["tools"])
      assert tool["type"] == "image_generation"
      assert tool["model"] == "gpt-image-2"
      assert tool["output_format"] == "png"
      # Generate stays byte-identical to the proven probe body: no `action`, no `size`.
      refute Map.has_key?(tool, "action")
      refute Map.has_key?(tool, "size")

      message = hd(req.body["input"])
      assert message["role"] == "user"
      assert message["content"] == [%{"type" => "input_text", "text" => "a watercolor fox"}]

      # Native Codex header profile (identical to the chat adapter's).
      assert {"authorization", "Bearer chatgpt-oauth-token"} in req.headers
      assert {"openai-beta", "responses=experimental"} in req.headers
      assert {"originator", "pi"} in req.headers
      # A non-JWT token yields no account id, so the header is omitted (not empty).
      refute List.keymember?(req.headers, "chatgpt-account-id", 0)
    end

    test "sends chatgpt-account-id when the bearer JWT carries an account claim" do
      jwt = jwt_with_sub("acct-42")
      {result, req} = run_generate(%{prompt: "x"}, image_sse("Y"), access_token: jwt)

      assert {:ok, _artifact, _trace} = result
      assert {"chatgpt-account-id", "acct-42"} in req.headers
    end

    test "includes size on the tool only when requested" do
      {_result, req} =
        run_generate(%{prompt: "x", size: "1024x1024"}, image_sse("Y"))

      assert hd(req.body["tools"])["size"] == "1024x1024"
    end

    test "honors router_model and image model overrides" do
      {result, req} =
        run_generate(%{prompt: "x"}, image_sse("Y"),
          router_model: "gpt-5.5",
          model: "gpt-image-1.5"
        )

      assert {:ok, _artifact, _trace} = result
      assert req.body["model"] == "gpt-5.5"
      assert hd(req.body["tools"])["model"] == "gpt-image-1.5"
    end
  end

  describe "run(:edit, ...)" do
    test "carries the source image as an input_image data-URI part and sets action edit" do
      request = %{
        prompt: "make the sky stormy",
        input_image: %{bytes: "SRCPNG", mime: "image/png", filename: "src.png"}
      }

      {result, req} = run(:edit, request, image_sse("OUT"))

      assert {:ok, %{bytes: "OUT", mime: "image/png"}, %{}} = result
      assert hd(req.body["tools"])["action"] == "edit"

      content = hd(req.body["input"])["content"]
      assert %{"type" => "input_text", "text" => "make the sky stormy"} in content

      data_uri = "data:image/png;base64,#{Base.encode64("SRCPNG")}"
      assert %{"type" => "input_image", "image_url" => data_uri} in content
    end
  end

  describe "error mapping" do
    test "403 group-gate maps to an actionable auth_failed" do
      body = %{"error" => %{"message" => "Image generation is not enabled for this group"}}
      assert {:error, message, %{}} = run_error(403, body)
      assert message =~ "auth_failed"
      assert message =~ "not enabled for this ChatGPT account/plan"
    end

    test "other 401/403 map to auth_failed" do
      assert {:error, m401, %{}} = run_error(401, %{})
      assert m401 =~ "auth_failed"
      assert {:error, m403, %{}} = run_error(403, %{"error" => %{"message" => "nope"}})
      assert m403 =~ "auth_failed"
    end

    test "429 maps to rate_limited" do
      assert {:error, message, %{}} = run_error(429, %{})
      assert message =~ "rate_limited"
    end

    test "other non-2xx maps to provider_error with the vendor message" do
      assert {:error, message, %{}} =
               run_error(400, %{"error" => %{"message" => "bad model"}})

      assert message =~ "provider_error"
      assert message =~ "HTTP 400"
      assert message =~ "bad model"
    end

    test "a 200 with only text maps to provider_error carrying the text" do
      {result, _req} = run(:generate, %{prompt: "x"}, text_sse("I cannot do that."))
      assert {:error, message, %{}} = result
      assert message =~ "provider_error"
      assert message =~ "I cannot do that."
    end

    test "a 200 with neither image nor text maps to parser_changed" do
      empty =
        "data: " <> Jason.encode!(%{"type" => "response.completed"}) <> "\n\ndata: [DONE]\n\n"

      {result, _req} = run(:generate, %{prompt: "x"}, empty)
      assert {:error, message, %{}} = result
      assert message =~ "parser_changed"
    end

    test "a transport failure maps to network" do
      test_id = unique_id()
      Req.Test.stub(test_id, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, message, %{}} =
               CodexImage.run(:generate, %{prompt: "x"}, opts(test_id, access_token: "t"))

      assert message =~ "network"
    end
  end

  describe "auth resolution" do
    test "fails loud before any HTTP request when no token is resolvable" do
      test_pid = self()
      test_id = unique_id()

      Req.Test.stub(test_id, fn conn ->
        send(test_pid, :unexpected_request)
        Plug.Conn.resp(conn, 200, "")
      end)

      assert {:error, message, %{}} =
               CodexImage.run(
                 :generate,
                 %{prompt: "x"},
                 opts(test_id, fermix_auth_path: missing_auth_path())
               )

      assert message =~ "auth_failed"
      assert message =~ "connect OpenAI Codex"
      refute_received :unexpected_request
    end
  end

  # --- helpers -------------------------------------------------------------

  defp run_generate(request, sse_body, extra_opts \\ []) do
    run(:generate, request, sse_body, extra_opts)
  end

  # Drives one call and captures the decoded request body + headers.
  defp run(operation, request, sse_body, extra_opts \\ []) do
    test_pid = self()
    test_id = unique_id()

    Req.Test.stub(test_id, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn, length: 50_000_000)
      send(test_pid, {:request, %{body: Jason.decode!(raw), headers: conn.req_headers}})

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.resp(200, sse_body)
    end)

    result =
      CodexImage.run(
        operation,
        request,
        opts(test_id, Keyword.merge([access_token: "chatgpt-oauth-token"], extra_opts))
      )

    assert_receive {:request, req}
    {result, req}
  end

  defp run_error(status, body) do
    test_id = unique_id()

    Req.Test.stub(test_id, fn conn ->
      {:ok, _raw, conn} = Plug.Conn.read_body(conn, length: 50_000_000)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end)

    CodexImage.run(:generate, %{prompt: "x"}, opts(test_id, access_token: "t"))
  end

  # An SSE body whose image_generation_call output item carries the base64 result
  # (status "generating" — the probe showed `result` is present before "completed").
  defp image_sse(png) do
    sse([
      %{
        "type" => "response.output_item.done",
        "output_index" => 0,
        "item" => %{
          "type" => "image_generation_call",
          "status" => "generating",
          "output_format" => "png",
          "result" => Base.encode64(png)
        }
      }
    ])
  end

  defp text_sse(text) do
    sse([
      %{
        "type" => "response.output_item.done",
        "output_index" => 0,
        "item" => %{
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "output_text", "text" => text}]
        }
      }
    ])
  end

  defp sse(events) do
    Enum.map_join(events, "", fn event -> "data: " <> Jason.encode!(event) <> "\n\n" end) <>
      "data: [DONE]\n\n"
  end

  defp jwt_with_sub(sub) do
    payload = Base.url_encode64(Jason.encode!(%{"sub" => sub}), padding: false)
    "header.#{payload}.signature"
  end

  defp opts(test_id, extra) do
    Keyword.merge([context: %{req_options: [plug: {Req.Test, test_id}]}], extra)
  end

  defp missing_auth_path,
    do: "/nonexistent-fermix-auth-#{System.unique_integer([:positive])}.json"

  defp unique_id, do: :"codex_image_#{System.unique_integer([:positive])}"
end
