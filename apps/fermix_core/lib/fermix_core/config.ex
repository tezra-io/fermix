defmodule FermixCore.Config do
  @moduledoc """
  Typed accessor functions for Fermix runtime configuration.

  Reads from Application env for :fermix_core (providers, app settings)
  and :fermix_channels (channel config). All accessors return
  `{:ok, value} | {:error, :not_configured}`.
  """

  @channel_ingress_keys [
    telegram: :allowed_user_ids,
    whatsapp: :allowed_sender_ids,
    discord: :allowed_user_ids,
    slack: :allowed_user_ids,
    signal: :allowed_sender_ids
  ]

  @type config_error :: {:error, :not_configured}
  @type ingress_authority :: :config_allowlist | :paired_device | :none

  @spec provider(atom()) :: {:ok, keyword()} | config_error()
  def provider(name) when is_atom(name) do
    case Application.get_env(:fermix_core, :providers, []) do
      providers when is_list(providers) ->
        case Keyword.get(providers, name) do
          nil -> {:error, :not_configured}
          config when is_list(config) -> {:ok, config}
        end
    end
  end

  @spec provider_api_key(atom()) :: {:ok, String.t()} | config_error()
  def provider_api_key(name) when is_atom(name) do
    with {:ok, config} <- provider(name),
         key when is_binary(key) and key != "" <- Keyword.get(config, :api_key) do
      {:ok, key}
    else
      _ -> {:error, :not_configured}
    end
  end

  @spec tool(atom()) :: {:ok, keyword()} | config_error()
  def tool(name) when is_atom(name) do
    case Application.get_env(:fermix_core, :tools, []) do
      tools when is_list(tools) ->
        case Keyword.get(tools, name) do
          nil -> {:error, :not_configured}
          config when is_list(config) -> {:ok, config}
          _config -> {:error, :not_configured}
        end

      _tools ->
        {:error, :not_configured}
    end
  end

  @spec channel(atom()) :: {:ok, keyword()} | config_error()
  def channel(name) when is_atom(name) do
    case Application.get_env(:fermix_channels, name) do
      nil -> {:error, :not_configured}
      config when is_list(config) -> {:ok, config}
    end
  end

  @spec channel_command_owner_user_id(atom()) :: String.t() | nil
  def channel_command_owner_user_id(name) when is_atom(name) do
    with {:ok, config} <- channel(name) do
      owner = normalize_id(Keyword.get(config, :owner_user_id))

      owner || single_ingress_user_id(config, channel_ingress_key(name))
    else
      _ -> nil
    end
  end

  @doc """
  Strict owner lookup — returns `nil` unless `owner_user_id` is explicitly
  configured. Unlike `channel_command_owner_user_id/1`, this does not
  promote a single allowed-user-list entry to owner. Used by the ingress
  gateway so that adding a friend to `allowed_user_ids` does not silently
  grant them `:operator` trust; they get `:guest` (read-only) until the
  operator explicitly elevates them.
  """
  @spec channel_explicit_owner_user_id(atom()) :: String.t() | nil
  def channel_explicit_owner_user_id(name) when is_atom(name) do
    with {:ok, config} <- channel(name) do
      normalize_id(Keyword.get(config, :owner_user_id))
    else
      _ -> nil
    end
  end

  @spec channel_command_allowlist(atom()) :: [String.t()]
  def channel_command_allowlist(name) when is_atom(name) do
    with {:ok, config} <- channel(name) do
      config
      |> Keyword.get(:command_allowlist, [])
      |> normalize_ids()
    else
      _ -> []
    end
  end

  @spec channel_ingress_user_ids(atom()) :: [String.t()]
  def channel_ingress_user_ids(name) when is_atom(name) do
    with {:ok, config} <- channel(name),
         key when is_atom(key) <- channel_ingress_key(name) do
      channel_ingress_user_ids(name, config, key)
    else
      _ -> []
    end
  end

  @doc "Names the trust source for inbound channel connections."
  @spec channel_ingress_authority(atom()) :: ingress_authority()
  def channel_ingress_authority(:mobile), do: :paired_device

  def channel_ingress_authority(name) when is_atom(name) do
    if Keyword.has_key?(@channel_ingress_keys, name), do: :config_allowlist, else: :none
  end

  @spec get(atom(), term()) :: {:ok, term()} | config_error()
  def get(key, default \\ :__not_set__) when is_atom(key) do
    case Application.get_env(:fermix_core, key) do
      nil when default == :__not_set__ -> {:error, :not_configured}
      nil -> {:ok, default}
      value -> {:ok, value}
    end
  end

  defp channel_ingress_key(name), do: Keyword.get(@channel_ingress_keys, name)

  defp channel_ingress_user_ids(name, config, key) do
    case Keyword.fetch(config, key) do
      {:ok, ids} -> normalize_ids(ids)
      :error -> default_ingress_user_ids(name)
    end
  end

  defp default_ingress_user_ids(name) do
    case channel_command_owner_user_id(name) do
      nil -> []
      owner -> [owner]
    end
  end

  defp single_ingress_user_id(_config, nil), do: nil

  defp single_ingress_user_id(config, key) do
    if Keyword.has_key?(config, key) do
      case normalize_ids(Keyword.get(config, key, [])) do
        [id] -> id
        _ids -> nil
      end
    end
  end

  defp normalize_ids(ids) when is_list(ids) do
    ids
    |> Enum.map(&normalize_id/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_ids(_ids), do: []

  defp normalize_id(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_id(nil), do: nil
  defp normalize_id(value), do: to_string(value)
end
