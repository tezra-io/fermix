defmodule FermixCore.Home.Snapshot.Run do
  @moduledoc """
  One snapshot run: capture once, store to every configured target, and say
  how each went (`FermixCore.Home.Snapshot.Scheduler` runs it in a task and
  records the answer).

  The encrypted file is written under `<home>/snapshots/` (device-local, so a
  capture never captures it) and removed once every target had it, whatever
  they answered: the primary keeps no copy, the targets do. A capture that
  fails is every target's failure, with the capture's own sentence. A target
  that cannot take it now answers `{:waiting, sentence}`. The result names the
  recovery key the snapshot was written for (`key_id`).
  """

  alias FermixCore.Home.Disk
  alias FermixCore.Home.Snapshot
  alias FermixCore.Home.Snapshot.Capture
  alias FermixCore.Home.Snapshot.Config
  alias FermixCore.Home.Snapshot.Recipient
  alias FermixCore.Home.Snapshot.Telemetry

  require Logger

  @type outcome ::
          {:ok, Snapshot.Target.stored()} | {:waiting, String.t()} | {:error, String.t()}
  @type result :: %{
          started_at: DateTime.t(),
          written: Snapshot.written() | nil,
          key_id: String.t(),
          outcomes: [{module(), outcome()}]
        }

  @doc """
  Runs one snapshot of `home` under `config` to `targets` (`Snapshot.Target`
  modules). `:not_configured` when the section names no recipient or no target
  is on. `opts`: `:now` (a 0-arity clock), `:host`, and what the targets take
  (`:profile`, their own seams).
  """
  @spec run(Path.t(), keyword(), [module()], keyword()) :: {:ok, result()} | :not_configured
  def run(home, config, targets, opts)
      when is_binary(home) and is_list(config) and is_list(targets) and is_list(opts) do
    active =
      for target <- targets,
          {:ok, settings} <- [target.configured(config)],
          do: {target, settings}

    case {Config.recipient(config), active} do
      {{:ok, recipient}, [_ | _]} -> {:ok, capture_and_store(home, recipient, active, opts)}
      _off -> :not_configured
    end
  end

  @doc "The sentence an owner is shown for a capture that failed."
  @spec capture_sentence(term()) :: String.t()
  def capture_sentence({:home_moved, %{to: to}}),
    do: "This home moved to #{to}, so it writes no snapshots."

  def capture_sentence(:epoch_absent),
    do: "The home has no primary epoch yet, so there is nothing to snapshot."

  def capture_sentence({:changed_during_capture, path}),
    do: "#{path} kept growing while the snapshot was taken. The next run tries again."

  def capture_sentence({:vacuum, reason}),
    do: "The memory database could not be copied (#{describe(reason)})."

  def capture_sentence({:file, path, reason}),
    do: "The snapshot could not be written: #{path}: #{describe(reason)}."

  def capture_sentence({kind, path, _detail})
      when kind in [:unsupported_entry, :unsupported_link],
      do: "#{path} in the home cannot be carried in a snapshot. Move it out of the home."

  def capture_sentence({:too_many_files, count, max}),
    do: "The home holds #{count} files or more, beyond the #{max} one snapshot carries."

  def capture_sentence({:insufficient_space, need, free}),
    do:
      "Taking a snapshot needs about #{Disk.gib(need)} free on this disk, and #{Disk.gib(free)} is " <>
        "free. Make room or give the disk more space; the next run tries again."

  def capture_sentence({:free_space_unknown, reason}),
    do: "Fermix could not tell how much space this disk has (#{describe(reason)})."

  def capture_sentence(reason), do: "The snapshot could not be written (#{describe(reason)})."

  defp capture_and_store(home, recipient, active, opts) do
    started_at = now(opts)
    started_ms = System.monotonic_time(:millisecond)
    path = Path.join(Capture.dir(home), ".outgoing-#{System.unique_integer([:positive])}.fxsnap")
    write_opts = [now: fn -> started_at end] ++ Keyword.take(opts, [:host, :free_bytes])
    key_id = Base.encode16(Recipient.key_id(recipient.public_key), case: :lower)

    case Snapshot.write(home, recipient, path, write_opts) do
      {:ok, written} ->
        outcomes = store_all(Map.put(written, :path, path), active, opts, started_ms)
        remove(path)
        %{started_at: started_at, written: written, key_id: key_id, outcomes: outcomes}

      {:error, reason} ->
        Logger.warning("home snapshot: capture failed: #{inspect(reason)}")
        sentence = capture_sentence(reason)

        outcomes =
          Enum.map(active, fn {target, _settings} ->
            Telemetry.emit(target.id(), {:failed, reason}, %{}, started_ms)
            {target, {:error, sentence}}
          end)

        %{started_at: started_at, written: nil, key_id: key_id, outcomes: outcomes}
    end
  end

  defp store_all(snapshot, active, opts, started_ms) do
    Enum.map(active, fn {target, settings} ->
      case target.store(snapshot, settings, opts) do
        {:ok, stored} ->
          Telemetry.emit(target.id(), :verified, snapshot, started_ms)
          {target, {:ok, stored}}

        {:waiting, reason} ->
          Telemetry.emit(target.id(), {:waiting, reason}, snapshot, started_ms)
          {target, {:waiting, target.sentence(reason)}}

        {:error, reason} ->
          Logger.warning("home snapshot: #{target.id()} failed: #{inspect(reason)}")
          Telemetry.emit(target.id(), {:failed, reason}, snapshot, started_ms)
          {target, {:error, target.sentence(reason)}}
      end
    end)
  end

  defp remove(path) do
    case File.rm(path) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("home snapshot: could not remove #{path}: #{inspect(reason)}")
    end
  end

  defp now(opts),
    do:
      opts
      |> Keyword.get(:now, &DateTime.utc_now/0)
      |> then(& &1.())
      |> DateTime.truncate(:second)

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason) when is_atom(reason), do: posix(reason, :file.format_error(reason))
  defp describe(reason), do: inspect(reason)

  # A POSIX code reads as its words; any other atom is a literal, backticked.
  defp posix(reason, ~c"unknown POSIX error" ++ _rest), do: "`#{reason}`"
  defp posix(_reason, words), do: List.to_string(words)
end
