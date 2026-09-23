defmodule FermixCore.Setup.Endpoint do
  @moduledoc """
  Resolves the daemon-hosted Setup endpoint and builds one-use launch URLs.

  An explicit `:port` wins, because a caller that already knows the listener is
  not asking. Everything else is `FermixCore.Setup.WebListener`'s answer — the
  one resolver the daemon's own endpoint, the browser launcher and `hello`'s
  published origin share (M38 §4.7) — so the CLI and a management client can
  never construct different Setup URLs, and a packaged engine's refusal of a
  `PORT` override is the same refusal here as at boot.
  """

  alias FermixCore.BuildInfo
  alias FermixCore.Setup.WebListener

  @setup_path "/setup"

  @doc "Resolves the Setup listener port from explicit, environment, or default input."
  @spec port(keyword()) ::
          {:ok, 1..65_535}
          | {:error, {:invalid_port, atom(), term()} | {:port_not_used, String.t()}}
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
  @spec describe(keyword()) ::
          {:ok, map()}
          | {:error, {:invalid_port, atom(), term()} | {:port_not_used, String.t()}}
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
    distribution = Keyword.get(opts, :distribution, BuildInfo.distribution_identity())

    # A `PORT` a packaged engine refuses is not a `PORT` this CLI can parse and
    # dislike: the value is fine, the variable is simply not what decides the
    # listener. Rendering it as invalid would send an operator to fix a number
    # that was never wrong, so the refusal keeps its own reason and sentence.
    case WebListener.port(distribution, environment(opts), resolver_opts(opts)) do
      {:ok, %{port: port}} -> {:ok, port}
      {:error, failure} -> {:error, failure}
    end
  end

  # `:port_env` is how a caller supplies the one variable this resolver reads
  # without handing it the whole environment.
  defp environment(opts) do
    if Keyword.has_key?(opts, :port_env),
      do: %{"PORT" => Keyword.get(opts, :port_env)},
      else: System.get_env()
  end

  defp resolver_opts(opts), do: Keyword.take(opts, [:configured])

  defp validate_port(port, source, original \\ nil)

  defp validate_port(port, _source, _original)
       when is_integer(port) and port > 0 and port <= 65_535,
       do: {:ok, port}

  defp validate_port(port, source, nil), do: {:error, {:invalid_port, source, port}}
  defp validate_port(_port, source, original), do: {:error, {:invalid_port, source, original}}
end
