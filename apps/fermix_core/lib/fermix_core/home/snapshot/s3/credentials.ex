defmodule FermixCore.Home.Snapshot.S3.Credentials do
  @moduledoc """
  What the S3 target signs with, as `[fermix_core.snapshots]` says
  (`Snapshot.Config`): one way per setting, never the other when it fails.

  **Access keys** (no `s3_credentials`): the secrets
  `snapshot_s3_access_key_id` and `snapshot_s3_secret_access_key`, kept as
  references in the section. A value the settings load already resolved is
  used as it is; a reference the load could not resolve (its store was locked
  then) is read now from the store it names, through `SecretWriter`.

  **The instance role's session** (`s3_credentials = "instance_role"`, E1):
  on an Always On server whose infrastructure set the bucket. The engine's
  account never reaches the instance metadata service (first boot lets root
  alone), so root's credentials helper (`fermix-snapshot-credentials.timer`,
  every 15 minutes) assumes the snapshot writer role and writes its one-hour
  session to `credentials.json` in `/run/fermix-snapshots`, readable by this
  account and written by root alone, and its last failure's one sentence to
  `error` beside it. The session is read at each upload, with the account it
  belongs to (`account_id`), which the target names as the bucket's expected
  owner. One that runs out within a minute is not used.
  """

  alias FermixCore.Setup.SecretWriter

  @session_dir "/run/fermix-snapshots"
  @session_file "credentials.json"
  @error_file "error"
  @max_file_bytes 16_384
  @max_said_bytes 600
  @expiry_margin_s 60
  @fields ~w(access_key_id secret_access_key session_token expiration account_id)

  @type t :: %{
          required(:access_key_id) => String.t(),
          required(:secret_access_key) => String.t(),
          optional(:session_token) => String.t(),
          optional(:account_id) => String.t()
        }
  @type error ::
          {:keys_missing, atom()}
          | {:secret_unreadable, atom(), term()}
          | {:session_missing, String.t() | nil}
          | {:session_unreadable, File.posix()}
          | :session_malformed
          | {:session_expired, DateTime.t(), String.t() | nil}

  @doc "Where root's credentials helper writes the instance role's session."
  @spec session_dir() :: Path.t()
  def session_dir, do: @session_dir

  @doc """
  What `settings` sign with. `opts`: `:now` (a 0-arity clock) and
  `:session_dir` (the helper's directory, for a test).
  """
  @spec resolve(map(), keyword()) :: {:ok, t()} | {:error, error()}
  def resolve(settings, opts \\ [])

  def resolve(%{credentials: :instance_role}, opts) when is_list(opts), do: session(opts)

  def resolve(%{credentials: :access_keys} = settings, opts) when is_list(opts) do
    with {:ok, access_key_id} <- key(:snapshot_s3_access_key_id, settings.access_key_id),
         {:ok, secret} <- key(:snapshot_s3_secret_access_key, settings.secret_access_key) do
      {:ok, %{access_key_id: access_key_id, secret_access_key: secret}}
    end
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

  # -- the instance role's session ---------------------------------------------

  defp session(opts) do
    dir = Keyword.get(opts, :session_dir, @session_dir)
    now = Keyword.get(opts, :now, &DateTime.utc_now/0).()

    with {:ok, text} <- read_session(dir),
         {:ok, session} <- decode(text) do
      fresh(session, now, dir)
    end
  end

  defp read_session(dir) do
    case read_small(Path.join(dir, @session_file)) do
      {:ok, text} -> {:ok, text}
      {:error, :enoent} -> {:error, {:session_missing, helper_said(dir)}}
      {:error, :too_large} -> {:error, :session_malformed}
      {:error, reason} -> {:error, {:session_unreadable, reason}}
    end
  end

  defp read_small(path) do
    case File.read(path) do
      {:ok, text} when byte_size(text) <= @max_file_bytes -> {:ok, text}
      {:ok, _text} -> {:error, :too_large}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode(text) do
    with {:ok, %{} = fields} <- Jason.decode(text),
         true <- Enum.all?(@fields, &valid?(&1, Map.get(fields, &1))),
         {:ok, expiration, 0} <- DateTime.from_iso8601(fields["expiration"]) do
      {:ok,
       %{
         access_key_id: fields["access_key_id"],
         secret_access_key: fields["secret_access_key"],
         session_token: fields["session_token"],
         account_id: fields["account_id"],
         expiration: expiration
       }}
    else
      _not_the_helpers -> {:error, :session_malformed}
    end
  end

  defp valid?("account_id", value), do: is_binary(value) and value =~ ~r/\A[0-9]{12}\z/

  defp valid?(_field, value),
    do: is_binary(value) and value != "" and value =~ ~r/\A[\x21-\x7E]+\z/

  defp fresh(%{expiration: expiration} = session, now, dir) do
    if DateTime.diff(expiration, now, :second) > @expiry_margin_s,
      do: {:ok, Map.delete(session, :expiration)},
      else: {:error, {:session_expired, expiration, helper_said(dir)}}
  end

  # The helper's last failure in its own words: one line, bounded, or nil.
  defp helper_said(dir) do
    case read_small(Path.join(dir, @error_file)) do
      {:ok, text} -> said(text)
      {:error, _absent} -> nil
    end
  end

  defp said(text) do
    line = text |> String.split("\n", parts: 2) |> hd() |> String.trim()

    cond do
      line == "" or not String.printable?(line) -> nil
      byte_size(line) <= @max_said_bytes -> line
      true -> String.slice(line, 0, @max_said_bytes) <> "…"
    end
  end
end
