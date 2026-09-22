defmodule FermixCore.Setup.SecretMigration do
  @moduledoc """
  Explicit migration of setup secrets into the configured store.

  Two kinds of secret are moved, and both are shown by name and confirmed one
  by one: a plaintext value in `config.toml`, and a value the *other* store
  holds (a `@keyring` secret when the file store is configured, a `@file` one
  when the keyring is). Nothing else in Fermix moves a secret between stores,
  which is what lets each sentinel be believed. A secret the other store cannot
  currently give up — a locked keyring, say — stops the run by name rather
  than being skipped as if it had moved.
  """

  alias FermixCore.Sandbox.Config, as: SandboxConfig
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.SecretPaths
  alias FermixCore.Setup.SecretStore
  alias FermixCore.Setup.SecretWriteLog
  alias FermixCore.Setup.SecretWriter

  require Logger

  @type io_opts :: [puts: (String.t() -> any()), prompt: (String.t() -> String.t())]

  @spec run(keyword(), io_opts()) :: :ok | {:error, String.t()}
  def run(_opts \\ [], io_opts \\ []) do
    puts = Keyword.get(io_opts, :puts, &IO.puts/1)
    prompt = Keyword.get(io_opts, :prompt, &default_prompt/1)

    with {:ok, snapshot} <- ConfigStore.load_runtime_config(resolve_secrets: false),
         store = SecretWriter.store(),
         secrets = candidates(snapshot, store),
         :ok <- ensure_store_usable(secrets, store),
         :ok <- maybe_migrate(snapshot, secrets, store, puts, prompt) do
      :ok
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  @spec plaintext_secrets(ConfigStore.runtime_config()) :: [map()]
  def plaintext_secrets(snapshot) when is_map(snapshot),
    do: SecretStore.plaintext_secrets(snapshot)

  # Every secret that is not where new secrets go: plaintext carries its value;
  # one in the other store carries the store to read it from.
  defp candidates(snapshot, store) do
    plaintext = Enum.map(plaintext_secrets(snapshot), &Map.put(&1, :from, :plaintext))

    elsewhere =
      SecretPaths.all()
      |> Enum.flat_map(fn secret ->
        case SecretWriter.store_of_sentinel(SecretStore.get_snapshot_value(snapshot, secret.path)) do
          {:ok, ^store} -> []
          {:ok, other} -> [Map.put(secret, :from, other)]
          :error -> []
        end
      end)

    plaintext ++ elsewhere
  end

  defp ensure_store_usable([], _store), do: :ok

  defp ensure_store_usable(secrets, store) do
    verdict = SecretWriter.probe(store: store)

    if SecretWriter.usable?(verdict) do
      ensure_sources_readable(secrets)
    else
      {:error, "The #{store} store cannot take secrets right now: #{verdict.sentence}."}
    end
  end

  # A secret in the other store has to be read before it can be moved, and a
  # locked keyring is refused up front rather than raising its dialog once per
  # secret.
  defp ensure_sources_readable(secrets) do
    secrets
    |> Enum.map(& &1.from)
    |> Enum.reject(&(&1 == :plaintext))
    |> Enum.uniq()
    |> Enum.find_value(:ok, fn from ->
      verdict = SecretWriter.probe(store: from)

      if SecretWriter.usable?(verdict),
        do: nil,
        else: {:error, "The #{from} store cannot be read right now: #{verdict.sentence}."}
    end)
  end

  defp maybe_migrate(_snapshot, [], store, puts, _prompt) do
    puts.("No setup secrets to move: every stored secret is already in the #{store} store.")
    :ok
  end

  defp maybe_migrate(snapshot, secrets, store, puts, prompt) do
    with :ok <- backup_config() do
      migrate_secrets(snapshot, secrets, store, puts, prompt)
    end
  end

  defp migrate_secrets(snapshot, secrets, store, puts, prompt) do
    initial = {:ok, snapshot, []}

    case Enum.reduce_while(secrets, initial, &migrate_one(&1, &2, store, puts, prompt)) do
      {:ok, updated, migrated} -> save_migrated_snapshot(updated, migrated, store, puts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp save_migrated_snapshot(snapshot, migrated, store, puts) do
    case ConfigStore.save_snapshot(snapshot, secure_secrets: false) do
      :ok ->
        puts.("Moved #{length(migrated)} secret(s) to the #{store} store.")
        :ok

      {:error, reason} ->
        {:error, "failed to save migrated config: #{inspect(reason)}"}
    end
  end

  defp migrate_one(secret, {:ok, snapshot, migrated}, store, puts, prompt) do
    if confirm?(
         prompt,
         "Move #{secret.env} (#{describe(secret.from)}) to the #{store} store? [y/N]: "
       ) do
      move(secret, snapshot, migrated, store, puts)
    else
      puts.("Skipped #{secret.env}.")
      {:cont, {:ok, snapshot, migrated}}
    end
  end

  defp move(secret, snapshot, migrated, store, puts) do
    with {:ok, value} <- read_source(secret),
         :ok <- SecretWriteLog.put(secret.key, value, store: store) do
      forget_source(secret)
      puts.("Moved #{secret.env}.")

      updated =
        snapshot
        |> SecretStore.put_snapshot_value(secret.path, SecretWriter.sentinel_for(store))
        |> maybe_add_sandbox_env_source(secret)

      {:cont, {:ok, updated, [secret.key | migrated]}}
    else
      {:error, reason} -> {:halt, {:error, SecretWriter.format_error(secret.key, reason)}}
    end
  end

  defp read_source(%{from: :plaintext, value: value}), do: {:ok, value}
  defp read_source(%{from: store, key: key}), do: SecretWriter.get(key, store: store)

  # The copy left behind in the store a secret came from is removed; when it
  # cannot be, the move still happened and the log says what remains.
  defp forget_source(%{from: :plaintext}), do: :ok

  defp forget_source(%{from: store, key: key, env: env}) do
    case SecretWriter.delete(key, store: store) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "#{env} moved, but its copy in the #{store} store could not be removed: #{inspect(reason)}"
        )
    end
  end

  defp describe(:plaintext), do: "plaintext in config.toml"
  defp describe(store), do: "in the #{store} store"

  defp maybe_add_sandbox_env_source(snapshot, secret) do
    if Map.get(secret, :sandbox_env, false) do
      sandbox = SandboxConfig.normalize(Map.get(snapshot, :sandbox))

      allow =
        if secret.env in sandbox.env.allow,
          do: sandbox.env.allow,
          else: sandbox.env.allow ++ [secret.env]

      sources =
        Map.put_new(sandbox.env.sources, secret.env, SecretWriter.command_source(secret.key))

      updated_env = %{sandbox.env | allow: allow, sources: sources}
      Map.put(snapshot, :sandbox, %{sandbox | env: updated_env})
    else
      snapshot
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

    case IO.gets("") do
      :eof -> ""
      {:error, _reason} -> ""
      value -> value
    end
  end
end
