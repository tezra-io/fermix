defmodule FermixCore.Tools.Media.Backends.OpenAIImageTest do
  # async: false — the credential-reuse test reads the global `:providers` env.
  use ExUnit.Case, async: false

  alias FermixCore.Tools.Media.Backends.OpenAIImage

  setup do
    providers = Application.get_env(:fermix_core, :providers)
    on_exit(fn -> restore(:providers, providers) end)
    :ok
  end

  describe "metadata" do
    test "declares its name, modality and capability gate" do
      assert OpenAIImage.name() == :openai_image
      assert OpenAIImage.modality() == :image

      assert OpenAIImage.capabilities() == %{
               ops: [:generate, :edit],
               mask: true,
               multi_image_ref: true,
               async: false
             }
    end

    test "configured? reflects whether a credential resolves" do
      assert OpenAIImage.configured?(api_key: "sk-test")
      Application.put_env(:fermix_core, :providers, [])
      refute OpenAIImage.configured?([])
    end
  end

  describe "run(:generate, ...)" do
    test "sends a JSON body without response_format and decodes b64_json" do
      png = "PNG"

      {result, req} =
        run_generate(%{prompt: "a watercolor fox", size: "1024x1024"}, %{
          "data" => [%{"b64_json" => Base.encode64(png)}]
        })

      assert {:ok, %{bytes: ^png, mime: "image/png", ext: "png"}, %{}} = result
      assert req.body["model"] == "gpt-image-2"
      assert req.body["prompt"] == "a watercolor fox"
      assert req.body["n"] == 1
      assert req.body["size"] == "1024x1024"
      # GPT image models reject response_format / input_fidelity / background.
      refute Map.has_key?(req.body, "response_format")
      refute Map.has_key?(req.body, "input_fidelity")
      refute Map.has_key?(req.body, "background")
      # Bearer auth from the configured key.
      assert {"authorization", "Bearer sk-test"} in req.headers
    end

    test "omits size when none is requested" do
      {result, req} =
        run_generate(%{prompt: "x"}, %{"data" => [%{"b64_json" => Base.encode64("Y")}]})

      assert {:ok, _artifact, _trace} = result
      refute Map.has_key?(req.body, "size")
    end

    test "honors a model override" do
      {result, req} =
        run_generate(
          %{prompt: "x"},
          %{"data" => [%{"b64_json" => Base.encode64("Y")}]},
          model: "gpt-image-1.5"
        )

      assert {:ok, _artifact, _trace} = result
      assert req.body["model"] == "gpt-image-1.5"
    end
  end

  describe "run(:edit, ...)" do
    test "sends a multipart body with the image part and prompt" do
      request = %{
        prompt: "make the sky stormy",
        input_image: %{bytes: "SRCPNG", mime: "image/png", filename: "src.png"}
      }

      {result, raw, content_type} =
        run_edit(request, %{"data" => [%{"b64_json" => Base.encode64("OUT")}]})

      assert {:ok, %{bytes: "OUT", mime: "image/png"}, %{}} = result
      assert content_type =~ "multipart/form-data"
      assert raw =~ ~s(name="model")
      assert raw =~ ~s(name="prompt")
      assert raw =~ "make the sky stormy"
      assert raw =~ ~s(name="image")
      assert raw =~ ~s(filename="src.png")
      refute raw =~ ~s(name="mask")
    end

    test "includes the mask part when a mask is supplied" do
      request = %{
        prompt: "swap the background",
        input_image: %{bytes: "SRCPNG", mime: "image/png", filename: "src.png"},
        mask: %{bytes: "MASKPNG", mime: "image/png", filename: "mask.png"}
      }

      {result, raw, _content_type} =
        run_edit(request, %{"data" => [%{"b64_json" => Base.encode64("OUT")}]})

      assert {:ok, _artifact, _trace} = result
      assert raw =~ ~s(name="mask")
      assert raw =~ ~s(filename="mask.png")
    end
  end

  describe "error mapping" do
    test "401/403 map to auth_failed" do
      assert {:error, message, %{}} = run_error(401, %{})
      assert message =~ "auth_failed"
      assert {:error, message, %{}} = run_error(403, %{})
      assert message =~ "auth_failed"
    end

    test "429 maps to rate_limited" do
      assert {:error, message, %{}} = run_error(429, %{})
      assert message =~ "rate_limited"
    end

    test "other non-2xx maps to provider_error with the vendor message" do
      assert {:error, message, %{}} =
               run_error(400, %{"error" => %{"message" => "bad size value"}})

      assert message =~ "provider_error"
      assert message =~ "HTTP 400"
      assert message =~ "bad size value"
    end

    test "a 2xx with the wrong shape maps to parser_changed" do
      assert {:error, message, %{}} = run_error(200, %{"unexpected" => true})
      assert message =~ "parser_changed"
    end

    test "a transport failure maps to network" do
      test_id = unique_id()
      Req.Test.stub(test_id, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, message, %{}} =
               OpenAIImage.run(:generate, %{prompt: "x"}, opts(test_id, api_key: "sk-test"))

      assert message =~ "network"
    end
  end

  describe "credential reuse and refusal" do
    test "reuses the OpenAI chat-provider key when no opts api_key is given" do
      Application.put_env(:fermix_core, :providers, openai: [api_key: "sk-provider"])
      test_pid = self()
      test_id = unique_id()

      Req.Test.stub(test_id, fn conn ->
        send(test_pid, {:headers, conn.req_headers})
        {:ok, _body, conn} = Plug.Conn.read_body(conn, length: 10_000_000)
        json_response(conn, %{"data" => [%{"b64_json" => Base.encode64("Y")}]})
      end)

      assert {:ok, _artifact, _trace} = OpenAIImage.run(:generate, %{prompt: "x"}, opts(test_id))

      assert_receive {:headers, headers}
      assert {"authorization", "Bearer sk-provider"} in headers
    end

    test "fails loud before any HTTP request when no key is resolvable" do
      Application.put_env(:fermix_core, :providers, [])
      test_pid = self()
      test_id = unique_id()

      Req.Test.stub(test_id, fn conn ->
        send(test_pid, :unexpected_request)
        json_response(conn, %{})
      end)

      assert {:error, message, %{}} = OpenAIImage.run(:generate, %{prompt: "x"}, opts(test_id))
      assert message =~ "auth_failed"
      refute_received :unexpected_request
    end
  end

  # --- helpers -------------------------------------------------------------

  # Runs a JSON-body generate and captures the decoded request body + headers.
  defp run_generate(request, response_data, extra_opts \\ []) do
    test_pid = self()
    test_id = unique_id()

    Req.Test.stub(test_id, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn, length: 10_000_000)
      send(test_pid, {:request, %{body: Jason.decode!(body), headers: conn.req_headers}})
      json_response(conn, response_data)
    end)

    result =
      OpenAIImage.run(:generate, request, opts(test_id, [api_key: "sk-test"] ++ extra_opts))

    assert_receive {:request, req}
    {result, req}
  end

  # Runs a multipart edit and captures the raw body + content-type.
  defp run_edit(request, response_data) do
    test_pid = self()
    test_id = unique_id()

    Req.Test.stub(test_id, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn, length: 10_000_000)
      content_type = conn |> Plug.Conn.get_req_header("content-type") |> List.first()
      send(test_pid, {:multipart, raw, content_type})
      json_response(conn, response_data)
    end)

    result = OpenAIImage.run(:edit, request, opts(test_id, api_key: "sk-test"))
    assert_receive {:multipart, raw, content_type}
    {result, raw, content_type}
  end

  defp run_error(status, body) do
    test_id = unique_id()

    Req.Test.stub(test_id, fn conn ->
      {:ok, _body, conn} = Plug.Conn.read_body(conn, length: 10_000_000)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end)

    OpenAIImage.run(:generate, %{prompt: "x"}, opts(test_id, api_key: "sk-test"))
  end

  defp json_response(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(body))
  end

  defp opts(test_id, extra \\ []) do
    Keyword.merge([context: %{req_options: [plug: {Req.Test, test_id}]}], extra)
  end

  defp unique_id, do: :"openai_image_#{System.unique_integer([:positive])}"

  defp restore(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore(key, value), do: Application.put_env(:fermix_core, key, value)
end
