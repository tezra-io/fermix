defmodule FermixCore.Capabilities.MCP.Remote.EndpointTest do
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.MCP.Remote.Endpoint

  @host "mcp.acme.example"
  @base "https://" <> @host

  describe "new/2 accepts a signed HTTPS origin" do
    test "builds the endpoint and joins the path" do
      assert {:ok, endpoint} = Endpoint.new(@base, "/mcp")
      assert endpoint.host == @host
      assert endpoint.port == 443
      assert endpoint.path == "/mcp"
      assert Endpoint.uri(endpoint) == @base <> "/mcp"
      assert Endpoint.origin(endpoint) == @base
    end

    test "downcases the host and keeps an explicit port in the origin" do
      assert {:ok, endpoint} = Endpoint.new("https://MCP.Acme.EXAMPLE:8443", "/mcp")
      assert endpoint.host == @host
      assert Endpoint.origin(endpoint) == "https://mcp.acme.example:8443"
    end

    test "allows a multi-segment literal path" do
      assert {:ok, endpoint} = Endpoint.new(@base, "/v1/mcp")
      assert endpoint.path == "/v1/mcp"
    end
  end

  describe "new/2 refuses anything that is not an origin" do
    test "plain http" do
      assert {:error, {:invalid_base_url, :scheme_not_https}} =
               Endpoint.new("http://acme.example", "/mcp")
    end

    test "userinfo" do
      assert {:error, {:invalid_base_url, :userinfo_not_allowed}} =
               Endpoint.new("https://user:pw@acme.example", "/mcp")
    end

    test "a query string" do
      assert {:error, {:invalid_base_url, :query_not_allowed}} =
               Endpoint.new("https://acme.example?a=1", "/mcp")
    end

    test "a fragment" do
      assert {:error, {:invalid_base_url, :fragment_not_allowed}} =
               Endpoint.new("https://acme.example#x", "/mcp")
    end

    test "a path, including a bare trailing slash" do
      assert {:error, {:invalid_base_url, :path_not_allowed}} =
               Endpoint.new("https://acme.example/x", "/mcp")

      assert {:error, {:invalid_base_url, :path_not_allowed}} =
               Endpoint.new("https://acme.example/", "/mcp")
    end

    test "a template or wildcard" do
      assert {:error, {:invalid_base_url, :template}} =
               Endpoint.new("https://{env}.acme.example", "/mcp")

      assert {:error, {:invalid_base_url, :template}} =
               Endpoint.new("https://*.acme.example", "/mcp")
    end

    # An IP literal leaves no name to verify the certificate against, so the
    # revalidate-DNS-on-reconnect contract becomes unenforceable.
    test "an IP literal" do
      assert {:error, {:invalid_base_url, :ip_literal_not_allowed}} =
               Endpoint.new("https://93.184.216.34", "/mcp")

      assert {:error, {:invalid_base_url, :ip_literal_not_allowed}} =
               Endpoint.new("https://[2606:2800:220:1:248:1893:25c8:1946]", "/mcp")
    end

    test "whitespace or control characters" do
      assert {:error, {:invalid_base_url, :whitespace_or_control}} =
               Endpoint.new("https://acme.example\n", "/mcp")
    end

    test "an empty host" do
      assert {:error, {:invalid_base_url, :empty_host}} = Endpoint.new("https://", "/mcp")
    end
  end

  describe "new/2 refuses a non-literal mcp_path" do
    test "a relative path" do
      assert {:error, {:invalid_mcp_path, :not_absolute}} = Endpoint.new(@base, "mcp")
    end

    test "a query or fragment" do
      assert {:error, {:invalid_mcp_path, :query_not_allowed}} = Endpoint.new(@base, "/mcp?a=1")
      assert {:error, {:invalid_mcp_path, :fragment_not_allowed}} = Endpoint.new(@base, "/mcp#x")
    end

    test "a backslash" do
      assert {:error, {:invalid_mcp_path, :backslash}} = Endpoint.new(@base, "/mcp\\x")
    end

    test "a dot segment" do
      assert {:error, {:invalid_mcp_path, :dot_segment}} = Endpoint.new(@base, "/../mcp")
      assert {:error, {:invalid_mcp_path, :dot_segment}} = Endpoint.new(@base, "/a/./mcp")
    end

    # A percent-encoded slash re-introduces path structure the validator never
    # reviewed, once the server decodes it.
    test "a percent-encoded slash in either case" do
      assert {:error, {:invalid_mcp_path, :encoded_slash}} = Endpoint.new(@base, "/mcp%2fadmin")
      assert {:error, {:invalid_mcp_path, :encoded_slash}} = Endpoint.new(@base, "/mcp%2Fadmin")
    end

    test "a template" do
      assert {:error, {:invalid_mcp_path, :template}} = Endpoint.new(@base, "/{tenant}/mcp")
    end
  end

  describe "operator/1 accepts the URL the owner typed (M74 E4)" do
    test "an HTTPS URL with a path and a query, the query riding the request target" do
      assert {:ok, endpoint} = Endpoint.operator("https://MCP.Linear.app/v1/mcp?team=core")
      assert endpoint.scheme == :https
      assert endpoint.source == :operator
      assert endpoint.host == "mcp.linear.app"
      assert endpoint.port == 443
      assert endpoint.path == "/v1/mcp?team=core"
      assert Endpoint.uri(endpoint) == "https://mcp.linear.app/v1/mcp?team=core"
    end

    test "an absent path is the root" do
      assert {:ok, %{path: "/"}} = Endpoint.operator("https://mcp.example.com")
    end

    test "an IP literal, on a private network or this machine, with its port" do
      assert {:ok, endpoint} = Endpoint.operator("https://10.0.0.5:8443/mcp")
      assert {endpoint.host, endpoint.port} == {"10.0.0.5", 8443}

      assert {:ok, endpoint} = Endpoint.operator("https://[fd12::1]/mcp")
      assert endpoint.host == "fd12::1"
      assert Endpoint.origin(endpoint) == "https://[fd12::1]"
    end

    test "plain http to this machine, by name or literal" do
      for url <- [
            "http://localhost:3000/mcp",
            "http://127.0.0.1:3000/mcp",
            "http://[::1]:3000/mcp"
          ] do
        assert {:ok, %{scheme: :http} = endpoint} = Endpoint.operator(url), url
        assert endpoint.port == 3000
      end

      assert {:ok, endpoint} = Endpoint.operator("http://localhost/mcp")
      assert endpoint.port == 80
      assert Endpoint.origin(endpoint) == "http://localhost"
    end
  end

  describe "operator/1 refuses" do
    test "plain http anywhere but this machine" do
      for url <- [
            "http://mcp.example.com/mcp",
            "http://10.0.0.5/mcp",
            "http://localhost.example/mcp"
          ] do
        assert {:error, {:invalid_url, :http_only_to_loopback}} = Endpoint.operator(url), url
      end
    end

    test "userinfo, a key in it or a host pretending to be one" do
      assert {:error, {:invalid_url, :userinfo_not_allowed}} =
               Endpoint.operator("https://user:key@mcp.example.com/mcp")

      assert {:error, {:invalid_url, :userinfo_not_allowed}} =
               Endpoint.operator("https://mcp.linear.app@evil.example/mcp")
    end

    test "a fragment, even an empty one" do
      assert {:error, {:invalid_url, :fragment_not_allowed}} =
               Endpoint.operator("https://mcp.example.com/mcp#tools")

      assert {:error, {:invalid_url, :fragment_not_allowed}} =
               Endpoint.operator("https://mcp.example.com/mcp#")
    end

    test "a template or wildcard anywhere in it" do
      for url <- [
            "https://{tenant}.example.com/mcp",
            "https://*.example.com/mcp",
            "https://mcp.example.com/{tenant}/mcp",
            "https://mcp.example.com/mcp?team={team}"
          ] do
        assert {:error, {:invalid_url, :template}} = Endpoint.operator(url), url
      end
    end

    test "another scheme, no host, whitespace, or not text" do
      assert {:error, {:invalid_url, :scheme_not_http_or_https}} =
               Endpoint.operator("ws://mcp.example.com/mcp")

      assert {:error, {:invalid_url, :scheme_not_http_or_https}} =
               Endpoint.operator("mcp.example.com")

      assert {:error, {:invalid_url, :empty_host}} = Endpoint.operator("https:///mcp")

      assert {:error, {:invalid_url, :whitespace_or_control}} =
               Endpoint.operator("https://a.example/ mcp")

      assert {:error, {:invalid_url, :empty}} = Endpoint.operator("")
      assert {:error, {:invalid_url, :not_text}} = Endpoint.operator(nil)
    end

    test "a path the manifest rules refuse" do
      assert {:error, {:invalid_url, :dot_segment}} =
               Endpoint.operator("https://mcp.example.com/a/../mcp")

      assert {:error, {:invalid_url, :encoded_slash}} =
               Endpoint.operator("https://mcp.example.com/mcp%2Fadmin")
    end
  end

  describe "resolve/2 for an operator endpoint" do
    test "an IP literal is its own peer, a private one included" do
      resolver = fn host -> flunk("#{host} must not be looked up") end

      {:ok, endpoint} = Endpoint.operator("https://10.0.0.5/mcp")
      assert {:ok, [{10, 0, 0, 5}]} = Endpoint.resolve(endpoint, resolver: resolver)

      {:ok, endpoint} = Endpoint.operator("http://[::1]:3000/mcp")
      assert {:ok, [{0, 0, 0, 0, 0, 0, 0, 1}]} = Endpoint.resolve(endpoint, resolver: resolver)
    end

    test "a name's every answer is a peer, in the resolver's order" do
      {:ok, endpoint} = Endpoint.operator("https://nas.local/mcp")
      resolver = fn "nas.local" -> {:ok, [{192, 168, 1, 20}]} end
      assert {:ok, [{192, 168, 1, 20}]} = Endpoint.resolve(endpoint, resolver: resolver)

      {:ok, endpoint} = Endpoint.operator("http://localhost:3000/mcp")
      resolver = fn "localhost" -> {:ok, [{0, 0, 0, 0, 0, 0, 0, 1}, {127, 0, 0, 1}]} end

      assert {:ok, [{0, 0, 0, 0, 0, 0, 0, 1}, {127, 0, 0, 1}]} =
               Endpoint.resolve(endpoint, resolver: resolver)
    end

    test "a metadata or link-local address is a security block, literal or answered" do
      {:ok, endpoint} = Endpoint.operator("https://169.254.169.254/latest")

      assert {:error, {:remote_security_blocked, {:blocked_host, :link_local_address}}} =
               Endpoint.resolve(endpoint)

      {:ok, endpoint} = Endpoint.operator("https://metadata.example/mcp")
      resolver = fn "metadata.example" -> {:ok, [{10, 0, 0, 5}, {169, 254, 169, 254}]} end

      assert {:error,
              {:remote_security_blocked, {:resolved_to_link_local_address, {169, 254, 169, 254}}}} =
               Endpoint.resolve(endpoint, resolver: resolver)
    end

    # The manifest source keeps its public-only rule: an owner's URL widens
    # nothing for a plugin.
    test "a manifest endpoint still refuses the owner's own network" do
      {:ok, endpoint} = Endpoint.new(@base, "/mcp")
      resolver = fn _host -> {:ok, [{192, 168, 1, 20}]} end

      assert {:error, {:remote_security_blocked, {:resolved_to_private_address, _ip}}} =
               Endpoint.resolve(endpoint, resolver: resolver)
    end
  end

  describe "resolve/2" do
    test "returns the validated peer for a public answer" do
      {:ok, endpoint} = Endpoint.new(@base, "/mcp")
      resolver = fn _host -> {:ok, [{93, 184, 216, 34}]} end

      assert {:ok, [{93, 184, 216, 34}]} = Endpoint.resolve(endpoint, resolver: resolver)
    end

    # The gate has to run in the world the connection runs in: if resolution
    # refuses, no connection may be attempted at all.
    test "refuses a host that resolves to a non-global address" do
      {:ok, endpoint} = Endpoint.new(@base, "/mcp")
      resolver = fn _host -> {:ok, [{127, 0, 0, 1}]} end

      assert {:error, {:remote_security_blocked, _reason}} =
               Endpoint.resolve(endpoint, resolver: resolver)
    end

    test "refuses a mixed public/non-global answer set" do
      {:ok, endpoint} = Endpoint.new(@base, "/mcp")
      resolver = fn _host -> {:ok, [{93, 184, 216, 34}, {10, 0, 0, 5}]} end

      assert {:error, {:remote_security_blocked, _reason}} =
               Endpoint.resolve(endpoint, resolver: resolver)
    end

    test "reports a resolution failure as a security block, not a soft miss" do
      {:ok, endpoint} = Endpoint.new(@base, "/mcp")
      resolver = fn _host -> {:ok, []} end

      assert {:error, {:remote_security_blocked, _reason}} =
               Endpoint.resolve(endpoint, resolver: resolver)
    end
  end
end
