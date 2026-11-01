defmodule Fermix.CLI.HomeCommand do
  @moduledoc """
  `fermix home`: carry a home to another host (M75).

      fermix home export FILE [--passphrase-file PATH] [--mark-moved --to TEXT]
      fermix home import FILE --into ROOT [--passphrase-file PATH]
      fermix home mark-moved --to TEXT [--json]
      fermix home status [--json]
      fermix home snapshots status [--json]
      fermix home snapshots passphrase --passphrase-file PATH [--json]
      fermix home enroll --code-file PATH [--snapshot-bucket B --snapshot-region R]
      fermix home candidates [--json]

  `export` archives the home this command runs against (`FERMIX_HOME`, default
  `~/.fermix`) into `FILE`, sealed under a passphrase (`FermixCore.Home.Archive`).
  It refuses while the engine that owns the home is running. With
  `--mark-moved --to TEXT` it also writes the moved marker
  (`FermixCore.Home.Moved.write/2`) right after the archive is sealed, so an
  engine a service relaunches between two commands can never run the old home
  as the primary again. `import` restores an archive into an empty `ROOT` as
  the next primary, one epoch above the archived home, and says what it changed
  and what the owner must redo on this host. It never marks anything moved;
  `mark-moved` (`Fermix.CLI.HomeMovedCommand`) is the step on its own.
  `import` also takes a snapshot (`FXSNAP1`, `FermixCore.Home.Snapshot`), told
  by its magic: the passphrase is then the recovery passphrase, and the key is
  derived from it and the salt the snapshot's header carries. `status` and
  `snapshots` are `Fermix.CLI.HomeStatusCommand`; `enroll` and `candidates`
  are `Fermix.CLI.HomeMoveCommand`.

  The passphrase never enters argv. It is read from `--passphrase-file` (one
  line; a trailing newline is dropped) or asked for on the terminal without
  echo, twice on export so a typing slip cannot seal an archive nobody can
  open. With no terminal and no file the verb refuses rather than reading an
  unmasked line.

  Exit status follows the CLI contract: `0` done, `1` refused (one sentence on
  stderr), `2` usage error. `export` and `import` are human-mode only; they
  print no machine envelope.
  """

  alias Fermix.CLI.HomeMoveCommand
  alias Fermix.CLI.HomeMovedCommand
  alias Fermix.CLI.HomeStatusCommand
  alias Fermix.CLI.SecretInput
  alias FermixCore.Home.Archive
  alias FermixCore.Home.Moved
  alias FermixCore.Home.Snapshot
  alias FermixCore.Home.Snapshot.Format
  alias FermixCore.Home.Snapshot.Recipient
  alias FermixCore.Setup.ConfigStore

  @export_switches [passphrase_file: :string, mark_moved: :boolean, to: :string]
  @import_switches [into: :string, passphrase_file: :string]
  @move_verbs ~w(enroll candidates)
  @max_passphrase_file_bytes 4_096
  @moved "Start the engine here; the old home must be marked moved before it runs again."

  @doc "Runs `fermix home` with the real home, terminal and daemon probe."
  @spec run([String.t()]) :: non_neg_integer()
  def run(argv) when is_list(argv), do: run(argv, [])

  @doc """
  Runs `fermix home` with injected dependencies: `:home` (the home `export`
  archives), `:terminal` (the `Fermix.CLI.SecretInput` terminal), `:hello`
  (the daemon probe), `:now` (a 0-arity clock for the moved marker), and the
  host facts `FermixCore.Home.Archive.restore/4` takes (`:host`,
  `:keyring_usable?`, `:now_ms`).
  """
  @spec run([String.t()], keyword()) :: non_neg_integer()
  def run(argv, deps) when is_list(argv) and is_list(deps) do
    case argv do
      ["export" | rest] -> export(rest, deps)
      ["import" | rest] -> import_archive(rest, deps)
      ["mark-moved" | rest] -> HomeMovedCommand.run(rest, Keyword.take(deps, [:home, :hello]))
      ["status" | rest] -> HomeStatusCommand.status(rest, status_deps(deps))
      ["snapshots" | rest] -> HomeStatusCommand.snapshots(rest, status_deps(deps))
      [verb | rest] when verb in @move_verbs -> HomeMoveCommand.run(verb, rest, move_deps(deps))
      _other -> usage()
    end
  end

  defp status_deps(deps), do: Keyword.take(deps, [:home, :client, :terminal, :app_managed?])

  defp move_deps(deps), do: Keyword.take(deps, [:home, :client, :now])

  defp export(argv, deps) do
    case OptionParser.parse(argv, strict: @export_switches) do
      {opts, [file], []} -> export_marking(Path.expand(file), opts, deps)
      _invalid -> usage()
    end
  end

  # `--to` names where the home went, so it belongs with `--mark-moved` and
  # with nothing else.
  defp export_marking(file, opts, deps) do
    case {Keyword.get(opts, :mark_moved, false), Keyword.get(opts, :to)} do
      {true, to} when is_binary(to) -> run_export(file, opts, {:mark_moved, to}, deps)
      {false, nil} -> run_export(file, opts, :no_mark, deps)
      _half -> usage()
    end
  end

  defp run_export(file, opts, mark, deps) do
    home = Path.expand(Keyword.get_lazy(deps, :home, &ConfigStore.fermix_home/0))
    archive_opts = [to: file] ++ Keyword.take(deps, [:hello, :host])

    with :ok <- not_moved_yet(home, mark),
         {:ok, passphrase} <- export_passphrase(opts, deps),
         {:ok, created} <- Archive.create(home, passphrase, archive_opts) do
      IO.puts("Exported #{home} to #{created.path}")
      IO.puts("  bytes: #{created.bytes}")
      IO.puts("  files: #{created.files}")
      IO.puts("  primary epoch: #{created.epoch}")
      print_keyring(created.keyring_secrets, "This home keeps", "on the new host")
      mark_moved(home, created, mark, deps) |> passphrase_note(opts)
    else
      {:error, reason} -> refuse(reason, home)
    end
  end

  defp not_moved_yet(_home, :no_mark), do: :ok

  defp not_moved_yet(home, {:mark_moved, _to}) do
    case Moved.read(home) do
      :absent -> :ok
      {:ok, marker} -> {:error, {:already_moved, marker}}
      {:error, _reason} = error -> error
    end
  end

  defp mark_moved(_home, _created, :no_mark, _deps), do: 0

  defp mark_moved(home, created, {:mark_moved, to}, deps) do
    moved_at = DateTime.truncate(Keyword.get(deps, :now, &DateTime.utc_now/0).(), :second)

    case Moved.write(home, %{epoch: created.epoch, moved_at: moved_at, to: to}) do
      :ok ->
        IO.puts("Marked #{home} moved to #{to} at epoch #{created.epoch}.")
        0

      {:error, reason} ->
        refuse({:not_marked, created.path, reason}, home)
    end
  end

  # The file holds the owner root, so the owner hears once that it outlives the
  # move unless they remove it.
  defp passphrase_note(status, opts) do
    case Keyword.fetch(opts, :passphrase_file) do
      {:ok, path} ->
        IO.puts(
          "The passphrase file #{Path.expand(path)} holds the owner root: remove it, or keep " <>
            "it protected, once the move is done."
        )

      :error ->
        :ok
    end

    status
  end

  defp import_archive(argv, deps) do
    case OptionParser.parse(argv, strict: @import_switches) do
      {opts, [file], []} -> run_import(Path.expand(file), opts, deps)
      _invalid -> usage()
    end
  end

  defp run_import(file, opts, deps) do
    case Keyword.fetch(opts, :into) do
      {:ok, into} -> restore(file, Path.expand(into), opts, deps)
      :error -> usage()
    end
  end

  # A snapshot (`FXSNAP1`) is told from an archive by its magic, and restored
  # with the recovery key its passphrase and the header's salt derive; anything
  # else is an archive, as it always was.
  defp restore(file, root, opts, deps) do
    restore_opts = Keyword.take(deps, [:host, :keyring_usable?, :now_ms])
    kind = if Format.snapshot?(file), do: :snapshot, else: :archive

    with {:ok, passphrase} <- passphrase(opts, deps, kind),
         {:ok, restored} <- restore_kind(kind, file, passphrase, root, restore_opts) do
      IO.puts("Restored #{restored.files} files into #{root} at primary epoch #{restored.epoch}.")
      print_restored(restored)
      passphrase_note(0, opts)
      IO.puts(@moved)
      0
    else
      {:error, reason} -> refuse(reason, root)
    end
  end

  defp print_restored(restored) do
    print_rewritten(restored.rewritten)
    print_kept_paths(restored.kept_paths)

    if restored.harness_consent_reset,
      do: IO.puts("Coding-harness consent does not travel; approve it again here.")

    if restored.secret_store_switched do
      IO.puts(
        ~s(This host has no usable keyring, so secrets are kept in files here: secret_store = "file".)
      )
    end

    if restored.imessage_disabled,
      do: IO.puts("iMessage needs a Mac, so it is turned off here.")

    print_keyring(restored.keyring_secrets, "The archived home kept", "on this host")
    print_screen_history(restored.screen_history_removed)
    print_reinstall(restored)
  end

  defp print_kept_paths([]), do: :ok

  defp print_kept_paths(keys) do
    IO.puts(
      "Kept as they were; review them, they hold paths outside the old home: " <>
        Enum.join(keys, ", ") <> "."
    )
  end

  defp print_screen_history(0), do: :ok

  defp print_screen_history(rows) do
    IO.puts(
      "Removed #{count(rows, "screen-history row")}: screen history stays on the machine " <>
        "it describes."
    )
  end

  defp print_reinstall(%{plugins_to_reinstall: []}), do: :ok

  defp print_reinstall(%{plugins_to_reinstall: names, source_host: from, host: host}) do
    IO.puts("Installed plugins were built for #{from}, and this host is #{host}. Reinstall each:")
    Enum.each(names, &IO.puts("  fermix plugins install #{&1}"))
  end

  defp print_rewritten([]), do: :ok

  defp print_rewritten(keys) do
    IO.puts(
      "Rewrote #{count(length(keys), "path")} in config.toml: " <>
        Enum.join(Enum.uniq(keys), ", ") <> "."
    )
  end

  defp print_keyring(0, _subject, _where), do: :ok

  defp print_keyring(secrets, subject, where) do
    IO.puts(
      "#{subject} #{count(secrets, "secret")} in the OS keyring; the archive carries only " <>
        "their references, so enter them again #{where}."
    )
  end

  defp count(1, noun), do: "1 #{noun}"
  defp count(n, noun), do: "#{n} #{noun}s"

  defp export_passphrase(opts, deps) do
    case Keyword.fetch(opts, :passphrase_file) do
      {:ok, path} -> read_passphrase_file(Path.expand(path))
      :error -> ask_twice(deps)
    end
  end

  defp passphrase(opts, deps, kind) do
    case Keyword.fetch(opts, :passphrase_file) do
      {:ok, path} -> read_passphrase_file(Path.expand(path))
      :error -> ask(prompt(kind), deps)
    end
  end

  defp prompt(:archive), do: "Archive passphrase"
  defp prompt(:snapshot), do: "Recovery passphrase"

  defp restore_kind(:archive, file, passphrase, root, opts),
    do: Archive.restore(file, passphrase, root, opts)

  defp restore_kind(:snapshot, file, passphrase, root, opts) do
    with {:ok, header} <- Format.peek_header(file),
         {:ok, pair} <- Recipient.derive(passphrase, header.salt) do
      Snapshot.restore(file, pair, root, opts)
    end
  end

  defp ask_twice(deps) do
    with {:ok, first} <- ask("Archive passphrase", deps),
         {:ok, second} <- ask("Repeat the passphrase", deps) do
      if first == second, do: {:ok, first}, else: {:error, :passphrases_differ}
    end
  end

  defp ask(label, deps) do
    case SecretInput.read_masked(label, Keyword.take(deps, [:terminal])) do
      {:ok, value} -> {:ok, value}
      {:error, :not_a_terminal} -> {:error, :no_passphrase_source}
      {:error, reason} -> {:error, {:passphrase_prompt, reason}}
    end
  end

  @doc """
  Reads a passphrase file: one line of at most #{@max_passphrase_file_bytes}
  bytes, a trailing newline dropped. Shared by every `fermix home` verb that
  takes `--passphrase-file`.
  """
  @spec read_passphrase_file(Path.t()) :: {:ok, binary()} | {:error, term()}
  def read_passphrase_file(path) when is_binary(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_passphrase_file_bytes ->
        read_passphrase(path)

      {:ok, %File.Stat{}} ->
        {:error, {:passphrase_file_unusable, path}}

      {:error, reason} ->
        {:error, {:passphrase_file, path, reason}}
    end
  end

  defp read_passphrase(path) do
    case File.read(path) do
      {:ok, contents} ->
        {:ok, contents |> String.replace_suffix("\n", "") |> String.replace_suffix("\r", "")}

      {:error, reason} ->
        {:error, {:passphrase_file, path, reason}}
    end
  end

  @doc "The sentence for a passphrase that could not be read, from a file or a terminal."
  @spec passphrase_sentence(term()) :: String.t()
  def passphrase_sentence(reason), do: sentence(reason, "")

  defp refuse(reason, root) do
    IO.puts(:stderr, "fermix home: " <> sentence(reason, root))
    1
  end

  # One sentence per refusal, written for the person at the terminal: what
  # happened and what they can do.
  defp sentence(:passphrase_too_short, _root),
    do: "The passphrase must be at least 12 bytes long. Nothing was written."

  defp sentence(:passphrases_differ, _root),
    do: "The two passphrases differ, so nothing was written. Run the export again."

  defp sentence(:no_passphrase_source, _root),
    do: "There is no terminal to ask for the passphrase on. Pass --passphrase-file PATH."

  defp sentence({:passphrase_prompt, reason}, _root),
    do: "The passphrase could not be read from the terminal (#{inspect(reason)})."

  defp sentence({:passphrase_file, path, reason}, _root),
    do: "The passphrase file #{path} could not be read: #{describe(reason)}."

  defp sentence({:passphrase_file_unusable, path}, _root) do
    "The passphrase file #{path} is not a regular file of at most " <>
      "#{@max_passphrase_file_bytes} bytes."
  end

  defp sentence(:daemon_running, _root) do
    "The engine that owns this home is running, and an archive of a running home can catch " <>
      "its database mid-write. Stop the engine, then export again."
  end

  defp sentence({:daemon_probe_failed, reason}, _root) do
    "Fermix could not tell whether the engine that owns this home is running " <>
      "(#{inspect(reason)}). Make sure it is stopped, then export again."
  end

  defp sentence(:epoch_absent, _root),
    do: "The home has no primary epoch: it has never started as the primary."

  defp sentence({:destination_exists, path}, _root),
    do: "#{path} already exists. Name a new file; an archive never replaces another."

  defp sentence({:destination_inside_home, path}, _root),
    do: "#{path} is inside the home being exported. Write the archive outside the home."

  defp sentence({:already_moved, %{to: to, epoch: epoch}}, _root) do
    "This home already moved to #{to} at epoch #{epoch}, so it is not exported again as " <>
      "the primary."
  end

  defp sentence({:home_moved, %{to: to, moved_at: %DateTime{} = at, epoch: epoch}}, _root) do
    "This home moved to #{to} on #{Date.to_iso8601(DateTime.to_date(at))} at epoch #{epoch}; " <>
      "a retired copy cannot be exported as a primary."
  end

  defp sentence({:moved_marker_unreadable, reason}, _root) do
    "This home's moved marker could not be read (#{inspect(reason)}), so it cannot be " <>
      "exported as a primary."
  end

  defp sentence({:not_marked, path, reason}, _root) do
    "The archive was written to #{path}, but this home was not marked moved " <>
      "(#{inspect(reason)}). Run fermix home mark-moved --to TEXT before it runs again."
  end

  defp sentence({:screen_history_remaining, rows}, _root) do
    "The archive's screen history holds #{rows} rows stamped after this host's clock, so it " <>
      "was not cleared. Check this host's clock. Nothing was written."
  end

  defp sentence({:screen_history, reason}, _root),
    do: "Screen history could not be cleared from the restored database (#{inspect(reason)})."

  defp sentence({:plugin_lockfile, reason}, _root) do
    "The archive's plugin lockfile could not be read (#{inspect(reason)}). Nothing was written."
  end

  defp sentence({:host_unsupported, reason}, _root),
    do: "This host's OS or architecture is not one Fermix runs on (#{inspect(reason)})."

  defp sentence({:stale_partial, path}, _root) do
    "#{path} was left by an export that stopped part-way and may hold this home " <>
      "unencrypted. Delete it, then export again."
  end

  defp sentence({:home_not_found, root}, _root), do: "There is no Fermix home at #{root}."

  defp sentence({:too_many_files, count, max}, _root),
    do: "The home holds #{count} files or more, beyond the #{max} one archive carries."

  defp sentence({:too_many_bytes, bytes, max}, _root),
    do: "The home holds #{bytes} bytes or more, beyond the #{max} one archive carries."

  defp sentence({:unsupported_entry, path, type}, _root) do
    "#{path} in the home is a #{type}, which an archive cannot carry. Move it out of the " <>
      "home, then export again."
  end

  defp sentence({:unsupported_link, path, target}, _root) do
    "#{path} in the home links to #{target}, outside the home, which an archive cannot " <>
      "carry. Move it out of the home, then export again."
  end

  defp sentence({:unsupported_name, path}, _root),
    do: "#{inspect(path)} in the home has a name an archive cannot carry. Rename it."

  defp sentence({:too_deep, path}, _root),
    do: "#{path} in the home is nested too deep for an archive."

  defp sentence({:changed_during_export, path}, _root) do
    "#{path} changed while it was being archived. Make sure nothing runs on this home, " <>
      "then export again."
  end

  defp sentence(:wrong_key, _root) do
    "The passphrase does not open this snapshot: it was encrypted to another recovery key. " <>
      "Nothing was written."
  end

  defp sentence(:snapshot_rejected, _root) do
    "The snapshot did not open: it was changed, cut at a chunk or put together out of order. " <>
      "Nothing was written."
  end

  defp sentence(:snapshot_truncated, _root),
    do: "The snapshot ends before its last chunk: the copy is incomplete. Nothing was written."

  defp sentence({:invalid_snapshot, detail}, _root) do
    "The snapshot opened, but it is not a home this engine can restore (#{detail}). " <>
      "Nothing was written."
  end

  defp sentence({:unsupported_version, version}, _root) do
    "The snapshot is format version #{version}, which this engine does not read. Nothing was " <>
      "written."
  end

  defp sentence({:invalid_header, field}, _root),
    do: "The snapshot's header is not one Fermix wrote (#{field}). Nothing was written."

  defp sentence(:archive_rejected, _root) do
    "The archive did not open: the passphrase is wrong, or the file is not a Fermix home " <>
      "archive, or it was changed. Nothing was written."
  end

  defp sentence(:root_not_empty, root),
    do: "#{root} is not empty. Import into an empty directory or a path that does not exist."

  defp sentence({:root_not_directory, root}, _root), do: "#{root} exists and is not a directory."

  defp sentence({:archive_too_large, size, max}, _root),
    do: "The archive is #{size} bytes, beyond the #{max} this engine opens."

  defp sentence(:epoch_overflow, _root) do
    "The archive is at the highest primary epoch there is, so it cannot become a new " <>
      "primary. Nothing was written."
  end

  defp sentence({:newer_engine, theirs, ours}, _root) do
    "Fermix #{theirs} wrote this home, and this is Fermix #{ours}: update Fermix here first, " <>
      "then restore it. Nothing was written."
  end

  defp sentence({kind, path}, _root)
       when kind in [:corrupt_entry, :missing_entry, :unsafe_path, :device_local_entry] do
    "The archive's entry #{inspect(path)} is not one a restore can write (#{kind}). " <>
      "Nothing was written."
  end

  defp sentence({:unsafe_link, path, target}, _root) do
    "The archive's link #{inspect(path)} to #{inspect(target)} could lead out of the home. " <>
      "Nothing was written."
  end

  defp sentence({:unlisted_entry, name}, _root),
    do:
      "The archive carries #{inspect(name)}, which its manifest does not list. Nothing was written."

  defp sentence({kind, detail}, _root)
       when kind in [:invalid_manifest, :unsupported_format, :invalid_tar] do
    "The archive opened, but it is not a home this engine can restore (#{kind}: " <>
      "#{inspect(detail)}). Nothing was written."
  end

  defp sentence({:config_not_rewritable, :multiline_string}, _root) do
    "The archive's config.toml uses a multi-line string, so the paths in it that name the " <>
      "old home cannot be moved safely. Nothing was written."
  end

  defp sentence({:file, path, reason}, _root), do: "#{path}: #{describe(reason)}."
  defp sentence({:tar, name, reason}, _root), do: "Writing #{name} failed: #{inspect(reason)}."
  defp sentence(reason, _root), do: "The command failed: #{inspect(reason)}."

  defp describe(reason) when is_atom(reason), do: List.to_string(:file.format_error(reason))
  defp describe(reason), do: inspect(reason)

  defp usage do
    IO.puts(:stderr, """
    Usage:
      fermix home export FILE [--passphrase-file PATH] [--mark-moved --to TEXT]
      fermix home import FILE --into ROOT [--passphrase-file PATH]
      fermix home mark-moved --to TEXT [--json]
      fermix home status [--json]
      fermix home snapshots status [--json]
      fermix home snapshots passphrase --passphrase-file PATH [--json]
      fermix home enroll --code-file PATH [--snapshot-bucket B --snapshot-region R]
      fermix home candidates [--json]
    """)

    2
  end
end
