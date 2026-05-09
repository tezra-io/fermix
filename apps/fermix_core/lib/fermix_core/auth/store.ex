defmodule FermixCore.Auth.Store do
  @moduledoc """
  Versioned, provider-scoped auth profile at `~/.fermix/auth.json`.

  Reads tolerate the M3-era flat shape (one provider, top-level keys)
  and normalize it to the new nested shape silently. Writes always
  emit the new shape. Atomic via tmp+rename; perms forced to `0600`.

  No file locking — callers are serialized in-process: TokenManager
  is a singleton GenServer, the wizard runs sequentially. The atomic
  rename closes the multi-process race for the rare concurrent boot
  case (e.g. setup wizard running while the daemon is alive).
  """

  require Logger

  @schema_version 1

  @type provider :: atom()
  @type entry :: %{
          auth_mode: String.t(),
          tokens: %{access_token: String.t(), refresh_token: String.t() | nil},
          expires_at: DateTime.t() | nil,
          last_refresh: DateTime.t() | nil
        }

  @spec read(provider(), Path.t()) :: {:ok, entry()} | {:error, term()}
  def read(provider, path \\ default_path()) when is_atom(provider) do
    with {:ok, raw} <- File.read(path),
         {:ok, data} <- Jason.decode(raw),
         {:ok, providers} <- providers_map(data),
         {:ok, entry} <- fetch_provider(providers, provider) do
      {:ok, normalize(entry)}
    else
      {:error, %Jason.DecodeError{} = err} -> {:error, {:invalid_json, err}}
      {:error, :enoent} -> {:error, :no_auth_file}
      {:error, _reason} = err -> err
    end
  end

  @spec write(provider(), entry(), Path.t()) :: :ok | {:error, term()}
  def write(provider, %{} = entry, path \\ default_path()) when is_atom(provider) do
    with {:ok, current} <- read_or_empty(path),
         updated <- put_provider(current, provider, entry),
         :ok <- atomic_write(path, encode(updated)) do
      :ok
    end
  end

  @spec delete_provider(provider(), Path.t()) :: :ok | {:error, term()}
  def delete_provider(provider, path \\ default_path()) when is_atom(provider) do
    with {:ok, current} <- read_existing(path),
         {:ok, updated} <- remove_provider(current, provider),
         :ok <- atomic_write(path, encode(updated)) do
      :ok
    end
  end

  @spec path() :: Path.t()
  def path, do: default_path()

  defp default_path do
    home = System.get_env("FERMIX_HOME") || Path.join(System.user_home!(), ".fermix")
    Path.join(home, "auth.json")
  end

  defp providers_map(%{"providers" => providers}) when is_map(providers), do: {:ok, providers}

  # Migration: M3-era flat shape — one ChatGPT OAuth provider implicit at
  # the top level. It belongs to openai_codex, not api-key openai.
  defp providers_map(%{"tokens" => _} = flat),
    do: {:ok, %{"openai_codex" => flat}}

  defp providers_map(_), do: {:error, :no_providers}

  defp fetch_provider(providers, provider) do
    case Map.get(providers, Atom.to_string(provider)) do
      nil -> {:error, {:provider_missing, provider}}
      entry -> {:ok, entry}
    end
  end

  defp normalize(entry) do
    tokens = Map.get(entry, "tokens", %{})
    access = Map.get(tokens, "access_token")

    if not (is_binary(access) and access != "") do
      raise ArgumentError, "auth entry missing access_token"
    end

    %{
      auth_mode: Map.get(entry, "auth_mode") || "chatgpt",
      tokens: %{
        access_token: access,
        refresh_token: Map.get(tokens, "refresh_token")
      },
      expires_at: parse_iso8601(Map.get(entry, "expires_at")),
      last_refresh: parse_iso8601(Map.get(entry, "last_refresh"))
    }
  end

  defp parse_iso8601(nil), do: nil

  defp parse_iso8601(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp read_or_empty(path) do
    case File.read(path) do
      {:ok, raw} ->
        case Jason.decode(raw) do
          {:ok, %{"providers" => _} = data} -> {:ok, data}
          {:ok, %{"tokens" => _} = flat} -> {:ok, legacy_codex_doc(flat)}
          {:ok, _} -> {:ok, empty_doc()}
          {:error, _} -> {:ok, empty_doc()}
        end

      {:error, :enoent} ->
        {:ok, empty_doc()}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_existing(path) do
    case File.read(path) do
      {:ok, raw} ->
        case Jason.decode(raw) do
          {:ok, %{"providers" => providers} = data} when is_map(providers) -> {:ok, data}
          {:ok, %{"tokens" => _} = flat} -> {:ok, legacy_codex_doc(flat)}
          {:ok, _} -> {:error, :no_providers}
          {:error, %Jason.DecodeError{} = err} -> {:error, {:invalid_json, err}}
          {:error, reason} -> {:error, reason}
        end

      {:error, :enoent} ->
        {:error, :no_auth_file}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp empty_doc, do: %{"version" => @schema_version, "providers" => %{}}

  defp legacy_codex_doc(flat),
    do: %{"version" => @schema_version, "providers" => %{"openai_codex" => flat}}

  defp put_provider(doc, provider, entry) do
    serialized = %{
      "auth_mode" => entry.auth_mode,
      "tokens" => %{
        "access_token" => entry.tokens.access_token,
        "refresh_token" => entry.tokens.refresh_token
      },
      "expires_at" => entry.expires_at && DateTime.to_iso8601(entry.expires_at),
      "last_refresh" => DateTime.to_iso8601(DateTime.utc_now())
    }

    providers = Map.put(Map.get(doc, "providers", %{}), Atom.to_string(provider), serialized)
    %{"version" => @schema_version, "providers" => providers}
  end

  defp remove_provider(%{"providers" => providers}, provider) when is_map(providers) do
    key = Atom.to_string(provider)

    if Map.has_key?(providers, key) do
      {:ok, %{"version" => @schema_version, "providers" => Map.delete(providers, key)}}
    else
      {:error, {:provider_missing, provider}}
    end
  end

  defp remove_provider(_doc, _provider), do: {:error, :no_providers}

  defp encode(doc), do: Jason.encode!(doc, pretty: true) <> "\n"

  defp atomic_write(path, contents) do
    dir = Path.dirname(path)
    tmp = "#{path}.tmp.#{System.unique_integer([:positive, :monotonic])}"

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(tmp, contents, [:binary]),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        Logger.warning("Auth.Store: failed to persist — #{inspect(reason)}")
        {:error, reason}
    end
  end
end
