defmodule FermixCore.Home.Snapshot.S3.Credentials do
  @moduledoc """
  The access keys the S3 target signs with: the secrets
  `snapshot_s3_access_key_id` and `snapshot_s3_secret_access_key`, stored
  through `secret.set` or setup and kept as references in
  `[fermix_core.snapshots]`. A value the settings load already resolved is
  used as it is; a reference the load could not resolve (its store was locked
  then) is read now from the store it names, through `SecretWriter`.
  """

  alias FermixCore.Setup.SecretWriter

  @type t :: %{access_key_id: String.t(), secret_access_key: String.t()}
  @type error :: {:keys_missing, atom()} | {:secret_unreadable, atom(), term()}

  @doc "The access keys `settings` name."
  @spec resolve(map()) :: {:ok, t()} | {:error, error()}
  def resolve(settings) when is_map(settings) do
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
end
