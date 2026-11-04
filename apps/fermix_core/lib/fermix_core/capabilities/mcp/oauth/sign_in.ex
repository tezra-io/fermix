defmodule FermixCore.Capabilities.MCP.OAuth.SignIn do
  @moduledoc """
  The browser sign-in of an MCP server the owner added (M74 E5), which
  `auth.start mcp:<name>` runs as an `auth` job. Its phases:

    1. `discovering`: `OAuth.Discovery` reads how the server is signed in to.
    2. `registering`: `OAuth.Registration` picks the client (D6). The
       owner's client is refused where the server now names another issuer
       than the one it was signed in with (`Grant.owner_issuer/2`). A dynamic
       registration names the exact loopback redirect, so it is made, or a
       kept one reused, once the listener has bound its port: the port a kept
       registration names when it is free, another when it is not.
    3. `awaiting_browser`: the loopback listener of `Auth.OAuthFlow`, with
       PKCE (`S256`), `state`, and the `resource` indicator (RFC 8707) on the
       authorization request. The scopes are the server's (its challenge, or
       its resource's `scopes_supported`) and the ones it asked for since the
       last sign-in to the same issuer. The callback's `iss` (RFC 9207 §2.4)
       is compared to the issuer exactly when present, and a missing one is
       refused only where the metadata says
       `authorization_response_iss_parameter_supported`.
    4. `verifying`: the code is exchanged, with `resource`, under the
       grant's profile lock, and the grant is written before the lock is
       released (`OAuth.Grant`), so a busy profile refuses with the code
       unspent. The account label is the ID token's or the userinfo
       endpoint's `email`, else `preferred_username`, else `name`, else the
       issuer's host.

  A sign-in that completes starts the server once (`McpSupervisor`), and
  nothing else.
  """

  alias FermixCore.Auth.OAuthFlow
  alias FermixCore.Auth.OAuthProvider
  alias FermixCore.Capabilities.MCP.OAuth.Discovery
  alias FermixCore.Capabilities.MCP.OAuth.Grant
  alias FermixCore.Capabilities.MCP.OAuth.Http
  alias FermixCore.Capabilities.MCP.OAuth.Registration
  alias FermixCore.Capabilities.MCP.OAuth.Token
  alias FermixCore.Capabilities.MCP.Supervisor, as: McpSupervisor

  require Logger

  # Discovery and registration happen before the authorize url exists, and
  # `auth.start` waits for that url at most `Jobs`' 15 s.
  @prepare_budget_ms 12_000
  @exchange_budget_ms 15_000
  @userinfo_budget_ms 5_000
  @label_claims ~w(email preferred_username name)
  @max_label_chars 200

  @doc """
  Signs `server` in and starts it. `:phase` is told each phase as it begins,
  `:opener` gets the authorize url (as `Auth.OAuthFlow`'s does), and
  `:mcp_supervisor` names the module that starts the server, and
  `:loopback_owner` the desktop that started the sign-in (`Auth.OAuthFlow`).
  """
  @spec login(map(), keyword()) :: {:ok, %{account_label: String.t()}} | {:error, term()}
  def login(%{name: name, url: url} = server, opts) when is_binary(name) and is_binary(url) do
    phase = Keyword.get(opts, :phase, fn _phase -> :ok end)
    deadline = Http.deadline(@prepare_budget_ms)

    with {:ok, metadata, stored} <- discover(server, phase, deadline, opts),
         {:ok, choice} <- register(server, metadata, stored, phase),
         scopes = requested_scopes(metadata, stored),
         {:ok, authorization, client} <- authorize(metadata, choice, scopes, deadline, opts),
         {:ok, entry} <- redeem(server, metadata, client, scopes, authorization, phase, opts) do
      :ok = start(server, opts)
      {:ok, %{account_label: entry.mcp.account_label}}
    end
  end

  defp discover(server, phase, deadline, opts) do
    phase.("discovering")

    with {:ok, metadata} <- Discovery.discover(server.url, deadline, opts),
         {:ok, stored} <- Grant.read(server.name, opts) do
      {:ok, metadata, stored}
    end
  end

  defp register(server, metadata, stored, phase) do
    phase.("registering")

    with :ok <- owner_client_bound(server, metadata, stored) do
      Registration.client(server, metadata, Grant.registered_client(stored, metadata.issuer))
    end
  end

  # The owner's client ID and secret belong to the authorization server they
  # were signed in with: a server that now names another is refused before
  # the secret is read or the browser opens. Another client ID is the owner's
  # word that it belongs where the server now signs in.
  defp owner_client_bound(%{oauth_client_id: id} = server, %{issuer: issuer}, stored)
       when is_binary(id) do
    case Grant.owner_issuer(stored, id) do
      bound when bound in [nil, issuer] ->
        :ok

      bound ->
        Logger.warning(
          "MCP server #{server.name} now names #{issuer} for sign-in, not #{bound}, " <>
            "where its client ID was used; nothing was sent there"
        )

        {:error, {:owner_client_issuer_changed, bound, issuer}}
    end
  end

  defp owner_client_bound(_server, _metadata, _stored), do: :ok

  defp requested_scopes(metadata, stored),
    do: Enum.uniq(metadata.scopes ++ Grant.wanted_scopes(stored, metadata.issuer))

  defp authorize(metadata, choice, scopes, deadline, opts) do
    provider = provider(metadata, choice, scopes)

    with {:ok, authorization} <-
           OAuthFlow.await_authorization(provider, flow_opts(metadata, choice, deadline, opts)),
         :ok <- check_issuer(authorization, metadata) do
      {:ok, authorization, client_of(choice, authorization)}
    end
  end

  # A registered client is registered for the port the listener binds, so it
  # is known only once the authorization carries it back.
  defp client_of({:client, client}, _authorization), do: client
  defp client_of({:dynamic, _registered}, authorization), do: authorization.registration

  defp provider(metadata, choice, scopes) do
    {host, path} = Registration.redirect()

    %OAuthProvider{
      id: :mcp,
      authorize_url: metadata.authorization_endpoint,
      token_url: metadata.token_endpoint,
      client_id: known_client_id(choice),
      redirect_host: host,
      redirect_port: 0,
      redirect_path: path,
      scopes: scopes,
      extra_authorize_params: %{"resource" => metadata.resource},
      hardened_callback?: true
    }
  end

  defp known_client_id({:client, client}), do: client.id
  defp known_client_id({:dynamic, _registered}), do: nil

  defp flow_opts(metadata, choice, deadline, opts) do
    opts
    |> Keyword.take([:opener, :timeout_ms, :loopback_owner])
    |> Keyword.put(:puts, fn _line -> :ok end)
    |> Keyword.merge(listener_opts(metadata, choice, deadline, opts))
  end

  # A registration names its exact redirect: the listener asks for the port a
  # kept one names, and the client is registered, or reused, for the port it
  # bound before the authorize url names it.
  defp listener_opts(_metadata, {:client, _client}, _deadline, _opts), do: []

  defp listener_opts(metadata, {:dynamic, registered}, deadline, opts) do
    register = fn port ->
      with {:ok, client} <- Registration.dynamic(metadata, registered, port, deadline, opts),
           do: {:ok, client.id, client}
    end

    [preferred_port: registered && registered.port, register: register]
  end

  # RFC 9207 §2.4: a present `iss` is the issuer, compared exactly; an absent
  # one is refused where the metadata promised it.
  defp check_issuer(%{iss: nil}, %{iss_required?: true}), do: {:error, :issuer_missing}
  defp check_issuer(%{iss: nil}, _metadata), do: :ok
  defp check_issuer(%{iss: issuer}, %{issuer: issuer}), do: :ok
  defp check_issuer(%{iss: _other}, _metadata), do: {:error, :issuer_mismatch}

  # The code is spent under the profile lock, and the grant written before it
  # is released, so no refresh of an older grant lands over this one.
  defp redeem(server, metadata, client, scopes, authorization, phase, opts) do
    phase.("verifying")

    Grant.with_lock(server.name, opts, fn ->
      with {:ok, tokens} <- exchange(metadata, client, authorization, opts) do
        entry =
          Grant.signed_in(metadata, client, tokens, scopes, account_label(metadata, tokens, opts))

        persist(server.name, entry, opts)
      end
    end)
  end

  defp exchange(metadata, client, authorization, opts) do
    grant = %{
      code: authorization.code,
      verifier: authorization.code_verifier,
      redirect_uri: authorization.redirect_uri,
      resource: metadata.resource
    }

    Token.exchange(
      metadata.token_endpoint,
      client,
      grant,
      Http.deadline(@exchange_budget_ms),
      opts
    )
  end

  defp persist(name, entry, opts) do
    case Grant.write(name, entry, opts) do
      :ok -> {:ok, entry}
      {:error, reason} -> {:error, {:persist_failed, reason}}
    end
  end

  # --- the account label ----------------------------------------------------

  defp account_label(metadata, tokens, opts) do
    label(id_token_claims(tokens.id_token)) || userinfo_label(metadata, tokens, opts) ||
      URI.parse(metadata.issuer).host
  end

  # Received from the token endpoint itself, over TLS, and read for a label
  # alone (OpenID Connect Core §3.1.3.7), so its signature is not checked.
  defp id_token_claims(token) when is_binary(token) do
    with [_header, payload, _signature] <- String.split(token, "."),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, %{} = claims} <- Jason.decode(json) do
      claims
    else
      _unreadable -> nil
    end
  end

  defp id_token_claims(_absent), do: nil

  # The access token goes to the userinfo endpoint only on its issuer's own
  # origin, never to another server.
  defp userinfo_label(%{userinfo_endpoint: url, issuer: issuer}, tokens, opts)
       when is_binary(url) do
    if same_origin?(url, issuer) do
      headers = [{"authorization", "Bearer " <> tokens.access_token}]

      case Http.get_json(url, headers, Http.deadline(@userinfo_budget_ms), opts) do
        {:ok, 200, document} -> label(document)
        _unanswered -> nil
      end
    end
  end

  defp userinfo_label(_metadata, _tokens, _opts), do: nil

  defp label(%{} = claims), do: Enum.find_value(@label_claims, &text(claims[&1]))
  defp label(_claims), do: nil

  defp text(value) when is_binary(value) and value != "",
    do: String.slice(value, 0, @max_label_chars)

  defp text(_value), do: nil

  defp same_origin?(url, other) do
    {a, b} = {URI.parse(url), URI.parse(other)}
    {a.scheme, a.host, a.port} == {b.scheme, b.host, b.port}
  end

  # --- the start --------------------------------------------------------------

  defp start(server, opts) do
    if McpSupervisor.runs?(server) do
      supervisor = Keyword.get(opts, :mcp_supervisor, McpSupervisor)
      started(server.name, supervisor.restart_server({:operator, server.name}, server))
    else
      :ok
    end
  end

  # The grant is stored either way; a server that did not start says why on
  # its row and in the log.
  defp started(_name, {:ok, _pid}), do: :ok

  defp started(name, {:error, reason}) do
    Logger.error("MCP server #{name} did not start after its sign-in: #{inspect(reason)}")
    :ok
  end
end
