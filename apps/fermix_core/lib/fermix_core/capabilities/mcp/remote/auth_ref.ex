defmodule FermixCore.Capabilities.MCP.Remote.AuthRef do
  @moduledoc """
  The opaque credential reference carried through supervision (M27 §7.3/§7.5,
  M74 E4).

  Every layer above the connection process — the materialized server spec, the
  sub-supervisor child spec, the `MCP.Registry` entry, crash reports — carries
  only this reference. The values are resolved **inside** the session
  process's `init/1` and exist nowhere else, because an OTP child spec is
  retained for the child's lifetime and is printed verbatim in a
  `failed_to_start_child` report.

  Three reference kinds, one from a manifest and two from `[mcp.servers.*]`:

    * `:plugin_secret`, from a signed manifest: exactly one wire shape,
      `Authorization: Bearer <credential>`. Header name and scheme are matched
      case-insensitively (HTTP header names and auth schemes are
      case-insensitive, and shipped `api_key` manifests already spell the
      header `authorization`) but always serialized canonically.
    * `:mcp_headers`, from an http server whose `auth` is `header` or `none`:
      the headers it declares in `header_secrets`, each read from
      `MCP.Secrets`. `Authorization` is sent as `Bearer <value>`, since its
      value is stored without the scheme; every other header is sent as
      stored. With `header` a `401` or `403` refuses the key; `none` sends no
      key at all.
    * `:mcp_oauth`, from an http server whose `auth` is `auto` (M74 E5): its
      declared headers, and `Authorization: Bearer <access token>` from its
      grant (`OAuth.Grant`) where it has one for the server's URL; none where
      it has none, so a public server keeps working. The token is read for
      each request (`current/2`), refreshed first when it is about to
      expire; a `401` to a request that carried one is renewed once
      (`renew/3`). A `401` that carries `WWW-Authenticate` asks for a
      sign-in, and a `403` whose challenge says `insufficient_scope` keeps
      the scopes it names for the next sign-in.
  """

  alias FermixCore.Auth.Redaction
  alias FermixCore.Capabilities.MCP.OAuth.Challenge
  alias FermixCore.Capabilities.MCP.OAuth.Grant
  alias FermixCore.Capabilities.MCP.Secrets, as: McpSecrets
  alias FermixCore.Plugins.Config, as: PluginConfig

  require Logger

  # Headers the session or the connection writes itself: a declared one of
  # these would send a second value beside the rail's own, `Host` among them.
  @reserved_headers ~w(accept connection content-length content-type host mcp-protocol-version mcp-session-id transfer-encoding)

  @type t ::
          %{type: :plugin_secret, plugin: String.t()}
          | %{
              type: :mcp_headers,
              server: String.t(),
              auth: :header | :none,
              headers: [String.t()]
            }
          | %{type: :mcp_oauth, server: String.t(), url: String.t(), headers: [String.t()]}

  @type wire_header :: {String.t(), String.t()}

  @doc "Validate a manifest-derived reference. Never touches the credential."
  @spec new(String.t()) :: {:ok, t()} | {:error, term()}
  def new(plugin) when is_binary(plugin) and plugin != "",
    do: {:ok, %{type: :plugin_secret, plugin: plugin}}

  def new(plugin), do: {:error, {:invalid_auth_ref, plugin}}

  @doc """
  Validate a manifest `auth` block against the remote-MCP v1 grammar. Returns
  the reference, not the credential.
  """
  @spec from_auth(map(), String.t()) :: {:ok, t()} | {:error, term()}
  def from_auth(%{type: :api_key} = auth, plugin) when is_binary(plugin) do
    header = auth |> Map.get(:header) |> normalize()
    scheme = auth |> Map.get(:scheme) |> normalize()

    cond do
      header != "authorization" -> {:error, {:invalid_remote_auth, :header_must_be_authorization}}
      scheme not in ["bearer", ""] -> {:error, {:invalid_remote_auth, :scheme_must_be_bearer}}
      true -> new(plugin)
    end
  end

  def from_auth(%{type: type}, _plugin), do: {:error, {:invalid_remote_auth, {:type, type}}}

  @doc """
  The reference for an `[mcp.servers.*]` http server: its name, its `auth`
  mode, the header names it declares and, for `auto`, the URL its grant must
  cover. Never touches a value. A declared header the rail writes itself is
  refused.
  """
  @spec operator(map()) :: {:ok, t()} | {:error, term()}
  def operator(%{name: server, auth: auth, header_secrets: headers} = spec)
      when is_binary(server) and auth in [:auto, :header, :none] and is_list(headers) do
    if Enum.any?(headers, &(String.downcase(&1) in @reserved_headers)),
      do: {:error, {:invalid_remote_config, :reserved_header}},
      else: operator_ref(spec)
  end

  def operator(_spec), do: {:error, {:invalid_remote_config, :auth_ref}}

  defp operator_ref(%{name: server, auth: :auto, url: url, header_secrets: headers})
       when is_binary(url),
       do: {:ok, %{type: :mcp_oauth, server: server, url: url, headers: headers}}

  defp operator_ref(%{auth: :auto}), do: {:error, {:invalid_remote_config, :auth_ref}}

  defp operator_ref(%{name: server, auth: auth, header_secrets: headers}),
    do: {:ok, %{type: :mcp_headers, server: server, auth: auth, headers: headers}}

  @doc """
  Resolve the reference to the headers that carry it. Call this ONLY from
  inside the session process's initialization.

  `:resolver` is the plugin credential's test seam; production reads the
  keychain-backed plugin secret. An operator server's headers are read through
  `MCP.Secrets`, whose store the suite replaces. There is exactly one source
  for each — no environment overlay — so "forget local credential" can be
  truthful (§7.5).
  """
  @spec resolve(t(), keyword()) :: {:ok, [wire_header()]} | {:error, term()}
  def resolve(auth_ref, opts \\ [])

  def resolve(%{type: :plugin_secret, plugin: plugin}, opts) when is_list(opts) do
    resolver = Keyword.get(opts, :resolver, &PluginConfig.plugin_secret/1)

    case resolver.(plugin) do
      secret when is_binary(secret) and secret != "" -> {:ok, [bearer(secret)]}
      _absent -> {:error, {:needs_secret, plugin}}
    end
  end

  def resolve(%{type: :mcp_headers, server: server, headers: names}, opts) when is_list(opts),
    do: declared_headers(server, names)

  def resolve(%{type: :mcp_oauth, server: server, headers: names} = ref, opts)
      when is_list(opts) do
    with {:ok, headers} <- declared_headers(server, names), do: current(ref, headers)
  end

  defp declared_headers(server, names) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, acc} ->
      case McpSecrets.fetch(server, {:header, name}) do
        {:ok, value} -> {:cont, {:ok, acc ++ [wire_header(name, value)]}}
        {:error, _reason} -> {:halt, {:error, {:header_unavailable, name}}}
      end
    end)
  end

  @doc """
  The headers for the next request, given the ones the last carried: for
  `:mcp_oauth`, the grant's access token as it is now (refreshed first when
  it is about to expire, absent when there is no grant for the URL); every
  other reference's headers do not change.
  """
  @spec current(t(), [wire_header()]) :: {:ok, [wire_header()]} | {:error, term()}
  def current(%{type: :mcp_oauth, server: server, url: url}, headers) do
    case Grant.token(server, url) do
      {:ok, token} -> {:ok, with_bearer(headers, token)}
      {:error, reason} -> {:error, grant_refusal(reason)}
    end
  end

  def current(_auth_ref, headers), do: {:ok, headers}

  @doc """
  After a `401` whose answer carried `response_headers`, to a request that
  carried `headers`: for `:mcp_oauth` with a token sent, the grant renewed
  once (`OAuth.Grant.renew/5`) and the headers to send again. `:none` when
  there is nothing to renew: another reference, or no token was sent.
  """
  @spec renew(t(), [wire_header()], [wire_header()]) ::
          {:ok, [wire_header()]} | :none | {:error, term()}
  def renew(%{type: :mcp_oauth, server: server, url: url}, headers, response_headers) do
    case sent_token(headers) do
      nil -> :none
      sent -> renewed(Grant.renew(server, url, sent, Challenge.bearer(response_headers)), headers)
    end
  end

  def renew(_auth_ref, _headers, _response_headers), do: :none

  defp renewed({:ok, token}, headers), do: {:ok, with_bearer(headers, token)}
  defp renewed({:error, reason}, _headers), do: {:error, grant_refusal(reason)}

  # A grant that cannot be used any more asks for a sign-in; anything else
  # (an authorization server out of reach) is reported as itself.
  defp grant_refusal(reason)
       when reason in [:expired, :issuer_changed, :no_grant, :unverified_issuer],
       do: {:reauthorization_required, :sign_in_required}

  defp grant_refusal(reason), do: reason

  defp sent_token(headers) do
    Enum.find_value(headers, fn
      {"authorization", "Bearer " <> token} -> token
      _other -> nil
    end)
  end

  defp with_bearer(headers, token) do
    rest = Enum.reject(headers, fn {name, _value} -> name == "authorization" end)
    if is_binary(token), do: rest ++ [bearer(token)], else: rest
  end

  @doc """
  What a `401` or `403` answer means for the credential this reference sent.
  `challenge` is the answer's `WWW-Authenticate` value, or `nil`; `host` is the
  endpoint's, for the plugin rail's reason.
  """
  @spec refusal(t(), 401 | 403, String.t() | nil, String.t()) :: term()
  def refusal(%{type: :mcp_headers, auth: :header}, status, _challenge, _host)
      when status in [401, 403],
      do: {:reauthorization_required, :key_refused}

  def refusal(%{type: :mcp_oauth}, 401, challenge, _host)
      when is_binary(challenge) and challenge != "",
      do: {:reauthorization_required, :sign_in_required}

  def refusal(%{type: :mcp_oauth, server: server}, 403, challenge, host) do
    case Challenge.parse(challenge) do
      %{error: "insufficient_scope"} = asked -> insufficient_scope(server, asked)
      _other -> refusal(nil, 403, challenge, host)
    end
  end

  def refusal(_auth_ref, 401, _challenge, host), do: {:reauthorization_required, host}
  def refusal(_auth_ref, 403, _challenge, _host), do: {:remote_http_error, 403}

  # The scopes the server named are kept on the grant, so the next sign-in asks
  # for them; the refusal itself is the status every surface already has words
  # for.
  defp insufficient_scope(server, %{scope: scope}) do
    scopes = if is_binary(scope), do: String.split(scope, " ", trim: true), else: []

    case Grant.want_scopes(server, scopes) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "MCP server #{server}: the scopes it asked for were not kept: #{Redaction.format(reason)}"
        )
    end

    {:insufficient_credential_scope, :scope}
  end

  defp wire_header(name, value) do
    if String.downcase(name) == "authorization", do: bearer(value), else: {name, value}
  end

  defp bearer(credential), do: {"authorization", "Bearer " <> credential}

  defp normalize(nil), do: ""
  defp normalize(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize(_value), do: ""
end
