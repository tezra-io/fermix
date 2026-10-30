defmodule FermixChannels.Desktop.SnapshotTarget do
  @moduledoc """
  The desktop snapshot target (M75 §8, D19): the primary keeps a copy of each
  snapshot it writes on every desktop connected to it over the rail, beside
  the S3 copy.

  `FermixCore.Home.Snapshot.Scheduler` writes the encrypted snapshot once and
  hands it to each target (`FermixCore.Home.Snapshot.Target`); this one is
  registered by module (`config :fermix_core, :snapshot_targets`), so core
  never names it. It is on while the primary has a desktop row.

  `store/3` streams the file, never whole in memory, to each connected
  desktop: `snapshot_begin` (name, size and SHA-256), the bytes as
  `snapshot_chunk`s of 60 KiB in order, `snapshot_end`. Every 16 chunks it
  waits until the desktop's session has written what it was handed
  (`{:mobile_sync, from, ref}`), so a slow rail slows the stream instead of
  filling the session's mailbox. The copy is verified when the desktop answers
  `snapshot_stored` with the same SHA-256 (`Desktop.SnapshotCopies` hands the
  answer back); a desktop that refuses says why (`snapshot_refused`), and one
  that does not answer within 120 s of the end is a failure by name.

  No connected desktop (asleep, shut, offline) is no failure: `store/3`
  answers `{:waiting, {:not_connected, name}}`, which the status records as
  `waiting` with the sentence `Your <name> is not connected; the snapshot waits
  for the next run.` while the S3 copy goes on. The desktop keeps the newest 3
  (`Desktop.SnapshotStore`).

  Test seams in `opts`: `:desktop_rows` (a 0-arity function answering the
  desktop rows), `:desktop_peers` (the peers' registry), `:desktop_send`,
  `:desktop_tell`, `:desktop_sync`, `:desktop_answer_timeout_ms`.
  """

  @behaviour FermixCore.Home.Snapshot.Target

  require Logger

  alias FermixChannels.Desktop.Peer
  alias FermixChannels.Desktop.SnapshotStore
  alias FermixChannels.Mobile.DeviceStore

  @chunk_bytes 60 * 1_024
  @sync_every 16
  @sync_timeout_ms 60_000
  @answer_timeout_ms 120_000

  @impl true
  def id, do: "desktop"

  @impl true
  def label, do: "your desktop"

  @impl true
  def configured(config) when is_list(config) do
    case desktop_rows() do
      [] -> :not_configured
      rows -> {:ok, %{names: Enum.map(rows, & &1.name)}}
    end
  end

  @impl true
  def destination(%{names: names}, _opts), do: "snapshots/ on #{Enum.join(names, ", ")}"

  @impl true
  def store(%{path: path, name: name, size: size, sha256: sha256}, settings, opts)
      when is_binary(path) and is_list(opts) do
    rows = Keyword.get(opts, :desktop_rows, &desktop_rows/0).()
    registry = Keyword.get(opts, :desktop_peers, FermixChannels.Desktop.Peers)
    opts = Keyword.put(opts, :desktop_peers, registry)
    connected = connected_ids(registry)

    case Enum.filter(rows, &MapSet.member?(connected, &1.device_id)) do
      [] ->
        {:waiting, {:not_connected, first_name(rows, settings)}}

      desktops ->
        snapshot = %{path: path, name: name, size: size, sha256: sha256}
        store_all(desktops, snapshot, registry, opts)
    end
  end

  @impl true
  def sentence({:not_connected, name}),
    do: "Your #{name} is not connected; the snapshot waits for the next run."

  def sentence({:disconnected, name}),
    do: "Your #{name} disconnected while the snapshot was sent; the next run sends it again."

  def sentence({:timeout, name}), do: "Your #{name} did not confirm the snapshot in time."

  def sentence({:sha_mismatch, name}),
    do: "Your #{name} stored a copy that does not match the snapshot."

  def sentence({:refused, name, "disk_floor"}) do
    gib = div(SnapshotStore.floor_bytes(), 1_024 * 1_024 * 1_024)
    "Your #{name} kept no copy: it would have left less than #{gib} GiB free on its disk."
  end

  def sentence({:refused, name, "space_unknown"}),
    do: "Your #{name} kept no copy: it could not tell how much space its disk has."

  def sentence({:refused, name, "mismatch"}),
    do: "Your #{name} received a copy that did not match the snapshot, so it kept none."

  def sentence({:refused, name, _reason}),
    do: "Your #{name} could not keep the snapshot. Its daemon log says why."

  def sentence({:read_failed, reason}),
    do: "The snapshot could not be read to send it (#{inspect(reason)})."

  defp store_all(desktops, snapshot, registry, opts) do
    Enum.reduce_while(desktops, {:ok, []}, fn desktop, {:ok, names} ->
      case store_on(desktop, snapshot, registry, opts) do
        :ok -> {:cont, {:ok, [desktop.name | names]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> stored()
  end

  defp stored({:ok, names}),
    do: {:ok, %{location: "snapshots/ on " <> (names |> Enum.reverse() |> Enum.join(", "))}}

  defp stored({:error, _reason} = error), do: error

  # One desktop's copy: the answer awaited from its peer, the bytes streamed,
  # the SHA-256 compared. The wait is let go on every path.
  defp store_on(desktop, snapshot, registry, opts) do
    id = "snap-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    tell = Keyword.get(opts, :desktop_tell, &Peer.tell/4)

    with {:ok, peer, %{session: session}} <- Peer.lookup(registry, desktop.device_id),
         :ok <- tell.(desktop.device_id, :snapshots, {:await, id, self()}, registry: registry) do
      monitor = Process.monitor(peer)

      try do
        stream_and_verify(desktop, snapshot, id, session, monitor, opts)
      after
        Process.demonitor(monitor, [:flush])
        tell.(desktop.device_id, :snapshots, {:forget, id}, registry: registry)
      end
    else
      {:error, :not_connected} -> {:error, {:disconnected, desktop.name}}
    end
  end

  defp stream_and_verify(desktop, snapshot, id, session, monitor, opts) do
    send = Keyword.get(opts, :desktop_send, &Peer.send/4)
    registry = Keyword.fetch!(opts, :desktop_peers)
    device = desktop.device_id

    begin = %{
      "t" => "snapshot_begin",
      "snapshot_id" => id,
      "name" => snapshot.name,
      "size_bytes" => snapshot.size,
      "sha256" => snapshot.sha256
    }

    with :ok <- sent(send.(device, begin, <<>>, registry: registry), desktop),
         :ok <- stream(snapshot.path, desktop, id, session, opts),
         :ok <-
           sent(
             send.(device, %{"t" => "snapshot_end", "snapshot_id" => id}, <<>>,
               registry: registry
             ),
             desktop
           ) do
      await(id, desktop, snapshot.sha256, monitor, opts)
    end
  end

  defp stream(path, desktop, id, session, opts) do
    case File.open(path, [:read, :binary, :raw]) do
      {:ok, io} ->
        try do
          stream_chunks(io, 0, desktop, id, session, opts)
        after
          File.close(io)
        end

      {:error, reason} ->
        {:error, {:read_failed, reason}}
    end
  end

  defp stream_chunks(io, index, desktop, id, session, opts) do
    case :file.read(io, @chunk_bytes) do
      {:ok, bytes} ->
        with :ok <- send_chunk(desktop, id, index, bytes, opts),
             :ok <- maybe_sync(index, session, desktop, opts),
             do: stream_chunks(io, index + 1, desktop, id, session, opts)

      :eof ->
        :ok

      {:error, reason} ->
        {:error, {:read_failed, reason}}
    end
  end

  defp send_chunk(desktop, id, index, bytes, opts) do
    send = Keyword.get(opts, :desktop_send, &Peer.send/4)
    registry = Keyword.fetch!(opts, :desktop_peers)
    event = %{"t" => "snapshot_chunk", "snapshot_id" => id, "index" => index}
    sent(send.(desktop.device_id, event, bytes, registry: registry), desktop)
  end

  defp maybe_sync(index, session, desktop, opts) when rem(index + 1, @sync_every) == 0 do
    sync = Keyword.get(opts, :desktop_sync, &sync_session/1)

    case sync.(session) do
      :ok -> :ok
      {:error, _reason} -> {:error, {:disconnected, desktop.name}}
    end
  end

  defp maybe_sync(_index, _session, _desktop, _opts), do: :ok

  @doc false
  # Answered once the session wrote every frame handed to it before this.
  @spec sync_session(pid()) :: :ok | {:error, :session_down | :sync_timeout}
  def sync_session(session) when is_pid(session) do
    ref = Process.monitor(session)
    send(session, {:mobile_sync, self(), ref})

    receive do
      {:mobile_synced, ^ref} ->
        Process.demonitor(ref, [:flush])
        :ok

      {:DOWN, ^ref, :process, _session, _reason} ->
        {:error, :session_down}
    after
      @sync_timeout_ms ->
        Process.demonitor(ref, [:flush])
        {:error, :sync_timeout}
    end
  end

  defp await(id, desktop, sha256, monitor, opts) do
    timeout = Keyword.get(opts, :desktop_answer_timeout_ms, @answer_timeout_ms)
    expected = String.downcase(sha256)

    receive do
      {:desktop_snapshot, ^id, {:stored, ^expected}} -> :ok
      {:desktop_snapshot, ^id, {:stored, _other}} -> {:error, {:sha_mismatch, desktop.name}}
      {:desktop_snapshot, ^id, {:refused, reason}} -> {:error, {:refused, desktop.name, reason}}
      {:DOWN, ^monitor, :process, _peer, _reason} -> {:error, {:disconnected, desktop.name}}
    after
      timeout -> {:error, {:timeout, desktop.name}}
    end
  end

  defp sent(:ok, _desktop), do: :ok

  defp sent({:error, reason}, desktop) do
    Logger.warning("desktop snapshot: #{desktop.device_id}: #{inspect(reason)}")
    {:error, {:disconnected, desktop.name}}
  end

  defp first_name([%{name: name} | _rest], _settings), do: name
  defp first_name([], %{names: [name | _rest]}), do: name
  defp first_name([], _settings), do: "desktop"

  # No peers' registry runs where the phone channel does not, and no desktop
  # could connect there.
  defp connected_ids(registry) do
    if Process.whereis(registry),
      do: registry |> Peer.connected() |> MapSet.new(& &1.device_id),
      else: MapSet.new()
  end

  # The primary's desktop rows, from the running trust store; none where the
  # phone channel does not run (no desktop could connect there).
  defp desktop_rows do
    if GenServer.whereis(DeviceStore), do: desktops_in(DeviceStore.list(DeviceStore)), else: []
  end

  defp desktops_in({:ok, rows}),
    do: for(%{kind: :desktop} = row <- rows, do: %{device_id: row.device_id, name: row.name})

  defp desktops_in({:error, reason}) do
    Logger.error("desktop snapshot: the trust store could not be read: #{inspect(reason)}")
    []
  end
end
