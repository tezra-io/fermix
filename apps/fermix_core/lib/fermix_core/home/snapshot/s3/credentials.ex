defmodule FermixCore.Home.Snapshot.S3.Credentials do
  @moduledoc """
  The credentials the S3 target signs with (`[fermix_core.snapshots]
  s3_credentials`).

  **`instance_profile`** (M75 B9). The engine never reaches the instance
  metadata address: the first boot blocks it for every process but root. A
  root timer (`packaging/cloud`, §13) reads the instance role's credentials
  and writes them to `#{"/run/fermix/aws-credentials.json"}`, readable by the
  engine's user, in the shape the metadata service answers:

      {"AccessKeyId": "ASIA…", "SecretAccessKey": "…", "Token": "…",
       "Expiration": "2026-10-27T15:00:00Z"}

  Other keys (`Code`, `LastUpdated`, `Type`) are ignored. The file is read at
  every upload, so a refreshed one is used at once; one that is missing,
  unreadable, not that shape, or expired (or expiring within a minute) is
  refused by name, never retried another way.

  **`keys`.** The secrets `snapshot_s3_access_key_id` and
  `snapshot_s3_secret_access_key`, stored through `secret.set` or setup and
  kept as references in the section. A value the settings load already
  resolved is used as it is; a reference the load could not resolve (its
  store was locked then) is read now from the store it names, through
  `SecretWriter`.
  """

  alias FermixCore.Setup.SecretWriter

  @instance_file "/run/fermix/aws-credentials.json"
  @max_file_bytes 65_536
  @expiry_margin_s 60

  @type t :: %{
          access_key_id: String.t(),
          secret_access_key: String.t(),
          session_token: String.t() | nil
        }
  @type error ::
          {:instance_credentials, :absent | :invalid | {:unreadable, term()}}
          | {:instance_credentials, {:expired, DateTime.t()}}
          | {:keys_missing, atom()}
          | {:secret_unreadable, atom(), term()}

  @doc "Where the root timer writes the instance role's credentials."
  @spec instance_file() :: Path.t()
  def instance_file, do: @instance_file

  @doc """
  The credentials `settings` name. `opts`: `:instance_credentials_file` (the
  file in place of `instance_file/0`, tests), `:now` (a 0-arity clock).
  """
  @spec resolve(map(), keyword()) :: {:ok, t()} | {:error, error()}
  def resolve(%{credentials: :instance_profile}, opts) when is_list(opts) do
    path = Keyword.get(opts, :instance_credentials_file, @instance_file)
    now = Keyword.get(opts, :now, &DateTime.utc_now/0).()

    with {:ok, contents} <- read_instance_file(path),
         {:ok, fields} <- instance_fields(contents) do
      current(fields, now)
    end
  end

  def resolve(%{credentials: :keys} = settings, opts) when is_list(opts) do
    with {:ok, access_key_id} <- key(:snapshot_s3_access_key_id, settings.access_key_id),
         {:ok, secret} <- key(:snapshot_s3_secret_access_key, settings.secret_access_key) do
      {:ok, %{access_key_id: access_key_id, secret_access_key: secret, session_token: nil}}
    end
  end

  defp read_instance_file(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_file_bytes ->
        read(path)

      {:ok, %File.Stat{}} ->
        {:error, {:instance_credentials, :invalid}}

      {:error, :enoent} ->
        {:error, {:instance_credentials, :absent}}

      {:error, reason} ->
        {:error, {:instance_credentials, {:unreadable, reason}}}
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {:instance_credentials, {:unreadable, reason}}}
    end
  end

  defp instance_fields(contents) do
    with {:ok,
          %{
            "AccessKeyId" => id,
            "SecretAccessKey" => secret,
            "Token" => token,
            "Expiration" => expiration
          }}
         when is_binary(id) and id != "" and is_binary(secret) and secret != "" and
                is_binary(token) and token != "" <- Jason.decode(contents),
         {:ok, expires_at, _offset} <- DateTime.from_iso8601(expiration) do
      {:ok,
       %{
         access_key_id: id,
         secret_access_key: secret,
         session_token: token,
         expires_at: expires_at
       }}
    else
      _invalid -> {:error, {:instance_credentials, :invalid}}
    end
  end

  defp current(%{expires_at: expires_at} = fields, now) do
    if DateTime.diff(expires_at, now) > @expiry_margin_s,
      do: {:ok, Map.delete(fields, :expires_at)},
      else: {:error, {:instance_credentials, {:expired, expires_at}}}
  end

  defp key(name, value) when value in [nil, ""], do: {:error, {:keys_missing, name}}

  defp key(name, value) when is_binary(value) do
    case SecretWriter.store_of_sentinel(value) do
      {:ok, store} -> stored(name, SecretWriter.get(name, store: store))
      :error -> {:ok, value}
    end
  end

  defp stored(_name, {:ok, value}) when is_binary(value) and value != "", do: {:ok, value}
  defp stored(name, {:ok, _empty}), do: {:error, {:keys_missing, name}}
  defp stored(name, {:error, reason}), do: {:error, {:secret_unreadable, name, reason}}
end
