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

  Two reference kinds, one per endpoint source:

    * `:plugin_secret`, from a signed manifest: exactly one wire shape,
      `Authorization: Bearer <credential>`. Header name and scheme are matched
      case-insensitively (HTTP header names and auth schemes are
      case-insensitive, and shipped `api_key` manifests already spell the
      header `authorization`) but always serialized canonically.
    * `:mcp_headers`, from an `[mcp.servers.*]` http server: the headers it
      declares in `header_secrets`, each read from `MCP.Secrets`.
      `Authorization` is sent as `Bearer <value>`, since its value is stored
      without the scheme; every other header is sent as stored. The server's
      `auth` mode says what a refusal means (`refusal/4`): with `header` a
      `401` or `403` refuses the key, with `auto` a `401` that carries
      `WWW-Authenticate` asks for a sign-in, and `none` sends no key at all.
  """

  alias FermixCore.Capabilities.MCP.Secrets, as: McpSecrets
  alias FermixCore.Plugins.Config, as: PluginConfig

  # Headers the session or the connection writes itself: a declared one of
  # these would send a second value beside the rail's own, `Host` among them.
  @reserved_headers ~w(accept connection content-length content-type host mcp-protocol-version mcp-session-id transfer-encoding)

  @type t ::
          %{type: :plugin_secret, plugin: String.t()}
          | %{
              type: :mcp_headers,
              server: String.t(),
              auth: :auto | :header | :none,
              headers: [String.t()]
            }

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
  mode and the header names it declares. Never touches a value. A declared
  header the rail writes itself is refused.
  """
  @spec operator(map()) :: {:ok, t()} | {:error, term()}
  def operator(%{name: server, auth: auth, header_secrets: headers})
      when is_binary(server) and auth in [:auto, :header, :none] and is_list(headers) do
    if Enum.any?(headers, &(String.downcase(&1) in @reserved_headers)),
      do: {:error, {:invalid_remote_config, :reserved_header}},
      else: {:ok, %{type: :mcp_headers, server: server, auth: auth, headers: headers}}
  end

  def operator(_spec), do: {:error, {:invalid_remote_config, :auth_ref}}

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

  def resolve(%{type: :mcp_headers, server: server, headers: names}, opts) when is_list(opts) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, acc} ->
      case McpSecrets.fetch(server, {:header, name}) do
        {:ok, value} -> {:cont, {:ok, acc ++ [wire_header(name, value)]}}
        {:error, _reason} -> {:halt, {:error, {:header_unavailable, name}}}
      end
    end)
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

  def refusal(%{type: :mcp_headers, auth: :auto}, 401, challenge, _host)
      when is_binary(challenge) and challenge != "",
      do: {:reauthorization_required, :sign_in_required}

  def refusal(_auth_ref, 401, _challenge, host), do: {:reauthorization_required, host}
  def refusal(_auth_ref, 403, _challenge, _host), do: {:remote_http_error, 403}

  defp wire_header(name, value) do
    if String.downcase(name) == "authorization", do: bearer(value), else: {name, value}
  end

  defp bearer(credential), do: {"authorization", "Bearer " <> credential}

  defp normalize(nil), do: ""
  defp normalize(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize(_value), do: ""
end
