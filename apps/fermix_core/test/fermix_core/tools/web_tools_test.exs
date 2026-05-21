defmodule FermixCore.Tools.WebToolsTest do
  use ExUnit.Case, async: true

  alias FermixCore.Tools.WebFetch
  alias FermixCore.Tools.WebSearch

  @context %{agent_name: "test_agent", conversation_key: :test}
  test "web_fetch fetches HTML and returns readable markdown" do
    test_id = :"web_fetch_#{System.unique_integer([:positive])}"

    Req.Test.stub(test_id, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/html")
      |> Plug.Conn.resp(200, "<h1>Docs</h1><p>Hello <a href=\"/x\">world</a></p>")
    end)

    context =
      Map.merge(@context, %{
        req_options: [plug: {Req.Test, test_id}],
        net_resolver: public_resolver()
      })

    assert {:ok, result} =
             WebFetch.execute(%{"url" => "https://example.com/docs"}, context)

    assert result.success == true
    assert result.output =~ "# Docs"
    assert result.output =~ "Hello [world](/x)"
  end

  test "web_fetch streams response body through a bounded collector" do
    test_id = :"web_fetch_stream_#{System.unique_integer([:positive])}"
    test_pid = self()

    Req.Test.stub(test_id, fn conn ->
      Plug.Conn.resp(conn, 200, "<h1>Docs</h1>")
    end)

    probe_plugin = fn req ->
      Req.Request.append_request_steps(req,
        assert_streaming: fn request ->
          send(test_pid, {:web_fetch_into, is_function(request.into, 2)})
          request
        end
      )
    end

    context =
      Map.merge(@context, %{
        req_options: [plugins: [probe_plugin], plug: {Req.Test, test_id}],
        net_resolver: public_resolver()
      })

    assert {:ok, result} =
             WebFetch.execute(%{"url" => "https://example.com/docs"}, context)

    assert result.success == true
    assert_received {:web_fetch_into, true}
  end

  test "web_fetch reports the streamed body cap" do
    test_id = :"web_fetch_body_cap_#{System.unique_integer([:positive])}"

    Req.Test.stub(test_id, fn conn ->
      Plug.Conn.resp(conn, 200, String.duplicate("x", 1_048_577))
    end)

    context =
      Map.merge(@context, %{
        req_options: [plug: {Req.Test, test_id}],
        net_resolver: public_resolver()
      })

    assert {:ok, result} =
             WebFetch.execute(%{"url" => "https://example.com/huge"}, context)

    assert result.success == false
    assert result.error =~ "too_large"
  end

  test "web_fetch blocks private redirects before following them" do
    test_id = :"web_fetch_redirect_#{System.unique_integer([:positive])}"

    Req.Test.stub(test_id, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "http://private.example/secret")
      |> Plug.Conn.resp(302, "")
    end)

    context =
      Map.merge(@context, %{
        req_options: [plug: {Req.Test, test_id}],
        net_resolver: public_resolver()
      })

    assert {:ok, result} =
             WebFetch.execute(%{"url" => "https://example.com/start"}, context)

    assert result.success == false
    assert result.error =~ "blocked"
  end

  test "web_search parses DuckDuckGo HTML results" do
    test_id = :"web_search_#{System.unique_integer([:positive])}"

    Req.Test.stub(test_id, fn conn ->
      Plug.Conn.resp(conn, 200, ddg_results_fixture())
    end)

    context =
      Map.merge(@context, %{
        req_options: [plug: {Req.Test, test_id}],
        net_resolver: public_resolver()
      })

    assert {:ok, result} = WebSearch.execute(%{"query" => "fermix"}, context)
    assert result.success == true

    [%{"title" => title, "url" => url, "snippet" => snippet} | _] = Jason.decode!(result.output)
    assert title == "Fermix"
    assert url == "https://example.com/fermix"
    assert snippet =~ "agent platform"
  end

  test "web_search distinguishes empty results, rate limits, and parser changes" do
    assert_search_error("<div class=\"no-results\">No results</div>", nil)

    assert_search_error(
      "<html><title>Checking if the site connection is secure</title></html>",
      "rate_limited"
    )

    assert_search_error(
      "<html><body><div class=\"renamed-result\"></div></body></html>",
      "parser_changed"
    )

    assert_search_error(
      "<html><body><footer>No results does not mean the result list is empty.</footer></body></html>",
      "parser_changed"
    )
  end

  test "web_search rejects overlong queries" do
    assert {:ok, result} = WebSearch.execute(%{"query" => String.duplicate("x", 1025)}, @context)
    assert result.success == false
    assert result.error =~ "query_too_long"
  end

  test "web tools emit only redacted request headers in telemetry" do
    web_fetch_id = :"web_fetch_headers_#{System.unique_integer([:positive])}"
    web_search_id = :"web_search_headers_#{System.unique_integer([:positive])}"
    fetch_handler = attach_tool_telemetry("web_fetch")
    search_handler = attach_tool_telemetry("web_search")

    Req.Test.stub(web_fetch_id, fn conn ->
      Plug.Conn.resp(conn, 200, "<h1>Docs</h1>")
    end)

    Req.Test.stub(web_search_id, fn conn ->
      Plug.Conn.resp(conn, 200, ddg_results_fixture())
    end)

    sensitive_headers = [
      {"authorization", "Bearer secret"},
      {"x-api-key", "key-secret"},
      {"user-agent", "fermix-test"}
    ]

    fetch_context =
      Map.merge(@context, %{
        req_options: [headers: sensitive_headers, plug: {Req.Test, web_fetch_id}],
        net_resolver: public_resolver()
      })

    search_context =
      Map.merge(@context, %{
        req_options: [headers: sensitive_headers, plug: {Req.Test, web_search_id}],
        net_resolver: public_resolver()
      })

    assert {:ok, %{success: true}} =
             WebFetch.execute(%{"url" => "https://example.com/docs"}, fetch_context)

    assert {:ok, %{success: true}} = WebSearch.execute(%{"query" => "fermix"}, search_context)

    assert_receive {:telemetry, [:fermix, :tool, :exec], _measurements,
                    %{tool: "web_fetch", request_headers: fetch_headers}}

    assert_receive {:telemetry, [:fermix, :tool, :exec], _measurements,
                    %{
                      tool: "web_search",
                      request_headers: search_headers,
                      result_count: search_result_count
                    }}

    assert %{name: "authorization", value: "***REDACTED***"} in fetch_headers
    assert %{name: "x-api-key", value: "***REDACTED***"} in fetch_headers
    assert %{name: "authorization", value: "***REDACTED***"} in search_headers
    assert %{name: "x-api-key", value: "***REDACTED***"} in search_headers
    assert is_integer(search_result_count) and search_result_count > 0
    refute inspect(fetch_headers) =~ "secret"
    refute inspect(search_headers) =~ "secret"

    :telemetry.detach(fetch_handler)
    :telemetry.detach(search_handler)
  end

  test "web_search emits result_count: 0 when DuckDuckGo returns no results" do
    test_id = :"web_search_empty_#{System.unique_integer([:positive])}"
    handler = attach_tool_telemetry("web_search")

    Req.Test.stub(test_id, fn conn ->
      Plug.Conn.resp(conn, 200, "<div class=\"no-results\">No results</div>")
    end)

    context =
      Map.merge(@context, %{
        req_options: [plug: {Req.Test, test_id}],
        net_resolver: public_resolver()
      })

    assert {:ok, %{success: true, output: "[]"}} =
             WebSearch.execute(%{"query" => "unlikely"}, context)

    assert_receive {:telemetry, [:fermix, :tool, :exec], _measurements,
                    %{tool: "web_search", result_count: 0}}

    :telemetry.detach(handler)
  end

  defp assert_search_error(body, expected_tag) do
    test_id = :"web_search_error_#{System.unique_integer([:positive])}"
    Req.Test.stub(test_id, fn conn -> Plug.Conn.resp(conn, 200, body) end)

    context =
      Map.merge(@context, %{
        req_options: [plug: {Req.Test, test_id}],
        net_resolver: public_resolver()
      })

    assert {:ok, result} = WebSearch.execute(%{"query" => "unlikely"}, context)

    if expected_tag do
      assert result.success == false
      assert result.error =~ expected_tag
    else
      assert result.success == true
      assert Jason.decode!(result.output) == []
    end
  end

  defp ddg_results_fixture do
    """
    <html><body>
      <div class="result">
        <h2 class="result__title">
          <a class="result__a" href="https://example.com/fermix">Fermix</a>
        </h2>
        <a class="result__snippet">Elixir agent platform.</a>
      </div>
    </body></html>
    """
  end

  defp public_resolver do
    fn
      "example.com" -> {:ok, [{93, 184, 216, 34}]}
      "html.duckduckgo.com" -> {:ok, [{52, 149, 246, 39}]}
      "private.example" -> {:ok, [{127, 0, 0, 1}]}
    end
  end

  defp attach_tool_telemetry(tool) do
    handler_id = "test-web-tool-#{tool}-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:fermix, :tool, :exec],
      fn event, measurements, metadata, _config ->
        if metadata.tool == tool do
          send(test_pid, {:telemetry, event, measurements, metadata})
        end
      end,
      nil
    )

    handler_id
  end
end
