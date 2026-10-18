defmodule FermixCore.Capabilities.MCP.OAuth.DiscoveryTest do
  @moduledoc """
  How an MCP server says it is signed in to (M74 E5): the `WWW-Authenticate`
  challenge, the well-known URIs in the MCP authorization specification's
  order, the checks a document must pass, and Fermix's Client ID Metadata
  Document, against loopback servers that record what they were asked.
  """

  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.MCP.OAuth.Challenge
  alias FermixCore.Capabilities.MCP.OAuth.Discovery
  alias FermixCore.Capabilities.MCP.OAuth.Http
  alias FermixCore.Capabilities.MCP.OAuth.Registration
  alias FermixTestSupport.LoopbackHttp

  @document Application.app_dir(:fermix_core, "priv/oauth/mcp-client.json")

  describe "the challenge" do
    test "reads resource_metadata, scope and error from the Bearer challenge" do
      header =
        ~s(Bearer resource_metadata="https://x.dev/.well-known/oauth-protected-resource", scope="a b")

      assert Challenge.parse(header) == %{
               resource_metadata: "https://x.dev/.well-known/oauth-protected-resource",
               scope: "a b",
               error: nil
             }
    end

    test "finds the Bearer challenge among others, with tokens, escapes and odd spacing" do
      header =
        ~s(Basic realm="a, b", Bearer realm=example,error="insufficient_scope" ,  scope="x \\"y\\"")

      assert Challenge.parse(header) == %{
               resource_metadata: nil,
               scope: ~s(x "y"),
               error: "insufficient_scope"
             }

      assert Challenge.parse("Bearer") == %{resource_metadata: nil, scope: nil, error: nil}

      assert Challenge.parse(~s(DPoP algs="ES256", Bearer scope=read)) ==
               %{resource_metadata: nil, scope: "read", error: nil}
    end

    test "has none where there is no Bearer challenge or the header does not parse" do
      for header <- [nil, "", ~s(Basic realm="x"), ~s(Bearer scope="unterminated), "Bearer =x"] do
        assert Challenge.parse(header) == nil, inspect(header)
      end

      assert Challenge.bearer([{"WWW-Authenticate", "Bearer scope=read"}]) ==
               %{resource_metadata: nil, scope: "read", error: nil}
    end
  end

  describe "the protected resource metadata" do
    test "is read from the well-known URIs in order, path inserted first, when the challenge names none" do
      server = start_server(fn _request -> {404, [], ""} end)

      assert {:error, {:sign_in_discovery, :no_metadata}} =
               Discovery.protected_resource(base(server) <> "/v1/mcp", nil, deadline())

      assert paths(server) == [
               "/.well-known/oauth-protected-resource/v1/mcp",
               "/.well-known/oauth-protected-resource"
             ]
    end

    test "is read from resource_metadata alone when the challenge names it" do
      server = start_server(fn _request -> {404, [], ""} end)
      challenge = %{resource_metadata: base(server) <> "/meta", scope: nil, error: nil}

      assert {:error, {:sign_in_discovery, :no_metadata}} =
               Discovery.protected_resource(base(server) <> "/mcp", challenge, deadline())

      assert paths(server) == ["/meta"]
    end

    test "must name the server it was read for" do
      server = start_server(fn _request -> prm("https://elsewhere.dev/mcp", "https://a.dev") end)

      assert {:error, {:sign_in_discovery, :resource_mismatch}} =
               Discovery.protected_resource(base(server) <> "/mcp", nil, deadline())
    end

    test "takes the challenge's scope over scopes_supported" do
      # The resource is the server's origin, which covers its path.
      server =
        start_server(fn request ->
          prm("http://#{host(request)}", "https://a.dev", ["r", "w"])
        end)

      url = base(server) <> "/mcp"

      assert {:ok,
              %{resource: resource, authorization_servers: ["https://a.dev"], scopes: ["r", "w"]}} =
               Discovery.protected_resource(url, nil, deadline())

      assert resource == base(server)

      challenge = %{resource_metadata: nil, scope: "admin", error: nil}

      assert {:ok, %{scopes: ["admin"]}} =
               Discovery.protected_resource(url, challenge, deadline())
    end
  end

  describe "the authorization server metadata" do
    test "is read for an issuer with a path in the specification's order" do
      issuer_server = start_server(fn _request -> {404, [], ""} end)
      issuer = base(issuer_server) <> "/tenant1"
      mcp = start_server(&protected(&1, issuer))

      assert {:error, {:sign_in_discovery, :no_metadata}} =
               Discovery.discover(base(mcp) <> "/mcp", deadline())

      assert paths(issuer_server) == [
               "/.well-known/oauth-authorization-server/tenant1",
               "/.well-known/openid-configuration/tenant1",
               "/tenant1/.well-known/openid-configuration"
             ]
    end

    test "falls back to OpenID Connect discovery for an issuer without a path" do
      issuer_server = start_server(&oidc_only(&1, ""))
      issuer = base(issuer_server)
      mcp = start_server(&protected(&1, issuer))
      url = base(mcp) <> "/mcp"

      assert {:ok, metadata} = Discovery.discover(url, deadline())
      assert {metadata.issuer, metadata.resource} == {issuer, url}
      assert metadata.token_endpoint == issuer <> "/token"
      assert metadata.token_auth_methods == ["client_secret_basic"]
      refute metadata.client_id_metadata_document?
      refute metadata.iss_required?

      assert paths(issuer_server) == [
               "/.well-known/oauth-authorization-server",
               "/.well-known/openid-configuration"
             ]
    end

    test "is refused when it names its issuer any other way" do
      issuer_server = start_server(&oidc_only(&1, "/"))
      mcp = start_server(&protected(&1, base(issuer_server)))

      assert {:error, {:sign_in_discovery, :issuer_mismatch}} =
               Discovery.discover(base(mcp) <> "/mcp", deadline())
    end

    test "is refused when it does not offer PKCE with S256" do
      issuer_server =
        start_server(fn request ->
          metadata = as_metadata("http://#{host(request)}")
          json(%{metadata | "code_challenge_methods_supported" => ["plain"]})
        end)

      mcp = start_server(&protected(&1, base(issuer_server)))

      assert {:error, {:sign_in_discovery, :pkce_unsupported}} =
               Discovery.discover(base(mcp) <> "/mcp", deadline())
    end

    test "is refused when an endpoint is outside the rail's rule" do
      issuer_server =
        start_server(fn request ->
          metadata = as_metadata("http://#{host(request)}")
          json(%{metadata | "token_endpoint" => "http://example.com/token"})
        end)

      mcp = start_server(&protected(&1, base(issuer_server)))

      assert {:error, {:sign_in_discovery, :invalid_metadata}} =
               Discovery.discover(base(mcp) <> "/mcp", deadline())
    end

    test "follows no redirect" do
      mcp = start_server(fn _request -> {307, [{"location", "https://elsewhere.dev/"}], ""} end)

      assert {:error, {:remote_security_blocked, {:redirect_refused, 307}}} =
               Discovery.discover(base(mcp) <> "/mcp", deadline())
    end
  end

  describe "every answer" do
    test "is bounded in size while it streams" do
      server =
        start_server(fn _request -> {200, [{"content-type", "application/json"}], big()} end)

      assert {:error, {:remote_protocol_error, {:response_too_large, _bytes}}} =
               Discovery.protected_resource(base(server) <> "/mcp", nil, deadline())
    end

    test "is bounded in time by the step's deadline" do
      server =
        start_server(fn _request ->
          {:stream, 200, [{"content-type", "application/json"}], "{"}
        end)

      started = System.monotonic_time(:millisecond)

      assert {:error, {:remote_unreachable, {:timeout, :mcp_remote_response, _ms}}} =
               Discovery.protected_resource(base(server) <> "/mcp", nil, Http.deadline(300))

      assert System.monotonic_time(:millisecond) - started < 2_000
    end
  end

  describe "a token's resource" do
    test "covers the server at its own address or under its path, on its origin only" do
      assert Discovery.covers?("https://mcp.linear.app/mcp", "https://mcp.linear.app/mcp")
      assert Discovery.covers?("https://mcp.linear.app", "https://mcp.linear.app/mcp")
      assert Discovery.covers?("https://mcp.linear.app/", "https://mcp.linear.app/mcp?x=1")
      assert Discovery.covers?("https://MCP.linear.app:443/mcp", "https://mcp.linear.app/mcp/")

      refute Discovery.covers?("https://mcp.linear.app/mcp", "https://mcp.linear.app/mcpx")
      refute Discovery.covers?("https://mcp.linear.app/other", "https://mcp.linear.app/mcp")
      refute Discovery.covers?("https://mcp.linear.app/mcp", "http://mcp.linear.app/mcp")
      refute Discovery.covers?("https://mcp.linear.app/mcp", "https://linear.app/mcp")
      refute Discovery.covers?("https://mcp.linear.app:8443/mcp", "https://mcp.linear.app/mcp")
      refute Discovery.covers?(nil, "https://mcp.linear.app/mcp")
    end
  end

  describe "Fermix's Client ID Metadata Document" do
    # The site serves these bytes at the client id; the code's id, its
    # redirect and every registration's metadata must be what they say.
    test "is the document the code registers with, served at its own client id" do
      document = @document |> File.read!() |> JSON.decode!()

      assert document == Registration.document()
      assert document["client_id"] == Registration.client_id()
      assert %URI{scheme: "https", host: "fermix.ai"} = URI.parse(Registration.client_id())

      {host, path} = Registration.redirect()
      assert document["redirect_uris"] == ["http://#{host}#{path}"]
      assert document["token_endpoint_auth_method"] == "none"
      assert document["application_type"] == "native"
    end
  end

  # --- helpers ----------------------------------------------------------------

  defp start_server(handler),
    do: start_supervised!(Supervisor.child_spec({LoopbackHttp, handler}, id: make_ref()))

  defp base(server), do: "http://127.0.0.1:#{LoopbackHttp.port(server)}"
  defp paths(server), do: Enum.map(LoopbackHttp.requests(server), & &1.path)
  defp host(request), do: request.headers |> List.keyfind("host", 0) |> elem(1)
  defp deadline, do: Http.deadline(10_000)

  defp prm(resource, issuer, scopes \\ []) do
    json(%{
      "resource" => resource,
      "authorization_servers" => [issuer],
      "scopes_supported" => scopes
    })
  end

  # An MCP server that answers `initialize` with a challenge naming no
  # metadata, and its well-known resource metadata naming `issuer`.
  defp protected(%{method: "POST"}, _issuer), do: {401, [{"www-authenticate", "Bearer"}], ""}

  defp protected(%{path: "/.well-known/oauth-protected-resource/mcp"} = request, issuer),
    do: prm("http://#{host(request)}/mcp", issuer)

  defp protected(_request, _issuer), do: {404, [], ""}

  # An issuer that publishes OpenID Connect discovery alone, naming itself
  # with `suffix` after its origin.
  defp oidc_only(%{path: "/.well-known/openid-configuration"} = request, suffix),
    do:
      json(%{
        as_metadata("http://#{host(request)}")
        | "issuer" => "http://#{host(request)}#{suffix}"
      })

  defp oidc_only(_request, _suffix), do: {404, [], ""}

  defp as_metadata(issuer) do
    %{
      "issuer" => issuer,
      "authorization_endpoint" => issuer <> "/authorize",
      "token_endpoint" => issuer <> "/token",
      "code_challenge_methods_supported" => ["S256"]
    }
  end

  defp big, do: JSON.encode!(%{"resource" => String.duplicate("x", 300 * 1024)})

  defp json(body), do: {200, [{"content-type", "application/json"}], JSON.encode!(body)}
end
