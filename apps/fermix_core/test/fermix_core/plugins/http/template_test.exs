defmodule FermixCore.Plugins.Http.TemplateTest do
  use ExUnit.Case, async: true

  alias FermixCore.Plugins.Http.Template

  describe "build/3 url + method" do
    test "interpolates path placeholders and keeps the static host" do
      t = %{"method" => "GET", "url" => "https://api.github.com/repos/{owner}/{repo}/issues"}
      assert {:ok, req} = Template.build(t, %{"owner" => "tezra-io", "repo" => "fermix"}, nil)
      assert req.method == :get
      assert req.url == "https://api.github.com/repos/tezra-io/fermix/issues"
    end

    test "url-encodes interpolated path segments" do
      t = %{"url" => "https://api.example.com/items/{id}"}
      assert {:ok, req} = Template.build(t, %{"id" => "a b/c"}, nil)
      assert req.url == "https://api.example.com/items/a+b%2Fc"
    end

    test "rejects a non-https url" do
      assert {:error, {:non_https_url, _}} =
               Template.build(%{"url" => "http://api.example.com/x"}, %{}, nil)
    end

    test "SSRF guard: a placeholder cannot change the host" do
      t = %{"url" => "https://{host}.example.com/x"}

      assert {:error, {:url_origin_changed, _, _}} =
               Template.build(t, %{"host" => "evil"}, nil)
    end

    test "rejects an unknown method" do
      assert {:error, {:invalid_method, "TRACE"}} =
               Template.build(%{"method" => "TRACE", "url" => "https://x/y"}, %{}, nil)
    end

    test "errors when a path placeholder has no value" do
      assert {:error, :url_missing_param} =
               Template.build(%{"url" => "https://x/{missing}"}, %{}, nil)
    end
  end

  describe "build/3 query" do
    test "interpolates query values and omits absent optionals" do
      t = %{"url" => "https://x/y", "query" => %{"state" => "{state}", "page" => "{page}"}}
      assert {:ok, req} = Template.build(t, %{"state" => "open"}, nil)
      assert req.query == [{"state", "open"}]
    end

    test "keeps literal query values" do
      t = %{"url" => "https://x/y", "query" => %{"singleEvents" => "true"}}
      assert {:ok, req} = Template.build(t, %{}, nil)
      assert req.query == [{"singleEvents", "true"}]
    end
  end

  describe "build/3 headers + auth" do
    test "keeps static headers and injects the auth header" do
      t = %{"url" => "https://x/y", "headers" => %{"Accept" => "application/json"}}
      assert {:ok, req} = Template.build(t, %{}, {"Authorization", "Bearer tok"})
      assert {"Authorization", "Bearer tok"} in req.headers
      assert {"Accept", "application/json"} in req.headers
    end

    test "rejects a placeholder in a header value (injection surface)" do
      t = %{"url" => "https://x/y", "headers" => %{"X-Tenant" => "{tenant}"}}

      assert {:error, {:placeholder_in_header, "X-Tenant"}} =
               Template.build(t, %{"tenant" => "a"}, nil)
    end
  end

  describe "build/3 body" do
    test "interpolates body leaves and preserves JSON types (array stays array)" do
      t = %{
        "method" => "POST",
        "url" => "https://x/y",
        "body" => %{"title" => "{title}", "labels" => "{labels}"}
      }

      assert {:ok, req} = Template.build(t, %{"title" => "Bug", "labels" => ["p1", "ux"]}, nil)
      assert req.body == %{"title" => "Bug", "labels" => ["p1", "ux"]}
    end

    test "omits absent optional body leaves" do
      t = %{
        "method" => "POST",
        "url" => "https://x/y",
        "body" => %{"name" => "{name}", "note" => "{note}"}
      }

      assert {:ok, req} = Template.build(t, %{"name" => "x"}, nil)
      assert req.body == %{"name" => "x"}
    end

    test "nil body stays nil" do
      assert {:ok, %{body: nil}} = Template.build(%{"url" => "https://x/y"}, %{}, nil)
    end

    test "interpolates into a nested object and omits an absent nested leaf" do
      t = %{
        "method" => "POST",
        "url" => "https://x/y",
        "body" => %{"start" => %{"dateTime" => "{start}", "timeZone" => "{tz}"}}
      }

      assert {:ok, %{body: %{"start" => %{"dateTime" => "2026-01-01T10:00:00Z"}}}} =
               Template.build(t, %{"start" => "2026-01-01T10:00:00Z"}, nil)

      assert {:ok, %{body: with_tz}} =
               Template.build(t, %{"start" => "2026-01-01T10:00:00Z", "tz" => "UTC"}, nil)

      assert with_tz["start"] == %{"dateTime" => "2026-01-01T10:00:00Z", "timeZone" => "UTC"}
    end

    test "interpolates into a list element and omits the key when the list empties" do
      t = %{"method" => "POST", "url" => "https://x/y", "body" => %{"parents" => ["{parent_id}"]}}

      assert {:ok, %{body: %{"parents" => ["folder-1"]}}} =
               Template.build(t, %{"parent_id" => "folder-1"}, nil)

      assert {:ok, %{body: body}} = Template.build(t, %{}, nil)
      refute Map.has_key?(body, "parents")
    end
  end

  describe "static_validate/2 (install-time)" do
    test "accepts a template whose placeholders are all declared" do
      t = %{
        "url" => "https://api.example.com/repos/{owner}/x",
        "query" => %{"state" => "{state}"}
      }

      assert :ok = Template.static_validate(t, ["owner", "state"])
    end

    test "rejects a non-https url" do
      assert {:error, {:non_https_url, _}} =
               Template.static_validate(%{"url" => "http://x/y"}, [])
    end

    test "rejects a placeholder in the host (SSRF)" do
      assert {:error, {:placeholder_in_host, _}} =
               Template.static_validate(%{"url" => "https://{host}.example.com/x"}, ["host"])
    end

    test "rejects userinfo in the url (host-confusion SSRF)" do
      # URI.parse reads the real host as evil.com; a naive string split reads
      # good.com. The check must see what the runtime request will hit.
      assert {:error, {:userinfo_in_url, _}} =
               Template.static_validate(%{"url" => "https://good.com@evil.com/path"}, [])
    end

    test "rejects a placeholder in the port (URI.parse drops it silently)" do
      assert {:error, {:placeholder_in_host, _}} =
               Template.static_validate(%{"url" => "https://api.example.com:{port}/x"}, ["port"])
    end

    test "rejects an empty host" do
      assert {:error, {:invalid_url_host, _}} =
               Template.static_validate(%{"url" => "https:///path"}, [])
    end

    test "rejects a placeholder in a header" do
      t = %{"url" => "https://x/y", "headers" => %{"X-Tenant" => "{tenant}"}}

      assert {:error, {:placeholder_in_header, "X-Tenant"}} =
               Template.static_validate(t, ["tenant"])
    end

    test "rejects an undeclared placeholder anywhere in the template" do
      t = %{"url" => "https://x/y", "body" => %{"k" => "{undeclared}"}}

      assert {:error, {:undeclared_placeholder, "undeclared"}} =
               Template.static_validate(t, ["k"])
    end
  end
end
