defmodule FermixCore.Setup.SecretMigration do
  @moduledoc """
  Explicit migration from plaintext setup secrets to the OS secret store.
  """

  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.SecretPaths
  alias FermixCore.Setup.SecretWriter

  @type io_opts :: [puts: (String.t() -> any()), prompt: (String.t() -> String.t())]

  @spec run(keyword(), io_opts()) :: :ok | {:error, String.t()}
  def run(_opts \\ [], io_opts \\ []) do
    puts = Keyword.get(io_opts, :puts, &IO.puts/1)
    prompt = Keyword.get(io_opts, :prompt, &default_prompt/1)

    with {:ok, snapshot} <- ConfigStore.load_runtime_config(resolve_secrets: false),
         secrets <- plaintext_secrets(snapshot),
         :ok <- ensure_writer_available(secrets),
         :ok <- maybe_migrate(snapshot, secrets, puts, prompt) do
      :ok
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  @spec plaintext_secrets(ConfigStore.runtime_config()) :: [map()]
  def plaintext_secrets(snapshot) when is_map(snapshot) do
    SecretPaths.all()
    |> Enum.flat_map(fn secret ->
      case get_snapshot_value(snapshot, secret.path) do
        value when is_binary(value) and value not in ["", "@keyring"] ->
          [Map.put(secret, :value, value)]

        _other ->
          []
      end
    end)
  end

  defp ensure_writer_available([]), do: :ok

  defp ensure_writer_available(_secrets) do
    if SecretWriter.available?() do
      :ok
    else
      {:error, "No OS secret writer is available. Set secrets in shell rc, systemd unit, or launchd plist."}
    end
  end

  defp maybe_migrate(_snapshot, [], puts, _prompt) do
    puts.("No plaintext setup secrets found.")
    :ok
  end

  defp maybe_migrate(snapshot, secrets, puts, prompt) do
    with :ok <- backup_config() do
      migrate_secrets(snapshot, secrets, puts, prompt)
    end
  end

  defp migrate_secrets(snapshot, secrets, puts, prompt) do
    case Enum.reduce_while(secrets, {:ok, snapshot, []}, &migrate_one(&1, &2, puts, prompt)) do
      {:ok, updated, migrated} ->
        save_migrated_snapshot(updated, migrated, puts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp save_migrated_snapshot(snapshot, migrated, puts) do
    case ConfigStore.save_snapshot(snapshot) do
      :ok ->
        puts.("Migrated #{length(migrated)} secret(s) to keyring.")
        :ok

      {:error, reason} ->
        {:error, "failed to save migrated config: #{inspect(reason)}"}
    end
  end

  defp migrate_one(secret, {:ok, snapshot, migrated}, puts, prompt) do
    if confirm?(prompt, "Migrate #{secret.env} to the OS keyring? [y/N]: ") do
      case SecretWriter.put(secret.key, secret.value) do
        :ok ->
          puts.("Migrated #{secret.env}.")
          updated = put_snapshot_value(snapshot, secret.path, SecretWriter.sentinel())
          {:cont, {:ok, updated, [secret.key | migrated]}}

        {:error, reason} ->
          {:halt, {:error, SecretWriter.format_error(secret.key, reason)}}
      end
    else
      puts.("Skipped #{secret.env}.")
      {:cont, {:ok, snapshot, migrated}}
    end
  end

  defp backup_config do
    source = ConfigStore.path()
    target = source <> ".pre-m5"

    cond do
      not File.exists?(source) -> :ok
      File.exists?(target) -> :ok
      true -> File.cp(source, target)
    end
  end

  defp confirm?(prompt, label) do
    prompt.(label)
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> case do
      "y" -> true
      "yes" -> true
      _other -> false
    end
  end

  defp default_prompt(label) do
    IO.write(label)
    IO.gets("") || ""
  end

  defp get_snapshot_value(snapshot, [root | rest]) do
    snapshot
    |> Map.get(root, [])
    |> get_keyword_value(rest)
  end

  defp get_keyword_value(keyword, [key]) when is_list(keyword), do: Keyword.get(keyword, key)

  defp get_keyword_value(keyword, [key | rest]) when is_list(keyword) do
    keyword
    |> Keyword.get(key, [])
    |> get_keyword_value(rest)
  end

  defp get_keyword_value(_value, _path), do: nil

  defp put_snapshot_value(snapshot, [root | rest], value) do
    section = Map.get(snapshot, root, [])
    Map.put(snapshot, root, put_keyword_value(section, rest, value))
  end

  defp put_keyword_value(keyword, [key], value) when is_list(keyword) do
    Keyword.put(keyword, key, value)
  end

  defp put_keyword_value(keyword, [key | rest], value) when is_list(keyword) do
    nested = Keyword.get(keyword, key, [])
    Keyword.put(keyword, key, put_keyword_value(nested, rest, value))
  end
end
