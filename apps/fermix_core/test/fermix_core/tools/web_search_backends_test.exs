defmodule FermixCore.Tools.WebSearchBackendsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixCore.Tools.WebSearch
  alias FermixCore.Tools.WebSearch.Backends.Support

  @context %{agent_name: "test_agent", conversation_key: :test}

  setup do
    tools = Application.get_env(:fermix_core, :tools)
    on_exit(fn -> restore_tools(tools) end)
    :ok
  end

  test "tavily backend sends direct HTTP request and normalizes results" do
    handler_id = attach_tool_telemetry()

    result =
      execute_search(
        [backend: :tavily, tavily_api_key: "tvly-secret"],
        fn conn ->
          {body, conn} = request_json(conn)
          assert {"authorization", "Bearer tvly-secret"} in conn.req_headers
          assert body["search_depth"] == "basic"
          assert body["max_results"] == 10

          json_response(conn, %{
            "results" => [
              %{
                "title" => "Tavily",
                "url" => "https://tavily.example",
                "content" => "summary"
              }
            ]
          })
        end
      )

    assert_result(result, "Tavily", "https://tavily.example", "summary")
    assert_receive {:telemetry, %{backend: "tavily", request_headers: headers}}
    assert %{name: "authorization", value: "***REDACTED***"} in headers
    :telemetry.detach(handler_id)
  end

  test "exa backend requests highlights and normalizes highlights as snippet" do
    result =
      execute_search(
        [backend: :exa, exa_api_key: "exa-secret"],
        fn conn ->
          {body, conn} = request_json(conn)
          assert {"x-api-key", "exa-secret"} in conn.req_headers
          assert body["numResults"] == 10
          assert body["contents"] == %{"highlights" => true}

          json_response(conn, %{
            "results" => [
              %{
                "title" => "Exa",
                "url" => "https://exa.example",
                "highlights" => ["first", "second"]
              }
            ]
          })
        end
      )

    assert_result(result, "Exa", "https://exa.example", "first second")
  end

  test "parallel backend sends objective plus search query and normalizes excerpts" do
    result =
      execute_search(
        [backend: :parallel, parallel_api_key: "parallel-secret"],
        fn conn ->
          {body, conn} = request_json(conn)
          assert {"x-api-key", "parallel-secret"} in conn.req_headers
          assert body["search_queries"] == ["fermix"]
          assert body["objective"] =~ "fermix"

          json_response(conn, %{
            "results" => [
              %{
                "title" => "Parallel",
                "url" => "https://parallel.example",
                "excerpts" => ["first", "second"]
              }
            ]
          })
        end
      )

    assert_result(result, "Parallel", "https://parallel.example", "first second")
  end

  test "brave backend sends GET params and redacts subscription token" do
    handler_id = attach_tool_telemetry()

    result =
      execute_search(
        [backend: :brave, brave_api_key: "brave-secret"],
        fn conn ->
          query = URI.decode_query(conn.query_string)
          assert conn.method == "GET"
          assert {"x-subscription-token", "brave-secret"} in conn.req_headers
          assert query["q"] == "fermix"
          assert query["count"] == "10"
          assert query["safesearch"] == "moderate"

          json_response(conn, %{
            "web" => %{
              "results" => [
                %{
                  "title" => "Brave",
                  "url" => "https://brave.example",
                  "description" => "description",
                  "extra_snippets" => ["extra"]
                }
              ]
            }
          })
        end
      )

    assert_result(result, "Brave", "https://brave.example", "description extra")
    assert_receive {:telemetry, %{backend: "brave", request_headers: headers}}
    assert %{name: "x-subscription-token", value: "***REDACTED***"} in headers
    :telemetry.detach(handler_id)
  end

  test "firecrawl backend sends bearer POST and normalizes data.web results" do
    handler_id = attach_tool_telemetry()

    result =
      execute_search(
        [backend: :firecrawl, firecrawl_api_key: "fc-secret"],
        fn conn ->
          {body, conn} = request_json(conn)
          assert {"authorization", "Bearer fc-secret"} in conn.req_headers
          assert body["query"] == "fermix"
          assert body["sources"] == ["web"]
          assert body["limit"] == 10
          refute Map.has_key?(body, "scrapeOptions")

          json_response(conn, %{
            "success" => true,
            "data" => %{
              "web" => [
                %{
                  "title" => "Firecrawl",
                  "url" => "https://firecrawl.example",
                  "description" => "summary"
                }
              ]
            }
          })
        end
      )

    assert_result(result, "Firecrawl", "https://firecrawl.example", "summary")
    assert_receive {:telemetry, %{backend: "firecrawl", request_headers: headers}}
    assert %{name: "authorization", value: "***REDACTED***"} in headers
    :telemetry.detach(handler_id)
  end

  test "perplexity backend uses Search API and normalizes structured results" do
    result =
      execute_search(
        [backend: :perplexity, perplexity_api_key: "pplx-secret"],
        fn conn ->
          {body, conn} = request_json(conn)
          assert {"authorization", "Bearer pplx-secret"} in conn.req_headers
          assert body["query"] == "fermix"
          assert body["max_results"] == 10
          assert body["max_tokens_per_page"] == 512

          json_response(conn, %{
            "results" => [result("Perplexity", "https://perplexity.example", "snippet")]
          })
        end
      )

    assert_result(result, "Perplexity", "https://perplexity.example", "snippet")
  end

  test "selected keyed backend without key fails before making an HTTP request" do
    test_id = :"web_search_missing_key_#{System.unique_integer([:positive])}"
    test_pid = self()

    Application.put_env(:fermix_core, :tools, web_search: [backend: :brave])

    Req.Test.stub(test_id, fn conn ->
      send(test_pid, :unexpected_request)
      json_response(conn, %{})
    end)

    assert {:ok, result} =
             WebSearch.execute(
               %{"query" => "fermix"},
               Map.put(@context, :req_options, plug: {Req.Test, test_id})
             )

    assert result.success == false
    assert result.error =~ "auth_failed"
    refute_received :unexpected_request
  end

  test "provider HTTP failures and schema drift map to stable errors" do
    assert_error([backend: :tavily, tavily_api_key: "tvly-secret"], 401, %{}, "auth_failed")
    assert_error([backend: :tavily, tavily_api_key: "tvly-secret"], 429, %{}, "rate_limited")
    assert_error([backend: :tavily, tavily_api_key: "tvly-secret"], 500, %{}, "provider_error")
    assert_error([backend: :tavily, tavily_api_key: "tvly-secret"], 200, %{}, "parser_changed")

    # Firecrawl: 402 (out of credits) maps to provider_error, which web_search
    # treats as degradable — confirmed in the degrade test below.
    assert_error([backend: :firecrawl, firecrawl_api_key: "fc-secret"], 401, %{}, "auth_failed")
    assert_error([backend: :firecrawl, firecrawl_api_key: "fc-secret"], 429, %{}, "rate_limited")

    assert_error(
      [backend: :firecrawl, firecrawl_api_key: "fc-secret"],
      402,
      %{},
      "provider_error"
    )

    assert_error(
      [backend: :firecrawl, firecrawl_api_key: "fc-secret"],
      200,
      %{},
      "parser_changed"
    )
  end

  test "backend-specific query caps fail before making an HTTP request" do
    assert_no_request(
      [backend: :brave, brave_api_key: "brave-secret"],
      String.duplicate("x", 401),
      "query_too_long"
    )

    assert_no_request(
      [backend: :brave, brave_api_key: "brave-secret"],
      Enum.map_join(1..51, " ", &"w#{&1}"),
      "query_too_long"
    )

    assert_no_request(
      [backend: :parallel, parallel_api_key: "parallel-secret"],
      String.duplicate("x", 201),
      "query_too_long"
    )

    assert_no_request(
      [backend: :firecrawl, firecrawl_api_key: "fc-secret"],
      String.duplicate("x", 501),
      "query_too_long"
    )
  end

  test "keyed backends do not follow redirects (no credential leak or Guard bypass)" do
    test_pid = self()
    test_id = :"web_search_redirect_#{System.unique_integer([:positive])}"

    Application.put_env(:fermix_core, :tools,
      web_search: [backend: :tavily, tavily_api_key: "tvly-secret"]
    )

    Req.Test.stub(test_id, fn conn ->
      # Only a *followed* redirect reaches the leak target. The keyed backend
      # forces redirect: false, so the 302 surfaces as a provider error and
      # web_search degrades to DuckDuckGo (a legitimate second request to a
      # different host) — but a request to evil.example would mean the redirect
      # was followed (the regression this test guards against).
      if conn.host == "evil.example", do: send(test_pid, :redirect_followed)

      conn
      |> Plug.Conn.put_resp_header("location", "https://evil.example/leak")
      |> Plug.Conn.resp(302, "")
    end)

    context =
      Map.merge(@context, %{
        # inject redirect: true — the backend must force it back to false
        req_options: [redirect: true, plug: {Req.Test, test_id}],
        net_resolver: public_resolver()
      })

    assert {:ok, result} = WebSearch.execute(%{"query" => "fermix"}, context)
    assert result.success == false
    assert result.error =~ "provider_error"

    # redirect: false → the 302 is surfaced, never followed to the leak target
    refute_received :redirect_followed
  end

  test "a stale-connection :closed is retried once instead of degrading" do
    # Backends ride the shared FermixCore.Finch pool via Net.HttpClient, which
    # retries a stale-socket :closed once on a fresh connection. An idle-closed
    # keepalive socket must not degrade the search to DuckDuckGo when the
    # backend itself is healthy (the "exa fails after an idle gap" class).
    handler_id = attach_tool_telemetry()
    {:ok, attempts} = Agent.start_link(fn -> 0 end)
    test_id = :"web_search_closed_retry_#{System.unique_integer([:positive])}"

    Application.put_env(:fermix_core, :tools,
      web_search: [backend: :exa, exa_api_key: "exa-secret"]
    )

    Req.Test.stub(test_id, fn conn ->
      case Agent.get_and_update(attempts, &{&1, &1 + 1}) do
        0 ->
          Req.Test.transport_error(conn, :closed)

        _retry ->
          json_response(conn, %{
            "results" => [
              %{"title" => "Exa", "url" => "https://exa.example", "highlights" => ["recovered"]}
            ]
          })
      end
    end)

    context =
      Map.merge(@context, %{
        req_options: [plug: {Req.Test, test_id}],
        net_resolver: public_resolver()
      })

    {result, log} =
      with_log(fn ->
        assert {:ok, result} = WebSearch.execute(%{"query" => "fermix"}, context)
        result
      end)

    assert result.success == true
    assert_result(result, "Exa", "https://exa.example", "recovered")
    assert log =~ "retrying once"

    # Served by exa itself on the retry — no degrade to duckduckgo.
    assert_receive {:telemetry, %{backend: "exa"} = meta}
    refute Map.has_key?(meta, :degraded)
    assert Agent.get(attempts, & &1) == 2
    :telemetry.detach(handler_id)
  end

  test "Support.request/3 rejects :connect_options loudly on every path" do
    # Req only raises on :finch + :connect_options on the real adapter path —
    # a plug-stubbed test would stay green while production crashed. Guard the
    # boundary so a reintroduced :connect_options fails identically everywhere.
    assert_raise ArgumentError, ~r/finch_pools/, fn ->
      Support.request(:post, "https://api.exa.ai/search", connect_options: [timeout: 3_000])
    end
  end

  test "manual unknown backend names use the DuckDuckGo default" do
    result =
      execute_search(
        [backend: :manually_mistyped],
        fn conn ->
          assert conn.request_path == "/html/"
          Plug.Conn.resp(conn, 200, ddg_results_fixture())
        end
      )

    assert_result(result, "Fermix", "https://example.com/fermix", "Elixir agent platform.")
  end

  test "degrades to duckduckgo when the configured backend errors (e.g. out of credits)" do
    handler_id = attach_tool_telemetry()

    result =
      execute_search(
        [backend: :exa, exa_api_key: "exa-secret"],
        fn conn ->
          case conn.host do
            "html.duckduckgo.com" -> Plug.Conn.resp(conn, 200, ddg_results_fixture())
            _exa -> Plug.Conn.resp(conn, 402, "")
          end
        end
      )

    # DuckDuckGo served the results, and the degrade is visible in the trace.
    assert_result(result, "Fermix", "https://example.com/fermix", "Elixir agent platform.")

    assert_receive {:telemetry,
                    %{backend: "duckduckgo", primary_backend: "exa", degraded: true} = meta}

    assert meta.fallback_reason =~ "402"
    :telemetry.detach(handler_id)
  end

  test "does not fall back when the configured backend is already duckduckgo" do
    # A DuckDuckGo failure surfaces as an error — there is nothing keyless to
    # degrade to, so the error is not masked by a second attempt.
    assert_error([backend: :duckduckgo], 500, %{}, "network")
  end

  test "surfaces the configured backend's error when the duckduckgo fallback also fails" do
    test_id = :"web_search_both_fail_#{System.unique_integer([:positive])}"

    Application.put_env(:fermix_core, :tools,
      web_search: [backend: :exa, exa_api_key: "exa-secret"]
    )

    # Both the exa endpoint and the duckduckgo fallback fail.
    Req.Test.stub(test_id, fn conn -> Plug.Conn.resp(conn, 402, "") end)

    context =
      Map.merge(@context, %{
        req_options: [plug: {Req.Test, test_id}],
        net_resolver: public_resolver()
      })

    assert {:ok, result} = WebSearch.execute(%{"query" => "fermix"}, context)
    assert result.success == false
    # The operator's chosen backend (exa) error is surfaced, not duckduckgo's.
    assert result.error =~ "provider_error"
  end

  defp execute_search(tools, handler) do
    test_id = :"web_search_backend_#{System.unique_integer([:positive])}"
    Application.put_env(:fermix_core, :tools, web_search: tools)
    Req.Test.stub(test_id, handler)

    context =
      Map.merge(@context, %{
        req_options: [plug: {Req.Test, test_id}],
        net_resolver: public_resolver()
      })

    assert {:ok, result} = WebSearch.execute(%{"query" => "fermix"}, context)
    assert result.success == true
    result
  end

  defp assert_error(tools, status, body, tag) do
    test_id = :"web_search_error_#{System.unique_integer([:positive])}"
    Application.put_env(:fermix_core, :tools, web_search: tools)

    Req.Test.stub(test_id, fn conn ->
      {:ok, _body, conn} = Plug.Conn.read_body(conn)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end)

    context =
      Map.merge(@context, %{
        req_options: [plug: {Req.Test, test_id}],
        net_resolver: public_resolver()
      })

    assert {:ok, result} = WebSearch.execute(%{"query" => "fermix"}, context)
    assert result.success == false
    assert result.error =~ tag
  end

  defp assert_no_request(tools, query, tag) do
    test_id = :"web_search_no_request_#{System.unique_integer([:positive])}"
    test_pid = self()
    Application.put_env(:fermix_core, :tools, web_search: tools)

    Req.Test.stub(test_id, fn conn ->
      send(test_pid, :unexpected_request)
      json_response(conn, %{})
    end)

    assert {:ok, result} =
             WebSearch.execute(
               %{"query" => query},
               Map.put(@context, :req_options, plug: {Req.Test, test_id})
             )

    assert result.success == false
    assert result.error =~ tag
    refute_received :unexpected_request
  end

  defp result(title, url, snippet), do: %{"title" => title, "url" => url, "snippet" => snippet}

  defp request_json(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    {Jason.decode!(body), conn}
  end

  defp json_response(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(body))
  end

  defp assert_result(result, title, url, snippet) do
    assert [%{"title" => ^title, "url" => ^url, "snippet" => ^snippet}] =
             Jason.decode!(result.output)
  end

  defp public_resolver do
    fn
      "api.tavily.com" -> {:ok, [{93, 184, 216, 34}]}
      "api.exa.ai" -> {:ok, [{93, 184, 216, 34}]}
      "api.parallel.ai" -> {:ok, [{93, 184, 216, 34}]}
      "api.search.brave.com" -> {:ok, [{93, 184, 216, 34}]}
      "api.perplexity.ai" -> {:ok, [{93, 184, 216, 34}]}
      "api.firecrawl.dev" -> {:ok, [{93, 184, 216, 34}]}
      "html.duckduckgo.com" -> {:ok, [{52, 149, 246, 39}]}
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

  defp attach_tool_telemetry do
    handler_id = "test-web-search-backend-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:fermix, :tool, :exec],
      fn _event, _measurements, metadata, _config ->
        if metadata.tool == "web_search" do
          send(test_pid, {:telemetry, metadata})
        end
      end,
      nil
    )

    handler_id
  end

  defp restore_tools(nil), do: Application.delete_env(:fermix_core, :tools)
  defp restore_tools(value), do: Application.put_env(:fermix_core, :tools, value)
end
