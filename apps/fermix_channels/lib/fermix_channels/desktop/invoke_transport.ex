defmodule FermixChannels.Desktop.InvokeTransport do
  @moduledoc """
  The server's side of the link for an invocation (M97 §6.1): the one
  implementation of `FermixCore.Computers.Transport`, through the
  computer's peer (`Desktop.Peer.send/4`), which runs in the caller.

  `open/5` sends `invoke_open` (a chunked payload, its args JSON), then the
  part it announces as `invoke_part` frames of at most 60 KiB, each naming
  the part's whole size (`size_bytes`, which decides its lane,
  `Mobile.Lanes`), and waits every #{16} frames for the session to have
  written them (`{:mobile_sync, from, ref}`, at most #{60} s), so a slow
  link slows the upload instead of filling the session's mailbox.

  Option (a test's seam): `:registry`, the peers' registry.
  """

  @behaviour FermixCore.Computers.Transport

  alias FermixChannels.Desktop.Peer
  alias FermixChannels.Mobile.Chunks

  @chunk_bytes 60 * 1_024
  @sync_every 16
  @sync_timeout_ms 60_000

  @impl true
  def open(device_id, header, payload, part, opts)
      when is_binary(device_id) and is_map(header) and is_binary(payload) do
    registry = registry(opts)
    event = Map.put(header, "t", "invoke_open")

    case Peer.send(device_id, event, payload, registry: registry) do
      :ok -> send_part(device_id, header["id"], part, registry)
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def cancel(device_id, id, opts) when is_binary(device_id) and is_binary(id),
    do:
      Peer.send(device_id, %{"t" => "invoke_cancel", "id" => id}, <<>>, registry: registry(opts))

  @impl true
  def status(device_id, id, opts) when is_binary(device_id) and is_binary(id),
    do:
      Peer.send(device_id, %{"t" => "invoke_status", "id" => id}, <<>>, registry: registry(opts))

  defp registry(opts), do: Keyword.get(opts, :registry, FermixChannels.Desktop.Peers)

  defp send_part(_device_id, _id, nil, _registry), do: :ok

  defp send_part(device_id, id, part, registry) when is_binary(part) do
    with {:ok, _peer, %{session: session}} <- Peer.lookup(registry, device_id),
         :ok <- send_frames(device_id, id, part, session, registry) do
      :ok
    else
      {:error, reason} -> {:error, {:part, reason}}
    end
  end

  defp send_frames(device_id, id, part, session, registry) do
    size = byte_size(part)

    part
    |> Chunks.split(@chunk_bytes)
    |> Enum.reduce_while(:ok, fn {index, last, bytes}, :ok ->
      event = %{
        "t" => "invoke_part",
        "id" => id,
        "index" => index,
        "last" => last,
        "size_bytes" => size
      }

      with :ok <- Peer.send(device_id, event, bytes, registry: registry),
           :ok <- paced(index, session) do
        {:cont, :ok}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp paced(index, session) when rem(index + 1, @sync_every) == 0, do: synced(session)
  defp paced(_index, _session), do: :ok

  # Answered once the session wrote every frame handed to it before this.
  defp synced(session) do
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
end
