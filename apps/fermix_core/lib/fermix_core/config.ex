defmodule FermixCore.Config do
  @moduledoc """
  Typed accessor functions for Fermix runtime configuration.

  Reads from Application env for :fermix_core (providers, app settings)
  and :fermix_channels (channel config). All accessors return
  `{:ok, value} | {:error, :not_configured}`.
  """

  @type config_error :: {:error, :not_configured}

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

  @spec channel(atom()) :: {:ok, keyword()} | config_error()
  def channel(name) when is_atom(name) do
    case Application.get_env(:fermix_channels, name) do
      nil -> {:error, :not_configured}
      config when is_list(config) -> {:ok, config}
    end
  end

  @spec get(atom(), term()) :: {:ok, term()} | config_error()
  def get(key, default \\ :__not_set__) when is_atom(key) do
    case Application.get_env(:fermix_core, key) do
      nil when default == :__not_set__ -> {:error, :not_configured}
      nil -> {:ok, default}
      value -> {:ok, value}
    end
  end
end
