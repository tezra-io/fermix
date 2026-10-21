defmodule FermixCore.Capabilities.MCP.OAuth.Discovery do
  @moduledoc """
  How an MCP server says it is signed in to (M74 §3, E5), read the way the MCP
  authorization specification (2025-11-25 and 2026-07-28) orders it. Every
  request goes through `OAuth.Http`, the remote rail's owner policy, with no
  redirect followed.

    1. **The challenge.** An `initialize` sent with no token. A `401` carrying
       a `Bearer` challenge gives `resource_metadata` and maybe `scope`
       (RFC 9728 §5.1, RFC 6750 §3). Any other answer gives neither.
    2. **Protected resource metadata** (RFC 9728 §3): from `resource_metadata`
       when the challenge named it, and only from there; otherwise from the
       well-known URIs in the specification's order, the one with the
       server's path inserted (`/.well-known/oauth-protected-resource/<path>`)
       and then the root one. A `4xx` moves to the next; anything else stops.
       The document's `resource` must name the server: its origin, and a path
       the server's lies at or under (RFC 9728 §3.3, read as the MCP SDKs read
       it, since servers publish their origin as well as the full URL). It is
       the resource indicator a sign-in sends (RFC 8707).
    3. **Authorization server metadata**: the first of `authorization_servers`
       is the issuer, read at RFC 8414 §3.1 then OpenID Connect Discovery, in
       the specification's order: for an issuer with a path, OAuth with the
       path inserted, OpenID Connect with the path inserted, OpenID Connect
       with the path appended; for one without, OAuth then OpenID Connect. A
       `4xx` moves to the next. The document's `issuer` must be the issuer
       exactly (RFC 8414 §3.3), and it must offer PKCE with `S256`: the
       specification has a client refuse an authorization server that does
       not say so.

  Scopes are the challenge's `scope`, else the resource's `scopes_supported`,
  else none.
  """

  alias FermixCore.Capabilities.MCP.OAuth.Challenge
  alias FermixCore.Capabilities.MCP.OAuth.Http

  @resource_well_known "/.well-known/oauth-protected-resource"
  @oauth_well_known "/.well-known/oauth-authorization-server"
  @oidc_well_known "/.well-known/openid-configuration"
  @token_auth_default ["client_secret_basic"]
  @default_ports %{"https" => 443, "http" => 80}
  @max_servers 16
  @max_scopes 64

  @type resource :: %{
          resource: String.t(),
          authorization_servers: [String.t()],
          scopes: [String.t()]
        }

  @type metadata :: %{
          resource: String.t(),
          scopes: [String.t()],
          issuer: String.t(),
          authorization_endpoint: String.t(),
          token_endpoint: String.t(),
          registration_endpoint: String.t() | nil,
          userinfo_endpoint: String.t() | nil,
          client_id_metadata_document?: boolean(),
          iss_required?: boolean(),
          token_auth_methods: [String.t()]
        }

  @doc "Everything a sign-in to the server at `url` needs to know, discovered."
  @spec discover(String.t(), integer(), keyword()) :: {:ok, metadata()} | {:error, term()}
  def discover(url, deadline, opts \\ []) when is_binary(url) do
    with {:ok, challenge} <- probe(url, deadline, opts),
         {:ok, resource} <- protected_resource(url, challenge, deadline, opts),
         {:ok, server} <- authorization_server(hd(resource.authorization_servers), deadline, opts) do
      {:ok, Map.merge(server, %{resource: resource.resource, scopes: resource.scopes})}
    end
  end

  @doc """
  The server's protected resource metadata, from the challenge's
  `resource_metadata` or the well-known URIs. Also read when a token is
  refused, to check the server still names the grant's issuer.
  """
  @spec protected_resource(String.t(), Challenge.t() | nil, integer(), keyword()) ::
          {:ok, resource()} | {:error, term()}
  def protected_resource(url, challenge, deadline, opts \\ []) do
    case metadata_url(challenge) do
      nil ->
        first_document(
          resource_candidates(url),
          &resource_document(&1, url, challenge),
          deadline,
          opts
        )

      named ->
        named_document(named, &resource_document(&1, url, challenge), deadline, opts)
    end
  end

  @doc """
  Whether a token minted for `resource` may be sent to `url`: the same origin,
  and `url`'s path at or under the resource's.
  """
  @spec covers?(String.t(), String.t()) :: boolean()
  def covers?(resource, url) when is_binary(resource) and is_binary(url) do
    {r, u} = {URI.parse(resource), URI.parse(url)}
    origin(r) == origin(u) and is_nil(r.fragment) and under?(path(u), path(r))
  end

  def covers?(_resource, _url), do: false

  # --- the challenge ----------------------------------------------------------

  # The request every MCP client opens with, so a server that guards it answers
  # with its challenge. A server that lets it through needs no sign-in to be
  # reached, and its well-known metadata is the only place a sign-in is named.
  defp probe(url, deadline, opts) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => initialize_params()
      })

    headers = [
      {"accept", "application/json, text/event-stream"},
      {"content-type", "application/json"}
    ]

    case Http.request(
           "POST",
           url,
           headers,
           body,
           deadline,
           Keyword.put(opts, :stop, :first_event)
         ) do
      {:ok, %{status: 401, headers: headers}} -> {:ok, Challenge.bearer(headers)}
      {:ok, _answered} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp initialize_params do
    %{
      "protocolVersion" => "2025-11-25",
      "capabilities" => %{},
      "clientInfo" => %{
        "name" => "fermix",
        "version" => to_string(Application.spec(:fermix_core, :vsn))
      }
    }
  end

  defp metadata_url(%{resource_metadata: url}) when is_binary(url), do: url
  defp metadata_url(_challenge), do: nil

  # --- protected resource metadata ------------------------------------------

  defp resource_candidates(url) do
    uri = URI.parse(url)
    base = origin_url(uri)

    case path(uri) do
      "/" ->
        [base <> @resource_well_known]

      path ->
        [
          base <> @resource_well_known <> String.trim_trailing(path, "/"),
          base <> @resource_well_known
        ]
    end
  end

  defp resource_document(document, url, challenge) do
    with {:ok, resource} <- text(document, "resource"),
         :ok <- check(covers?(resource, url), :resource_mismatch),
         {:ok, servers} <- authorization_servers(document) do
      {:ok,
       %{resource: resource, authorization_servers: servers, scopes: scopes(challenge, document)}}
    end
  end

  defp authorization_servers(%{"authorization_servers" => [_ | _] = servers}) do
    if length(servers) <= @max_servers and Enum.all?(servers, &issuer_url?/1),
      do: {:ok, servers},
      else: {:error, {:sign_in_discovery, :invalid_metadata}}
  end

  defp authorization_servers(_document),
    do: {:error, {:sign_in_discovery, :no_authorization_server}}

  defp scopes(%{scope: scope}, _document) when is_binary(scope) and scope != "",
    do: split_scopes(scope)

  defp scopes(_challenge, %{"scopes_supported" => scopes}) when is_list(scopes),
    do: scopes |> Enum.filter(&scope?/1) |> Enum.take(@max_scopes)

  defp scopes(_challenge, _document), do: []

  defp split_scopes(scope), do: scope |> String.split(" ", trim: true) |> Enum.take(@max_scopes)

  defp scope?(scope), do: is_binary(scope) and scope != "" and not String.contains?(scope, " ")

  # --- authorization server metadata ----------------------------------------

  defp authorization_server(issuer, deadline, opts) do
    first_document(server_candidates(issuer), &server_document(&1, issuer), deadline, opts)
  end

  defp server_candidates(issuer) do
    uri = URI.parse(issuer)
    base = origin_url(uri)

    case path(uri) do
      "/" ->
        [base <> @oauth_well_known, base <> @oidc_well_known]

      path ->
        path = String.trim_trailing(path, "/")

        [
          base <> @oauth_well_known <> path,
          base <> @oidc_well_known <> path,
          base <> path <> @oidc_well_known
        ]
    end
  end

  defp server_document(document, issuer) do
    with :ok <- check(document["issuer"] == issuer, :issuer_mismatch),
         {:ok, authorization} <- endpoint(document, "authorization_endpoint"),
         {:ok, token} <- endpoint(document, "token_endpoint"),
         :ok <-
           check("S256" in list(document, "code_challenge_methods_supported"), :pkce_unsupported) do
      {:ok,
       %{
         issuer: issuer,
         authorization_endpoint: authorization,
         token_endpoint: token,
         registration_endpoint: optional_endpoint(document, "registration_endpoint"),
         userinfo_endpoint: optional_endpoint(document, "userinfo_endpoint"),
         client_id_metadata_document?: document["client_id_metadata_document_supported"] == true,
         iss_required?: document["authorization_response_iss_parameter_supported"] == true,
         token_auth_methods: token_auth_methods(document)
       }}
    end
  end

  defp endpoint(document, key) do
    case document[key] do
      url when is_binary(url) -> if Http.allowed_url?(url), do: {:ok, url}, else: invalid()
      _absent -> invalid()
    end
  end

  defp optional_endpoint(document, key) do
    case endpoint(document, key) do
      {:ok, url} -> url
      {:error, _reason} -> nil
    end
  end

  # RFC 8414 §2: absent, the authorization server takes `client_secret_basic`.
  defp token_auth_methods(document) do
    case list(document, "token_endpoint_auth_methods_supported") do
      [] -> @token_auth_default
      methods -> methods
    end
  end

  defp list(document, key) do
    case document[key] do
      values when is_list(values) -> Enum.filter(values, &is_binary/1)
      _absent -> []
    end
  end

  # --- documents ------------------------------------------------------------

  # The one document a server named: anything but a usable one stops.
  defp named_document(url, accept, deadline, opts) do
    if Http.allowed_url?(url) do
      case Http.get_json(url, [], deadline, opts) do
        {:ok, status, %{} = document} when status in 200..299 -> accept.(document)
        {:ok, _status, _document} -> {:error, {:sign_in_discovery, :no_metadata}}
        {:error, reason} -> {:error, reason}
      end
    else
      invalid()
    end
  end

  # Candidates in order: a `4xx` moves to the next, a usable document or any
  # other answer stops.
  defp first_document([], _accept, _deadline, _opts),
    do: {:error, {:sign_in_discovery, :no_metadata}}

  defp first_document([url | rest], accept, deadline, opts) do
    case Http.get_json(url, [], deadline, opts) do
      {:ok, status, %{} = document} when status in 200..299 ->
        accept.(document)

      {:ok, status, _document} when status in 400..499 ->
        first_document(rest, accept, deadline, opts)

      {:ok, _status, _document} ->
        invalid()

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp text(document, key) do
    case document[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _absent -> invalid()
    end
  end

  # An issuer is an `https` URL (or `http` to this machine) with no query and
  # no fragment (RFC 8414 §2).
  defp issuer_url?(url) when is_binary(url) do
    uri = URI.parse(url)
    Http.allowed_url?(url) and is_nil(uri.query) and is_nil(uri.fragment)
  end

  defp issuer_url?(_url), do: false

  defp origin(%URI{scheme: scheme, host: host, port: port})
       when is_binary(scheme) and is_binary(host) do
    scheme = String.downcase(scheme)
    {scheme, String.downcase(host), port || Map.get(@default_ports, scheme)}
  end

  defp origin(_uri), do: nil

  defp origin_url(%URI{} = uri),
    do: URI.to_string(%URI{uri | path: nil, query: nil, fragment: nil, userinfo: nil})

  defp path(%URI{path: path}) when path in [nil, ""], do: "/"
  defp path(%URI{path: path}), do: path

  defp under?(_path, "/"), do: true

  defp under?(path, resource_path) do
    base = String.trim_trailing(resource_path, "/")
    path == base or path == base <> "/" or String.starts_with?(path, base <> "/")
  end

  defp check(true, _reason), do: :ok
  defp check(false, reason), do: {:error, {:sign_in_discovery, reason}}

  defp invalid, do: {:error, {:sign_in_discovery, :invalid_metadata}}
end
