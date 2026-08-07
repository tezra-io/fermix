defmodule FermixCore.Capabilities.MCP.Remote.EndpointTest do
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.MCP.Remote.Endpoint

  @host "mcp.eden.so"
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
      assert {:ok, endpoint} = Endpoint.new("https://MCP.Eden.SO:8443", "/mcp")
      assert endpoint.host == @host
      assert Endpoint.origin(endpoint) == "https://mcp.eden.so:8443"
    end

    test "allows a multi-segment literal path" do
      assert {:ok, endpoint} = Endpoint.new(@base, "/v1/mcp")
      assert endpoint.path == "/v1/mcp"
    end
  end

  describe "new/2 refuses anything that is not an origin" do
    test "plain http" do
      assert {:error, {:invalid_base_url, :scheme_not_https}} =
               Endpoint.new("http://eden.so", "/mcp")
    end

    test "userinfo" do
      assert {:error, {:invalid_base_url, :userinfo_not_allowed}} =
               Endpoint.new("https://user:pw@eden.so", "/mcp")
    end

    test "a query string" do
      assert {:error, {:invalid_base_url, :query_not_allowed}} =
               Endpoint.new("https://eden.so?a=1", "/mcp")
    end

    test "a fragment" do
      assert {:error, {:invalid_base_url, :fragment_not_allowed}} =
               Endpoint.new("https://eden.so#x", "/mcp")
    end

    test "a path, including a bare trailing slash" do
      assert {:error, {:invalid_base_url, :path_not_allowed}} =
               Endpoint.new("https://eden.so/x", "/mcp")

      assert {:error, {:invalid_base_url, :path_not_allowed}} =
               Endpoint.new("https://eden.so/", "/mcp")
    end

    test "a template or wildcard" do
      assert {:error, {:invalid_base_url, :template}} =
               Endpoint.new("https://{env}.eden.so", "/mcp")

      assert {:error, {:invalid_base_url, :template}} = Endpoint.new("https://*.eden.so", "/mcp")
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
               Endpoint.new("https://eden.so\n", "/mcp")
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

  describe "resolve/2" do
    test "returns the validated peer for a public answer" do
      {:ok, endpoint} = Endpoint.new(@base, "/mcp")
      resolver = fn _host -> {:ok, [{93, 184, 216, 34}]} end

      assert {:ok, {93, 184, 216, 34}} = Endpoint.resolve(endpoint, resolver: resolver)
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
