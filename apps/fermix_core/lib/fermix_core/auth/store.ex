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

  @schema_version 2

  @type provider :: atom() | String.t()
  @type entry :: %{
          required(:auth_mode) => String.t(),
          required(:tokens) => %{access_token: String.t(), refresh_token: String.t() | nil},
          required(:expires_at) => DateTime.t() | nil,
          required(:last_refresh) => DateTime.t() | nil,
          optional(:provider) => String.t() | nil,
          optional(:account) => map() | nil,
          optional(:scope_profile) => String.t() | nil,
          optional(:granted_scopes) => [String.t()],
          optional(:status) => String.t() | nil
        }

  @spec read(provider(), Path.t()) :: {:ok, entry()} | {:error, term()}
  def read(provider, path \\ default_path()) when is_atom(provider) or is_binary(provider) do
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
  def write(provider, %{} = entry, path \\ default_path())
      when is_atom(provider) or is_binary(provider) do
    with {:ok, current} <- read_for_write(path),
         updated <- put_provider(current, provider, entry),
         :ok <- atomic_write(path, encode(updated)) do
      :ok
    end
  end

  @spec delete_provider(provider(), Path.t()) :: :ok | {:error, term()}
  def delete_provider(provider, path \\ default_path())
      when is_atom(provider) or is_binary(provider) do
    with {:ok, current} <- read_existing(path),
         {:ok, updated} <- remove_provider(current, provider),
         :ok <- atomic_write(path, encode(updated)) do
      :ok
    end
  end

  @spec path() :: Path.t()
  def path, do: default_path()

  @spec validate_permissions(Path.t()) ::
          :ok | {:error, {:insecure_permissions, Path.t(), non_neg_integer()}} | {:error, term()}
  def validate_permissions(path \\ default_path()) when is_binary(path) do
    case File.stat(path) do
      {:ok, %{mode: mode}} ->
        check_mode(path, Bitwise.band(mode, 0o777))

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec validate_permissions!(Path.t()) :: :ok
  def validate_permissions!(path \\ default_path()) when is_binary(path) do
    case validate_permissions(path) do
      :ok ->
        :ok

      {:error, {:insecure_permissions, ^path, mode}} ->
        raise ArgumentError, permissions_message(path, mode)

      {:error, reason} ->
        raise ArgumentError, "failed to stat #{path}: #{inspect(reason)}"
    end
  end

  @spec permissions_message(Path.t(), non_neg_integer()) :: String.t()
  def permissions_message(path, mode) when is_binary(path) and is_integer(mode) do
    "#{path} has perms 0o#{Integer.to_string(mode, 8)} (expected 0o600). " <>
      "Run `chmod 600 #{path}` and restart."
  end

  defp default_path do
    home = System.get_env("FERMIX_HOME") || Path.join(System.user_home!(), ".fermix")
    Path.join(home, "auth.json")
  end

  defp check_mode(_path, 0o600), do: :ok
  defp check_mode(path, mode), do: {:error, {:insecure_permissions, path, mode}}

  defp providers_map(%{"providers" => providers}) when is_map(providers), do: {:ok, providers}

  # Migration: M3-era flat shape — one ChatGPT OAuth provider implicit at
  # the top level. It belongs to openai_codex, not api-key openai.
  defp providers_map(%{"tokens" => _} = flat),
    do: {:ok, %{"openai_codex" => flat}}

  defp providers_map(_), do: {:error, :no_providers}

  defp fetch_provider(providers, provider) do
    case Map.get(providers, provider_key(provider)) do
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
      provider: Map.get(entry, "provider"),
      account: normalize_account(Map.get(entry, "account")),
      scope_profile: Map.get(entry, "scope_profile"),
      granted_scopes: normalize_string_list(Map.get(entry, "granted_scopes")),
      tokens: %{
        access_token: access,
        refresh_token: Map.get(tokens, "refresh_token")
      },
      expires_at: parse_iso8601(Map.get(entry, "expires_at")),
      last_refresh: parse_iso8601(Map.get(entry, "last_refresh")),
      status: Map.get(entry, "status")
    }
  end

  defp normalize_account(account) when is_map(account) do
    account
    |> Enum.into(%{}, fn {key, value} -> {normalize_account_key(key), value} end)
    |> atomize_known_account_keys()
  end

  defp normalize_account(_account), do: nil

  defp normalize_account_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_account_key(key) when is_binary(key), do: key

  defp atomize_known_account_keys(account) do
    account
    |> maybe_atomize_key("subject", :subject)
    |> maybe_atomize_key("email", :email)
    |> maybe_atomize_key("display_name", :display_name)
  end

  defp maybe_atomize_key(account, string_key, atom_key) do
    case Map.fetch(account, string_key) do
      {:ok, value} -> account |> Map.delete(string_key) |> Map.put(atom_key, value)
      :error -> account
    end
  end

  defp normalize_string_list(values) when is_list(values) do
    Enum.filter(values, &is_binary/1)
  end

  defp normalize_string_list(_values), do: []

  defp parse_iso8601(nil), do: nil

  defp parse_iso8601(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp read_for_write(path) do
    case File.read(path) do
      {:ok, raw} ->
        decode_for_write(path, raw)

      {:error, :enoent} ->
        {:ok, empty_doc()}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_for_write(path, raw) do
    case Jason.decode(raw) do
      {:ok, %{"providers" => providers} = data} when is_map(providers) ->
        {:ok, data}

      {:ok, %{"tokens" => _} = flat} ->
        {:ok, legacy_codex_doc(flat)}

      {:ok, _other} ->
        preserve_and_refuse(path, raw, :unknown_shape)

      {:error, %Jason.DecodeError{} = err} ->
        preserve_and_refuse(path, raw, {:invalid_json, err})
    end
  end

  defp preserve_and_refuse(path, raw, reason) do
    backup = "#{path}.broken.#{System.system_time(:second)}"

    case File.write(backup, raw, [:binary]) do
      :ok ->
        _ = File.chmod(backup, 0o600)

        Logger.error(
          "Auth.Store: refusing to overwrite #{path} (#{inspect(reason)}); preserved at #{backup}"
        )

        {:error, {:malformed_auth_file, path, backup, reason}}

      {:error, write_err} ->
        Logger.error(
          "Auth.Store: refusing to overwrite #{path} (#{inspect(reason)}); backup also failed: #{inspect(write_err)}"
        )

        {:error, {:malformed_auth_file, path, nil, reason}}
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
    providers = Map.get(doc, "providers", %{})
    provider_key = provider_key(provider)
    existing = Map.get(providers, provider_key, %{})

    serialized =
      %{
        "auth_mode" => entry_value(entry, :auth_mode, "chatgpt"),
        "tokens" => %{
          "access_token" => entry.tokens.access_token,
          "refresh_token" => entry.tokens.refresh_token
        },
        "expires_at" => encode_datetime(entry_value(entry, :expires_at)),
        "last_refresh" => DateTime.to_iso8601(DateTime.utc_now())
      }
      |> put_serialized("provider", entry_value(entry, :provider))
      |> put_serialized("account", stringify_account(entry_value(entry, :account)))
      |> put_serialized("scope_profile", entry_value(entry, :scope_profile))
      |> put_serialized("granted_scopes", entry_value(entry, :granted_scopes, []))
      |> put_serialized("status", entry_value(entry, :status))

    providers = Map.put(providers, provider_key, Map.merge(existing, serialized))
    %{"version" => @schema_version, "providers" => providers}
  end

  defp remove_provider(%{"providers" => providers}, provider) when is_map(providers) do
    key = provider_key(provider)

    if Map.has_key?(providers, key) do
      {:ok, %{"version" => @schema_version, "providers" => Map.delete(providers, key)}}
    else
      {:error, {:provider_missing, provider}}
    end
  end

  defp remove_provider(_doc, _provider), do: {:error, :no_providers}

  defp provider_key(provider) when is_atom(provider), do: Atom.to_string(provider)
  defp provider_key(provider) when is_binary(provider), do: provider

  defp entry_value(entry, key, default \\ nil) when is_map(entry) do
    Map.get(entry, key, Map.get(entry, Atom.to_string(key), default))
  end

  defp encode_datetime(nil), do: nil
  defp encode_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp stringify_account(nil), do: nil

  defp stringify_account(account) when is_map(account) do
    Enum.into(account, %{}, fn {key, value} -> {account_key(key), value} end)
  end

  defp account_key(key) when is_atom(key), do: Atom.to_string(key)
  defp account_key(key) when is_binary(key), do: key

  defp put_serialized(map, _key, nil), do: map
  defp put_serialized(map, _key, []), do: map
  defp put_serialized(map, key, value), do: Map.put(map, key, value)

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
