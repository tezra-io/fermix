defmodule Fermix.CLI.Migrate.Journal do
  @moduledoc """
  The owner-only handoff record `fermix migrate-to-app` leaves for Fermix.app
  (M34 §4, Homebrew contract).

  One file at `~/Library/Application Support/Fermix/migration-journal.json` —
  outside any bundle, outside the Fermix home — written atomically with mode
  `0600`. It carries a versioned schema, the transaction id, the Fermix home the
  app must preserve, the inspected source facts, and the phase the transaction
  reached. The app reads it, preserves the same home, registers its agent,
  verifies the same data, and clears it.

  **The file appears at the handoff point, not before.** M34 orders the
  transaction so the journal is written once the verified plist is gone: that is
  the first moment the legacy owner no longer exists and a later launch has
  something to recover. Every failure before it leaves the legacy install intact
  and nothing to hand off, so there is no state worth persisting; `phases/0`
  still publishes the whole ordered vocabulary so a phase is validated against
  one list rather than spelled freshly at each call site.
  """

  @schema_version 1
  @filename "migration-journal.json"
  @dir_relative "Library/Application Support/Fermix"
  # `:sync` opens the temporary file `O_SYNC`, so its bytes are on the disk
  # before the rename that publishes them. Without it, APFS can complete the
  # rename while the contents are still in the page cache: a panic or power loss
  # then leaves a present-but-empty file at the final path, which `read/1`
  # reports as `:invalid_journal` — with the legacy install already dismantled
  # and no home recorded anywhere. (The directory entry itself cannot be fsynced
  # from the BEAM: `:file.open/2` refuses a directory. A lost rename leaves no
  # file at all, which reads as `:enoent`, not as a corrupt record.)
  @write_modes [:binary, :sync]

  # Ordered. Everything up to `handoff_written` happens while the legacy install
  # is still whole; only from there on is there a record on disk.
  @phases ~w(preflight prepared drained handoff_written formula_uninstalled cask_installed app_launched)
  @initial_phase "handoff_written"

  @type record :: %{String.t() => term()}

  @doc "The ordered phase vocabulary this journal accepts."
  @spec phases() :: [String.t()]
  def phases, do: @phases

  @doc "The journal's absolute path for this account."
  @spec path(keyword()) :: Path.t()
  def path(opts \\ []) when is_list(opts), do: Path.join(dir(opts), @filename)

  @doc "The file modes the record is written with, published so the fsync is testable."
  @spec write_modes() :: [atom()]
  def write_modes, do: @write_modes

  @doc """
  Writes the handoff record, replacing any record left by an earlier attempt.

  Returns the exact record persisted so the caller reports what the app will
  read rather than what it intended to write.
  """
  @spec write(record(), keyword()) :: {:ok, record()} | {:error, term()}
  def write(payload, opts \\ []) when is_map(payload) and is_list(opts) do
    now = timestamp(opts)

    record =
      payload
      |> Map.merge(%{
        "schema_version" => @schema_version,
        "transaction_id" => transaction_id(opts),
        "phase" => @initial_phase,
        "created_at" => now,
        "updated_at" => now
      })

    with :ok <- persist(record, opts), do: {:ok, record}
  end

  @doc """
  Advances the persisted record to `phase`.

  Refuses a phase outside `phases/0` — a typo would otherwise persist a state
  the application has no reconcile branch for, which is indistinguishable on
  disk from a transaction that never got there.
  """
  @spec advance(String.t(), keyword()) :: {:ok, record()} | {:error, term()}
  def advance(phase, opts \\ []) when is_binary(phase) and is_list(opts) do
    with :ok <- known_phase(phase),
         {:ok, record} <- read(opts) do
      updated = Map.merge(record, %{"phase" => phase, "updated_at" => timestamp(opts)})
      with :ok <- persist(updated, opts), do: {:ok, updated}
    end
  end

  @doc "Reads the persisted record, or `{:error, :enoent}` when there is none."
  @spec read(keyword()) :: {:ok, record()} | {:error, term()}
  def read(opts \\ []) when is_list(opts) do
    with {:ok, body} <- File.read(path(opts)),
         {:ok, record} when is_map(record) <- Jason.decode(body) do
      {:ok, record}
    else
      {:ok, _not_a_map} -> {:error, :invalid_journal}
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_journal}
      {:error, reason} -> {:error, reason}
    end
  end

  defp known_phase(phase) do
    if phase in @phases, do: :ok, else: {:error, {:unknown_phase, phase}}
  end

  # Owner-only and flushed before the rename, so the record never exists at its
  # final name in a world-readable mode, the reader never sees a partial file,
  # and the bytes are durable before the name that publishes them appears.
  defp persist(record, opts) do
    path = path(opts)
    tmp = "#{path}.tmp.#{System.unique_integer([:positive, :monotonic])}"
    body = Jason.encode!(record, pretty: true) <> "\n"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.chmod(Path.dirname(path), 0o700),
         :ok <- File.write(tmp, body, @write_modes),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, {:journal_write_failed, reason}}
    end
  end

  defp dir(opts) do
    Keyword.get_lazy(opts, :journal_dir, fn ->
      Path.join(Keyword.get_lazy(opts, :home, &System.user_home!/0), @dir_relative)
    end)
  end

  defp transaction_id(opts) do
    Keyword.get_lazy(opts, :transaction_id, fn ->
      12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    end)
  end

  defp timestamp(opts) do
    Keyword.get_lazy(opts, :now, fn -> DateTime.utc_now() |> DateTime.to_iso8601() end)
  end
end
