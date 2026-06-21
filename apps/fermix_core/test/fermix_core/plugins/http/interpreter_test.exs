defmodule FermixCore.Plugins.Http.InterpreterTest do
  use ExUnit.Case, async: true

  alias FermixCore.Plugins.Http.Interpreter

  defp json(status, body, headers \\ [{"content-type", "application/json"}]) do
    fn _req -> {:ok, %{status: status, headers: headers, body: Jason.encode!(body)}} end
  end

  defp tool(request, parameters \\ %{"type" => "object", "properties" => %{}}) do
    %{"parameters" => parameters, "request" => request}
  end

  describe "single request" do
    test "returns the extracted, redacted body on success" do
      t =
        tool(%{
          "method" => "GET",
          "url" => "https://api.example.com/items",
          "extract" => %{"fields" => ["id", "title"]}
        })

      http = json(200, [%{"id" => 1, "title" => "a", "secret" => "x"}])
      assert {:ok, %{success: true, output: out}} = Interpreter.run(t, %{}, http: http)
      assert Jason.decode!(out) == [%{"id" => 1, "title" => "a"}]
    end

    test "captures URL/query interpolation in the request seam" do
      t =
        tool(
          %{
            "method" => "GET",
            "url" => "https://api.example.com/repos/{owner}/x",
            "query" => %{"state" => "{state}"}
          },
          %{
            "type" => "object",
            "properties" => %{"owner" => %{"type" => "string"}, "state" => %{"type" => "string"}},
            "required" => ["owner"]
          }
        )

      capture = fn req ->
        send(self(), {:req, req})
        {:ok, %{status: 200, headers: [{"content-type", "application/json"}], body: "{}"}}
      end

      assert {:ok, %{success: true}} =
               Interpreter.run(t, %{"owner" => "tezra", "state" => "open"}, http: capture)

      assert_received {:req, req}
      assert req.url == "https://api.example.com/repos/tezra/x"
      assert {"state", "open"} in req.query
    end

    test "a 204 no-content write is an explicit empty success" do
      t =
        tool(%{
          "method" => "DELETE",
          "url" => "https://api.example.com/x",
          "success" => [200, 204]
        })

      http = fn _ -> {:ok, %{status: 204, headers: [], body: ""}} end
      assert {:ok, %{success: true}} = Interpreter.run(t, %{}, http: http)
    end
  end

  describe "param + build errors (no request sent)" do
    test "a missing required param is a tool error" do
      t =
        tool(
          %{"method" => "GET", "url" => "https://x/y"},
          %{
            "type" => "object",
            "properties" => %{"q" => %{"type" => "string"}},
            "required" => ["q"]
          }
        )

      http = fn _ -> flunk("must not be called") end
      assert {:ok, %{success: false, error: err}} = Interpreter.run(t, %{}, http: http)
      assert err =~ "missing required parameter: q"
    end

    test "an SSRF host placeholder is refused before any request" do
      t =
        tool(
          %{"method" => "GET", "url" => "https://{host}.example.com/x"},
          %{"type" => "object", "properties" => %{"host" => %{"type" => "string"}}}
        )

      http = fn _ -> flunk("must not be called") end
      assert {:ok, %{success: false}} = Interpreter.run(t, %{"host" => "evil"}, http: http)
    end

    test "the default transport refuses private-address URLs" do
      # No :http opt — the built-in transport runs, and its Net.Guard floor
      # must block private hosts. An IP literal keeps this off DNS (hermetic).
      t = tool(%{"method" => "GET", "url" => "https://10.0.0.8/x"})

      assert {:ok, %{success: false, error: err}} = Interpreter.run(t, %{})
      assert err =~ "blocked_url"
    end
  end

  describe "response guards" do
    test "a non-JSON 2xx is a tool error, never dumped to the model" do
      t = tool(%{"method" => "GET", "url" => "https://x/y"})

      http = fn _ ->
        {:ok,
         %{status: 200, headers: [{"content-type", "text/html"}], body: "<html>error</html>"}}
      end

      assert {:ok, %{success: false, error: err}} = Interpreter.run(t, %{}, http: http)
      assert err =~ "non-JSON"
    end

    test "a response over the size cap is a tool error" do
      t = tool(%{"method" => "GET", "url" => "https://x/y"})
      big = String.duplicate("a", 200)

      http = fn _ ->
        {:ok,
         %{status: 200, headers: [{"content-type", "application/json"}], body: Jason.encode!(big)}}
      end

      assert {:ok, %{success: false, error: err}} =
               Interpreter.run(t, %{}, http: http, max_response_bytes: 50)

      assert err =~ "size cap"
    end
  end

  describe "error classification" do
    test "401 branches on auth type" do
      t = tool(%{"method" => "GET", "url" => "https://x/y"})
      resp = fn _ -> {:ok, %{status: 401, headers: [], body: "{}"}} end

      assert {:ok, %{error: e1}} = Interpreter.run(t, %{}, http: resp, auth_type: :oauth2)
      assert e1 =~ "reauthorize"

      assert {:ok, %{error: e2}} =
               Interpreter.run(t, %{}, http: resp, auth_type: :api_key, plugin: "github")

      assert e2 =~ "fermix plugins auth set github"
    end

    test "403 names the required scopes" do
      t = tool(%{"method" => "GET", "url" => "https://x/y"})
      resp = fn _ -> {:ok, %{status: 403, headers: [], body: ~s({"message":"forbidden"})}} end

      assert {:ok, %{error: err}} =
               Interpreter.run(t, %{}, http: resp, requires_scopes: ["repo", "read:org"])

      assert err =~ "repo, read:org"
    end

    test "429 surfaces Retry-After" do
      t = tool(%{"method" => "GET", "url" => "https://x/y"})
      resp = fn _ -> {:ok, %{status: 429, headers: [{"retry-after", "30"}], body: "{}"}} end
      assert {:ok, %{error: err}} = Interpreter.run(t, %{}, http: resp)
      assert err =~ "rate-limited" and err =~ "30"
    end

    test "5xx is a provider error" do
      t = tool(%{"method" => "GET", "url" => "https://x/y"})
      resp = fn _ -> {:ok, %{status: 503, headers: [], body: "{}"}} end
      assert {:ok, %{error: err}} = Interpreter.run(t, %{}, http: resp)
      assert err =~ "provider error (503)"
    end

    test "a huge error body is truncated, not copied wholesale into the model" do
      t = tool(%{"method" => "GET", "url" => "https://x/y"})
      huge = String.duplicate("E", 100_000)
      resp = fn _ -> {:ok, %{status: 500, headers: [], body: huge}} end
      assert {:ok, %{error: err}} = Interpreter.run(t, %{}, http: resp)
      assert err =~ "truncated"
      assert byte_size(err) < 5_000
    end
  end

  describe "pagination (body cursor)" do
    test "accumulates items across pages until the cursor runs out" do
      t =
        tool(%{
          "method" => "POST",
          "url" => "https://api.notion.com/v1/search",
          "paginate" => %{
            "cursor_path" => "next_cursor",
            "cursor_param" => "start_cursor",
            "cursor_in" => "body",
            "items_path" => "results",
            "max_pages" => 10
          }
        })

      http = fn req ->
        body =
          case (req.body || %{})["start_cursor"] do
            nil -> %{"results" => [%{"id" => "a"}], "next_cursor" => "c2"}
            "c2" -> %{"results" => [%{"id" => "b"}], "next_cursor" => nil}
          end

        {:ok,
         %{
           status: 200,
           headers: [{"content-type", "application/json"}],
           body: Jason.encode!(body)
         }}
      end

      assert {:ok, %{success: true, output: out}} = Interpreter.run(t, %{}, http: http)
      decoded = Jason.decode!(out)
      assert decoded["items"] == [%{"id" => "a"}, %{"id" => "b"}]
      assert decoded["truncated"] == false
    end

    test "stops at the page cap and marks the result truncated" do
      t =
        tool(%{
          "method" => "GET",
          "url" => "https://api.example.com/items",
          "paginate" => %{
            "cursor_path" => "next",
            "cursor_param" => "cursor",
            "cursor_in" => "query",
            "items_path" => "results",
            "max_pages" => 2
          }
        })

      # always returns a cursor → would loop forever without the cap
      http = fn _ ->
        body = %{"results" => [%{"id" => 1}], "next" => "always"}

        {:ok,
         %{
           status: 200,
           headers: [{"content-type", "application/json"}],
           body: Jason.encode!(body)
         }}
      end

      assert {:ok, %{success: true, output: out}} = Interpreter.run(t, %{}, http: http)
      decoded = Jason.decode!(out)
      assert length(decoded["items"]) == 2
      assert decoded["truncated"] == true
    end
  end

  describe "pagination (id_window)" do
    test "derives the next cursor from the last item's id and stops on an empty page" do
      t =
        tool(%{
          "method" => "GET",
          "url" => "https://discord.com/api/v10/channels/123/messages",
          "paginate" => %{
            "mode" => "id_window",
            "cursor_param" => "before",
            "cursor_in" => "query",
            "id_field" => "id",
            "max_pages" => 5
          }
        })

      http = fn req ->
        before = req.query |> Enum.into(%{}) |> Map.get("before")

        body =
          case before do
            nil -> [%{"id" => "30"}, %{"id" => "20"}]
            "20" -> [%{"id" => "10"}]
            "10" -> []
          end

        {:ok,
         %{
           status: 200,
           headers: [{"content-type", "application/json"}],
           body: Jason.encode!(body)
         }}
      end

      assert {:ok, %{success: true, output: out}} = Interpreter.run(t, %{}, http: http)
      decoded = Jason.decode!(out)
      assert Enum.map(decoded["items"], & &1["id"]) == ["30", "20", "10"]
      assert decoded["truncated"] == false
    end

    test "id_window paging is bounded by max_pages" do
      t =
        tool(%{
          "method" => "GET",
          "url" => "https://discord.com/api/v10/channels/123/messages",
          "paginate" => %{
            "mode" => "id_window",
            "cursor_param" => "before",
            "cursor_in" => "query",
            "max_pages" => 2
          }
        })

      # always returns a fresh-looking id → would loop forever without the cap
      http = fn _ ->
        {:ok,
         %{
           status: 200,
           headers: [{"content-type", "application/json"}],
           body: Jason.encode!([%{"id" => "1"}])
         }}
      end

      assert {:ok, %{success: true, output: out}} = Interpreter.run(t, %{}, http: http)
      decoded = Jason.decode!(out)
      assert decoded["truncated"] == true
    end
  end
end
