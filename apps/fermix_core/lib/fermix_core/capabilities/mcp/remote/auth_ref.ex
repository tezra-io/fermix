defmodule FermixCore.Capabilities.MCP.Remote.AuthRef do
  @moduledoc """
  The opaque credential reference carried through supervision (M27 §7.3/§7.5).

  Every layer above the connection process — the materialized server spec, the
  sub-supervisor child spec, the `MCP.Registry` entry, crash reports — carries
  only this reference. The bearer value is resolved **inside** the connection
  process's `init/1` and exists nowhere else, because an OTP child spec is
  retained for the child's lifetime and is printed verbatim in a
  `failed_to_start_child` report.

  v1 accepts exactly one reference kind, `:plugin_secret`, and exactly one wire
  shape: `Authorization: Bearer <credential>`. Header name and scheme are
  matched case-insensitively (HTTP header names and auth schemes are
  case-insensitive, and shipped `api_key` manifests already spell the header
  `authorization`) but always serialized canonically.
  """

  alias FermixCore.Plugins.Config, as: PluginConfig

  @type t :: %{type: :plugin_secret, plugin: String.t()}

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
  Resolve the reference to a bearer credential. Call this ONLY from inside the
  connection process's initialization.

  `:resolver` is the test seam; production reads the keychain-backed plugin
  secret. There is exactly one source — no environment overlay — so "forget
  local credential" can be truthful (§7.5).
  """
  @spec resolve(t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def resolve(%{type: :plugin_secret, plugin: plugin}, opts \\ []) when is_list(opts) do
    resolver = Keyword.get(opts, :resolver, &PluginConfig.plugin_secret/1)

    case resolver.(plugin) do
      secret when is_binary(secret) and secret != "" -> {:ok, secret}
      _absent -> {:error, {:needs_secret, plugin}}
    end
  end

  @doc "The canonical wire header for a resolved credential."
  @spec header(String.t()) :: {String.t(), String.t()}
  def header(credential) when is_binary(credential) and credential != "",
    do: {"authorization", "Bearer " <> credential}

  defp normalize(nil), do: ""
  defp normalize(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize(_value), do: ""
end
