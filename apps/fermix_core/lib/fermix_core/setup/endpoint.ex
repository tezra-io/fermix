defmodule FermixCore.Setup.Endpoint do
  @moduledoc """
  Resolves the daemon-hosted Setup endpoint and builds one-use launch URLs.

  The explicit port wins over `PORT`; absent values use the loopback default.
  Keeping this policy here prevents CLI and management clients from constructing
  different Setup URLs.
  """

  @default_port 4030
  @setup_path "/setup"

  @doc "Resolves the Setup listener port from explicit, environment, or default input."
  @spec port(keyword()) :: {:ok, 1..65_535} | {:error, {:invalid_port, atom(), term()}}
  def port(opts \\ []) when is_list(opts) do
    case Keyword.get(opts, :port) do
      value when is_integer(value) -> validate_port(value, :explicit)
      nil -> environment_port(opts)
      value -> {:error, {:invalid_port, :explicit, value}}
    end
  end

  @doc "The fixed loopback Setup path."
  @spec path() :: String.t()
  def path, do: @setup_path

  @doc "Builds the loopback HTTP origin for a validated port."
  @spec origin(integer()) :: {:ok, String.t()} | {:error, {:invalid_port, :explicit, term()}}
  def origin(port) do
    with {:ok, port} <- validate_port(port, :explicit) do
      {:ok, "http://127.0.0.1:#{port}"}
    end
  end

  @doc "Returns the public non-secret Setup endpoint descriptor."
  @spec describe(keyword()) :: {:ok, map()} | {:error, {:invalid_port, atom(), term()}}
  def describe(opts \\ []) when is_list(opts) do
    with {:ok, port} <- port(opts),
         {:ok, origin} <- origin(port) do
      {:ok, %{"origin" => origin, "path" => @setup_path}}
    end
  end

  @doc "Builds a URL containing one short-lived launch token."
  @spec launch_url(integer(), String.t()) ::
          {:ok, String.t()} | {:error, {:invalid_port, :explicit, term()} | :invalid_launch_token}
  def launch_url(port, token) when is_binary(token) and byte_size(token) > 0 do
    with {:ok, origin} <- origin(port) do
      {:ok, origin <> @setup_path <> "?t=" <> URI.encode_www_form(token)}
    end
  end

  def launch_url(_port, _token), do: {:error, :invalid_launch_token}

  defp environment_port(opts) do
    value =
      if Keyword.has_key?(opts, :port_env),
        do: Keyword.get(opts, :port_env),
        else: System.get_env("PORT")

    parse_environment_port(value)
  end

  defp parse_environment_port(value) when value in [nil, ""], do: {:ok, @default_port}

  defp parse_environment_port(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {port, ""} -> validate_port(port, :environment, value)
      _invalid -> {:error, {:invalid_port, :environment, value}}
    end
  end

  defp parse_environment_port(value), do: {:error, {:invalid_port, :environment, value}}

  defp validate_port(port, source, original \\ nil)

  defp validate_port(port, _source, _original)
       when is_integer(port) and port > 0 and port <= 65_535,
       do: {:ok, port}

  defp validate_port(port, source, nil), do: {:error, {:invalid_port, source, port}}
  defp validate_port(_port, source, original), do: {:error, {:invalid_port, source, original}}
end
