defmodule FermixCore.Tools.Media.Backends.GoogleImageTest do
  use ExUnit.Case, async: true

  alias FermixCore.Tools.Media.Backends.GoogleImage

  describe "metadata" do
    test "declares its name, modality and capability gate (no mask)" do
      assert GoogleImage.name() == :google_image
      assert GoogleImage.modality() == :image

      assert GoogleImage.capabilities() == %{
               ops: [:generate, :edit],
               mask: false,
               multi_image_ref: false,
               async: false
             }
    end

    test "configured? reflects whether the tool-block key resolves" do
      assert GoogleImage.configured?(google_api_key: "g-key")
      refute GoogleImage.configured?([])
      refute GoogleImage.configured?(google_api_key: "@keyring")
    end
  end

  describe "run(:generate, ...)" do
    test "posts contents.parts with the prompt and the x-goog-api-key header" do
      png = "PNG"

      {result, req} =
        run(:generate, %{prompt: "a koi pond"}, inline_response(png, "image/png"))

      assert {:ok, %{bytes: ^png, mime: "image/png", ext: "png"}, %{}} = result
      assert req.body["contents"] == [%{"parts" => [%{"text" => "a koi pond"}]}]
      # Gemini Developer API uses x-goog-api-key, never a Bearer token.
      assert {"x-goog-api-key", "g-key"} in req.headers
      refute Enum.any?(req.headers, fn {k, _v} -> k == "authorization" end)
      # generateContent endpoint, model in the path.
      assert req.path =~ "gemini-3.1-flash-image:generateContent"
    end

    test "decodes a camelCase inlineData part and honors its mimeType" do
      {result, _req} =
        run(:generate, %{prompt: "x"}, inline_response(Base.encode64("J"), "image/jpeg", :raw))

      assert {:ok, %{bytes: "J", mime: "image/jpeg", ext: "jpg"}, %{}} = result
    end

    test "defaults the mime to png when the part omits mimeType" do
      response = %{
        "candidates" => [
          %{"content" => %{"parts" => [%{"inlineData" => %{"data" => Base.encode64("Z")}}]}}
        ]
      }

      {result, _req} = run(:generate, %{prompt: "x"}, response)
      assert {:ok, %{bytes: "Z", mime: "image/png"}, %{}} = result
    end
  end

  describe "run(:edit, ...)" do
    test "appends the source image as a snake_case inline_data part" do
      request = %{
        prompt: "add a hat",
        input_image: %{bytes: "SRCPNG", mime: "image/png", filename: "src.png"}
      }

      {result, req} = run(:edit, request, inline_response("OUT", "image/png"))

      assert {:ok, %{bytes: "OUT"}, %{}} = result
      [%{"parts" => parts}] = req.body["contents"]
      assert %{"text" => "add a hat"} in parts

      assert %{"inline_data" => %{"mime_type" => "image/png", "data" => Base.encode64("SRCPNG")}} in parts
    end
  end

  describe "error mapping" do
    test "maps auth, rate-limit, provider and parser failures" do
      assert {:error, m403, %{}} = run_error(403, %{})
      assert m403 =~ "auth_failed"
      assert {:error, m429, %{}} = run_error(429, %{})
      assert m429 =~ "rate_limited"

      assert {:error, m400, %{}} =
               run_error(400, %{"error" => %{"message" => "API key not valid"}})

      assert m400 =~ "provider_error"
      assert m400 =~ "API key not valid"

      assert {:error, m200, %{}} = run_error(200, %{"candidates" => [%{"content" => %{}}]})
      assert m200 =~ "parser_changed"
    end

    test "a transport failure maps to network" do
      test_id = unique_id()
      Req.Test.stub(test_id, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, message, %{}} =
               GoogleImage.run(:generate, %{prompt: "x"}, opts(test_id, google_api_key: "g-key"))

      assert message =~ "network"
    end
  end

  describe "refusal" do
    test "fails loud before any HTTP request when no key is configured" do
      test_pid = self()
      test_id = unique_id()

      Req.Test.stub(test_id, fn conn ->
        send(test_pid, :unexpected_request)
        json_response(conn, %{})
      end)

      assert {:error, message, %{}} = GoogleImage.run(:generate, %{prompt: "x"}, opts(test_id))
      assert message =~ "auth_failed"
      refute_received :unexpected_request
    end
  end

  # --- helpers -------------------------------------------------------------

  defp run(operation, request, response_data) do
    test_pid = self()
    test_id = unique_id()

    Req.Test.stub(test_id, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn, length: 10_000_000)

      send(
        test_pid,
        {:request,
         %{body: Jason.decode!(body), headers: conn.req_headers, path: conn.request_path}}
      )

      json_response(conn, response_data)
    end)

    result = GoogleImage.run(operation, request, opts(test_id, google_api_key: "g-key"))
    assert_receive {:request, req}
    {result, req}
  end

  # candidates[].content.parts[].inlineData.{data,mimeType}; `:raw` passes the
  # data through verbatim (already base64), otherwise it is encoded here.
  defp inline_response(data, mime, mode \\ :encode) do
    encoded = if mode == :raw, do: data, else: Base.encode64(data)

    %{
      "candidates" => [
        %{
          "content" => %{"parts" => [%{"inlineData" => %{"data" => encoded, "mimeType" => mime}}]}
        }
      ]
    }
  end

  defp run_error(status, body) do
    test_id = unique_id()

    Req.Test.stub(test_id, fn conn ->
      {:ok, _body, conn} = Plug.Conn.read_body(conn, length: 10_000_000)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end)

    GoogleImage.run(:generate, %{prompt: "x"}, opts(test_id, google_api_key: "g-key"))
  end

  defp json_response(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(body))
  end

  defp opts(test_id, extra \\ []) do
    Keyword.merge([context: %{req_options: [plug: {Req.Test, test_id}]}], extra)
  end

  defp unique_id, do: :"google_image_#{System.unique_integer([:positive])}"
end
