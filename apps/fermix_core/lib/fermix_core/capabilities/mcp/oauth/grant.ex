defmodule FermixCore.Capabilities.MCP.OAuth.Grant do
  @moduledoc """
  The grant an MCP server the owner added signed in for (M74 E5): one
  `mcp:<name>` entry in `auth.json`, in `Auth.Store`'s open profile family,
  never in `config.toml`.

  It carries the token set and its expiry, the client that refreshes it (its
  id at the top, as every entry's, and under `mcp` how it authenticates and
  where it came from: the owner's, Fermix's Client ID Metadata Document, or a
  registration, with the loopback port its redirect names), the issuer that minted it, the resource it was minted for
  and that issuer's token endpoint, the scopes granted and the scopes the
  server asked for since, and the account label. Its status:

    * `"ready"`: signed in.
    * `"expired"`: its issuer refused a refresh, or there was nothing to
      refresh with. The tokens are cleared; the issuer, the client and the
      account stay, so the row says whose sign-in expired and the next
      sign-in reuses a registered client.
    * `"signed_out"`: `auth.logout` cleared it, and only a client a
      registration issued, or the owner's client and the issuer it was used
      with, is kept, for the next sign-in.

  Credentials are keyed by issuer and never cross to another: the access
  token goes only to a server the grant's resource covers, and the refresh
  token only to its issuer's token endpoint. When a server refuses the token
  and no longer names that issuer, the grant is deleted, and the server asks
  for a sign-in again. The owner's client keeps the issuer it was used with
  through that, as through a sign-out, so a sign-in elsewhere is refused
  before its secret is read (`owner_issuer/2`).

  Every refresh runs under the profile lock, from its read of the entry to
  its write (`Auth.Store.with_profile_lock/3`), so two refreshers never spend
  one refresh token and a sign-out never lands inside a refresh.
  """

  alias FermixCore.Auth.Redaction
  alias FermixCore.Auth.Store
  alias FermixCore.Auth.TokenExpiry
  alias FermixCore.Capabilities.MCP.OAuth.Discovery
  alias FermixCore.Capabilities.MCP.OAuth.Http
  alias FermixCore.Capabilities.MCP.OAuth.Registration
  alias FermixCore.Capabilities.MCP.OAuth.Token

  require Logger

  @auth_mode "mcp_oauth"
  @ready "ready"
  @expired "expired"
  @signed_out "signed_out"
  @refresh_budget_ms 15_000
  @client_kinds %{
    owner: "owner",
    metadata_document: "metadata_document",
    registered: "registered"
  }

  @type row_state :: %{
          state: :signed_in | :expired,
          account_label: String.t() | nil,
          issuer: String.t() | nil,
          wanted_scopes: [String.t()]
        }

  @doc "The auth profile `server`'s grant lives under."
  @spec profile(String.t()) :: String.t()
  def profile(server) when is_binary(server), do: Store.mcp_profile(server)

  @doc "The stored entry, with or without a token, or `nil` when there is none."
  @spec read(String.t(), keyword()) :: {:ok, Store.entry() | nil} | {:error, term()}
  def read(server, opts \\ []) when is_binary(server) do
    case Store.read_registration(profile(server), path(opts)) do
      {:ok, entry} -> {:ok, entry}
      {:error, :no_auth_file} -> {:ok, nil}
      {:error, {:provider_missing, _profile}} -> {:ok, nil}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  What `server`'s row says of its grant: signed in or expired, whose and
  from which issuer, and the scopes it was asked for since; `nil` for no
  grant, a signed-out one, or one minted for another address.
  """
  @spec row_state(map(), keyword()) :: row_state() | nil
  def row_state(%{name: name, url: url}, opts \\ []) do
    case read(name, opts) do
      {:ok, entry} ->
        entry_state(entry, url)

      {:error, reason} ->
        Logger.warning(
          "MCP server #{name}: its sign-in could not be read: #{Redaction.format(reason)}"
        )

        nil
    end
  end

  defp entry_state(%{status: status, mcp: %{} = mcp} = entry, url)
       when status in [@ready, @expired] do
    if Discovery.covers?(mcp.resource, url) and (status == @expired or token?(entry)) do
      %{
        state: if(status == @ready, do: :signed_in, else: :expired),
        account_label: mcp.account_label,
        issuer: mcp.issuer,
        wanted_scopes: mcp.wanted_scopes || []
      }
    end
  end

  defp entry_state(_entry, _url), do: nil

  @doc "A verified sign-in's entry."
  @spec signed_in(
          Discovery.metadata(),
          Registration.client(),
          Token.tokens(),
          [String.t()],
          String.t()
        ) ::
          Store.entry()
  def signed_in(metadata, client, tokens, requested, account_label) do
    %{
      auth_mode: @auth_mode,
      client_id: client.id,
      tokens: %{access_token: tokens.access_token, refresh_token: tokens.refresh_token},
      expires_at: tokens.expires_at,
      last_refresh: DateTime.utc_now(),
      status: @ready,
      mcp: %{
        issuer: metadata.issuer,
        resource: metadata.resource,
        token_endpoint: metadata.token_endpoint,
        client_kind: Map.fetch!(@client_kinds, client.kind),
        token_auth: client.auth,
        client_secret: if(client.kind == :registered, do: client.secret),
        redirect_port: if(client.kind == :registered, do: client.port),
        scopes: granted(tokens.scope, requested),
        wanted_scopes: [],
        account_label: account_label
      }
    }
  end

  # RFC 6749 §5.1: a token answer that names no scope granted what was asked.
  defp granted(nil, requested), do: requested
  defp granted(scope, _requested), do: String.split(scope, " ", trim: true)

  @doc "Stores `entry` as `server`'s grant. The caller holds the profile lock."
  @spec write(String.t(), Store.entry(), keyword()) :: :ok | {:error, term()}
  def write(server, entry, opts \\ []), do: Store.write(profile(server), entry, path(opts))

  @doc "Runs `fun` holding `server`'s profile lock."
  @spec with_lock(String.t(), keyword(), (-> result)) :: result | {:error, term()}
        when result: term()
  def with_lock(server, opts, fun), do: Store.with_profile_lock(profile(server), path(opts), fun)

  @doc """
  The client a registration with `issuer` issued, kept on `entry`, for the
  next sign-in to the same issuer; `nil` for any other.
  """
  @spec registered_client(Store.entry() | nil, String.t()) :: Registration.client() | nil
  def registered_client(
        %{client_id: id, mcp: %{client_kind: "registered", issuer: issuer} = mcp},
        issuer
      )
      when is_binary(id) do
    %{
      id: id,
      secret: mcp.client_secret,
      auth: mcp.token_auth || "none",
      kind: :registered,
      port: mcp.redirect_port
    }
  end

  def registered_client(_entry, _issuer), do: nil

  @doc """
  The issuer the owner's client `client_id` was signed in with, kept on
  `entry` through an expiry, a sign-out and a server that names another
  issuer; `nil` when `entry` holds no sign-in of that client.
  """
  @spec owner_issuer(Store.entry() | nil, String.t()) :: String.t() | nil
  def owner_issuer(%{client_id: id, mcp: %{client_kind: "owner", issuer: issuer}}, id)
      when is_binary(issuer),
      do: issuer

  def owner_issuer(_entry, _client_id), do: nil

  @doc "The scopes a server asked for since `entry` was minted by `issuer`, which a sign-in asks for too."
  @spec wanted_scopes(Store.entry() | nil, String.t()) :: [String.t()]
  def wanted_scopes(%{mcp: %{issuer: issuer, wanted_scopes: [_ | _] = wanted}}, issuer),
    do: wanted

  def wanted_scopes(_entry, _issuer), do: []

  @doc """
  The access token to send to the server at `url`: `nil` with no grant that
  covers it, refreshed first when it is about to expire.
  """
  @spec token(String.t(), String.t(), keyword()) :: {:ok, String.t() | nil} | {:error, term()}
  def token(server, url, opts \\ []) when is_binary(server) and is_binary(url) do
    with {:ok, entry} <- read(server, opts) do
      cond do
        not usable?(entry, url) ->
          {:ok, nil}

        TokenExpiry.refresh_due?(entry.expires_at) ->
          refresh(server, url, entry.tokens.access_token, opts)

        true ->
          {:ok, entry.tokens.access_token}
      end
    end
  end

  @doc """
  After the server at `url` refused `sent` with `challenge`: checks the server
  still names the grant's issuer, then refreshes once. A server that names
  another issuer has the grant deleted (`:issuer_changed`); a refused refresh
  leaves it expired (`:expired`).
  """
  @spec renew(String.t(), String.t(), String.t(), map() | nil, keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def renew(server, url, sent, challenge, opts \\ []) do
    deadline = Http.deadline(@refresh_budget_ms)

    with {:ok, entry} <- read(server, opts),
         :ok <- if(usable?(entry, url), do: :ok, else: {:error, :no_grant}),
         {:ok, resource} <- named_servers(url, challenge, deadline, opts),
         :ok <- same_issuer(server, entry, resource, opts) do
      refresh(server, url, sent, opts)
    end
  end

  defp named_servers(url, challenge, deadline, opts) do
    case Discovery.protected_resource(url, challenge, deadline, opts) do
      {:ok, resource} -> {:ok, resource}
      {:error, {:sign_in_discovery, _reason}} -> {:error, :unverified_issuer}
      {:error, _unreachable} = error -> error
    end
  end

  defp same_issuer(server, entry, resource, opts) do
    if entry.mcp.issuer in resource.authorization_servers do
      :ok
    else
      Logger.warning(
        "MCP server #{server} names another authorization server; its sign-in was deleted"
      )

      with :ok <- forget_issuer(server, entry, opts), do: {:error, :issuer_changed}
    end
  end

  # The owner's client keeps the issuer it was used with, which the next
  # sign-in holds it to; any other grant goes whole, its registration with it.
  defp forget_issuer(server, %{mcp: %{client_kind: "owner"}}, opts), do: keep_client(server, opts)
  defp forget_issuer(server, _entry, opts), do: delete(server, opts)

  @doc "Keeps the scopes a server asked for in a `403 insufficient_scope`, so the next sign-in asks for them too."
  @spec want_scopes(String.t(), [String.t()], keyword()) :: :ok | {:error, term()}
  def want_scopes(server, scopes, opts \\ []) when is_list(scopes) do
    with_lock(server, opts, fn ->
      case read(server, opts) do
        {:ok, %{status: @ready, mcp: %{} = mcp} = entry} ->
          wanted = Enum.uniq((mcp.wanted_scopes || []) ++ scopes)
          write(server, %{entry | mcp: %{mcp | wanted_scopes: wanted}}, opts)

        {:ok, _no_grant} ->
          :ok

        {:error, _reason} = error ->
          error
      end
    end)
  end

  @doc """
  Forgets `server`'s grant locally (`auth.logout`). Nothing is revoked
  upstream. A client a registration issued, and the owner's client with the
  issuer it was used with, are kept for the next sign-in.
  """
  @spec forget(String.t(), keyword()) :: :ok | {:error, term()}
  def forget(server, opts \\ []) do
    case read(server, opts) do
      {:ok, nil} ->
        :ok

      {:ok, %{mcp: %{client_kind: kind}}} when kind in ["registered", "owner"] ->
        keep_client(server, opts)

      {:ok, _entry} ->
        delete(server, opts)

      {:error, _reason} = error ->
        error
    end
  end

  defp keep_client(server, opts) do
    with_lock(server, opts, fn ->
      case read(server, opts) do
        {:ok, %{} = entry} -> write(server, signed_out(entry), opts)
        {:ok, nil} -> :ok
        {:error, _reason} = error -> error
      end
    end)
  end

  defp signed_out(%{mcp: mcp} = entry) do
    kept =
      Map.take(mcp, [
        :issuer,
        :token_endpoint,
        :client_kind,
        :token_auth,
        :client_secret,
        :redirect_port
      ])

    %{
      entry
      | tokens: %{access_token: nil, refresh_token: nil},
        expires_at: nil,
        status: @signed_out,
        mcp:
          Map.merge(%{resource: nil, scopes: nil, wanted_scopes: nil, account_label: nil}, kept)
    }
  end

  @doc "Deletes `server`'s grant and its client: the server was removed, or its issuer changed."
  @spec delete(String.t(), keyword()) :: :ok | {:error, term()}
  def delete(server, opts \\ []) do
    case Store.delete_provider(profile(server), path(opts)) do
      :ok -> :ok
      {:error, :no_auth_file} -> :ok
      {:error, {:provider_missing, _profile}} -> :ok
      {:error, _reason} = error -> error
    end
  end

  # --- refresh ----------------------------------------------------------------

  defp refresh(server, url, sent, opts) do
    with_lock(server, opts, fn -> refresh_locked(server, url, sent, opts) end)
  end

  # Another process may have refreshed while this one waited for the lock: its
  # token is the one to send, and the refresh token it spent is not spent again.
  defp refresh_locked(server, url, sent, opts) do
    with {:ok, entry} <- read(server, opts) do
      cond do
        not usable?(entry, url) -> {:error, :no_grant}
        entry.tokens.access_token != sent -> {:ok, entry.tokens.access_token}
        is_nil(entry.tokens.refresh_token) -> expire(server, entry, :no_refresh_token, opts)
        true -> settle_refresh(request_refresh(server, entry, opts), server, entry, opts)
      end
    end
  end

  defp request_refresh(server, entry, opts) do
    stored = %{
      id: entry.client_id,
      secret: entry.mcp.client_secret,
      auth: entry.mcp.token_auth || "none",
      kind: kind(entry.mcp.client_kind)
    }

    client = %{stored | secret: Registration.secret(server, stored)}
    deadline = Http.deadline(@refresh_budget_ms)

    Token.refresh(
      entry.mcp.token_endpoint,
      client,
      entry.tokens.refresh_token,
      entry.mcp.resource,
      deadline,
      opts
    )
  end

  defp settle_refresh({:ok, tokens}, server, entry, opts) do
    refreshed = %{
      entry
      | tokens: %{
          access_token: tokens.access_token,
          refresh_token: tokens.refresh_token || entry.tokens.refresh_token
        },
        expires_at: tokens.expires_at,
        mcp: %{entry.mcp | scopes: granted(tokens.scope, entry.mcp.scopes || [])}
    }

    with :ok <- write(server, refreshed, opts), do: {:ok, tokens.access_token}
  end

  defp settle_refresh({:error, {:token_refused, code}}, server, entry, opts),
    do: expire(server, entry, code, opts)

  defp settle_refresh({:error, _unreachable} = error, _server, _entry, _opts), do: error

  defp expire(server, entry, why, opts) do
    Logger.warning("MCP server #{server}: its sign-in could not be refreshed (#{why})")

    expired = %{
      entry
      | tokens: %{access_token: nil, refresh_token: nil},
        expires_at: nil,
        status: @expired
    }

    with :ok <- write(server, expired, opts), do: {:error, :expired}
  end

  defp usable?(%{status: @ready, mcp: %{} = mcp} = entry, url),
    do: token?(entry) and Discovery.covers?(mcp.resource, url)

  defp usable?(_entry, _url), do: false

  defp token?(%{tokens: %{access_token: token}}), do: is_binary(token) and token != ""
  defp token?(_entry), do: false

  defp kind(name) do
    Enum.find_value(@client_kinds, :registered, fn {kind, stored} ->
      if stored == name, do: kind
    end)
  end

  defp path(opts), do: Keyword.get_lazy(opts, :auth_path, &Store.path/0)
end
