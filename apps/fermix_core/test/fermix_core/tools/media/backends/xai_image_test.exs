defmodule FermixCore.Tools.Media.Backends.XAIImageTest do
  # async: false — the credential-reuse test reads the global `:providers` env.
  use ExUnit.Case, async: false

  alias FermixCore.Tools.Media.Backends.XAIImage

  # A minimal valid-magic PNG so `materialize_url` sniffs `image/png`.
  @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>> <> "pixels"

  # `materialize_url/2` screens the provider-returned URL with Net.Guard, which
  # resolves DNS names. A public IP literal is validated without a lookup, so
  # the temporary-URL tests below stay hermetic.
  @image_cdn "https://93.184.216.34/tmp"

  setup do
    providers = Application.get_env(:fermix_core, :providers)
    on_exit(fn -> restore(:providers, providers) end)
    :ok
  end

  describe "metadata" do
    test "declares its name, modality and capability gate (no mask)" do
      assert XAIImage.name() == :xai_image
      assert XAIImage.modality() == :image

      assert XAIImage.capabilities() == %{
               ops: [:generate, :edit],
               mask: false,
               multi_image_ref: false,
               async: false
             }
    end
  end

  describe "run(:generate, ...)" do
    test "always requests b64_json and decodes it" do
      png = "PNG"

      {result, req} =
        run_generate(%{prompt: "a neon city", size: "1024x768"}, %{
          "data" => [%{"b64_json" => Base.encode64(png)}]
        })

      assert {:ok, %{bytes: ^png, mime: "image/png", ext: "png"}, %{}} = result
      assert req.body["model"] == "grok-imagine-image-quality"
      assert req.body["prompt"] == "a neon city"
      assert req.body["n"] == 1
      # xAI defaults to a temporary URL unless b64_json is requested explicitly.
      assert req.body["response_format"] == "b64_json"
      assert req.body["size"] == "1024x768"
      assert {"authorization", "Bearer sk-test"} in req.headers
    end

    test "omits size when none is requested and honors a model override" do
      {result, req} =
        run_generate(
          %{prompt: "x"},
          %{"data" => [%{"b64_json" => Base.encode64("Y")}]},
          model: "grok-imagine-image-fast"
        )

      assert {:ok, _artifact, _trace} = result
      refute Map.has_key?(req.body, "size")
      assert req.body["model"] == "grok-imagine-image-fast"
    end
  end

  describe "run(:edit, ...)" do
    test "embeds the source image as a base64 data-uri" do
      request = %{
        prompt: "make it rain",
        input_image: %{bytes: "SRCPNG", mime: "image/png", filename: "src.png"}
      }

      {result, req} = run_edit(request, %{"data" => [%{"b64_json" => Base.encode64("OUT")}]})

      assert {:ok, %{bytes: "OUT", mime: "image/png"}, %{}} = result
      assert req.body["prompt"] == "make it rain"
      assert req.body["response_format"] == "b64_json"
      assert req.body["image"] == "data:image/png;base64,#{Base.encode64("SRCPNG")}"
    end
  end

  describe "temporary-URL response shape" do
    test "materializes a returned URL into bytes before it expires" do
      test_id = unique_id()

      # One plug handles both the generate POST and the follow-up image GET.
      Req.Test.stub(test_id, fn conn ->
        if String.contains?(conn.request_path, "/images/generations") do
          {:ok, _body, conn} = Plug.Conn.read_body(conn, length: 10_000_000)
          json_response(conn, %{"data" => [%{"url" => "#{@image_cdn}/abc.png"}]})
        else
          conn
          |> Plug.Conn.put_resp_content_type("image/png")
          |> Plug.Conn.resp(200, @png)
        end
      end)

      assert {:ok, %{bytes: @png, mime: "image/png", ext: "png"}, %{}} =
               XAIImage.run(:generate, %{prompt: "x"}, opts(test_id, api_key: "sk-test"))
    end

    test "a zero-byte materialized URL fails loud as parser drift" do
      test_id = unique_id()

      Req.Test.stub(test_id, fn conn ->
        if String.contains?(conn.request_path, "/images/generations") do
          {:ok, _body, conn} = Plug.Conn.read_body(conn, length: 10_000_000)
          json_response(conn, %{"data" => [%{"url" => "#{@image_cdn}/empty.png"}]})
        else
          Plug.Conn.resp(conn, 200, "")
        end
      end)

      assert {:error, message, %{}} =
               XAIImage.run(:generate, %{prompt: "x"}, opts(test_id, api_key: "sk-test"))

      assert message =~ "parser_changed"
    end
  end

  describe "error mapping" do
    test "maps auth, rate-limit, provider and parser failures" do
      assert {:error, m401, %{}} = run_error(401, %{})
      assert m401 =~ "auth_failed"
      assert {:error, m429, %{}} = run_error(429, %{})
      assert m429 =~ "rate_limited"

      assert {:error, m400, %{}} = run_error(400, %{"error" => "bad prompt"})
      assert m400 =~ "provider_error"
      assert m400 =~ "bad prompt"

      assert {:error, m200, %{}} = run_error(200, %{"unexpected" => true})
      assert m200 =~ "parser_changed"
    end

    test "a transport failure maps to network" do
      test_id = unique_id()
      Req.Test.stub(test_id, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, message, %{}} =
               XAIImage.run(:generate, %{prompt: "x"}, opts(test_id, api_key: "sk-test"))

      assert message =~ "network"
    end
  end

  describe "credential reuse and refusal" do
    test "reuses the xAI chat-provider key when no opts api_key is given" do
      Application.put_env(:fermix_core, :providers, xai: [api_key: "sk-provider"])
      test_pid = self()
      test_id = unique_id()

      Req.Test.stub(test_id, fn conn ->
        send(test_pid, {:headers, conn.req_headers})
        {:ok, _body, conn} = Plug.Conn.read_body(conn, length: 10_000_000)
        json_response(conn, %{"data" => [%{"b64_json" => Base.encode64("Y")}]})
      end)

      assert {:ok, _artifact, _trace} = XAIImage.run(:generate, %{prompt: "x"}, opts(test_id))
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

      assert {:error, message, %{}} = XAIImage.run(:generate, %{prompt: "x"}, opts(test_id))
      assert message =~ "auth_failed"
      refute_received :unexpected_request
    end
  end

  # --- helpers -------------------------------------------------------------

  defp run_generate(request, response_data, extra_opts \\ []) do
    test_pid = self()
    test_id = unique_id()

    Req.Test.stub(test_id, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn, length: 10_000_000)
      send(test_pid, {:request, %{body: Jason.decode!(body), headers: conn.req_headers}})
      json_response(conn, response_data)
    end)

    result = XAIImage.run(:generate, request, opts(test_id, [api_key: "sk-test"] ++ extra_opts))
    assert_receive {:request, req}
    {result, req}
  end

  defp run_edit(request, response_data) do
    test_pid = self()
    test_id = unique_id()

    Req.Test.stub(test_id, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn, length: 10_000_000)
      send(test_pid, {:request, %{body: Jason.decode!(body), headers: conn.req_headers}})
      json_response(conn, response_data)
    end)

    result = XAIImage.run(:edit, request, opts(test_id, api_key: "sk-test"))
    assert_receive {:request, req}
    {result, req}
  end

  defp run_error(status, body) do
    test_id = unique_id()

    Req.Test.stub(test_id, fn conn ->
      {:ok, _body, conn} = Plug.Conn.read_body(conn, length: 10_000_000)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end)

    XAIImage.run(:generate, %{prompt: "x"}, opts(test_id, api_key: "sk-test"))
  end

  defp json_response(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(body))
  end

  defp opts(test_id, extra \\ []) do
    Keyword.merge([context: %{req_options: [plug: {Req.Test, test_id}]}], extra)
  end

  defp unique_id, do: :"xai_image_#{System.unique_integer([:positive])}"

  defp restore(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore(key, value), do: Application.put_env(:fermix_core, key, value)
end
