defmodule FermixChannels.Desktop.SnapshotCopies do
  @moduledoc """
  The `snapshots` family of a connected desktop on the primary
  (`Desktop.Family`, M75 §8): the desktop's answers to the snapshots the
  desktop target (`Desktop.SnapshotTarget`) streams it.

  The target, in the scheduler's run, says which snapshot it waits for
  (`{:await, snapshot_id, pid}` through `Desktop.Peer.tell/4`) before it
  streams, and lets go after (`{:forget, snapshot_id}`). The desktop's
  `snapshot_stored` (with the SHA-256 it computed) and `snapshot_refused`
  (with why) are handed to that process as
  `{:desktop_snapshot, snapshot_id, {:stored, sha256} | {:refused, reason}}`.
  An answer nobody waits for (a run that gave up) is logged and dropped.
  """

  @behaviour FermixChannels.Desktop.Family

  require Logger

  @impl true
  def init(context), do: {:ok, %{device_id: context.device_id, waiters: %{}}}

  @impl true
  def handle_event(
        "snapshot_stored",
        %{"snapshot_id" => id, "sha256" => sha256},
        _payload,
        state
      ),
      do: {:ok, answer(state, id, {:stored, String.downcase(sha256)})}

  def handle_event(
        "snapshot_refused",
        %{"snapshot_id" => id, "reason" => reason},
        _payload,
        state
      ),
      do: {:ok, answer(state, id, {:refused, reason})}

  @impl true
  def handle_info({:await, id, pid}, state) when is_binary(id) and is_pid(pid),
    do: {:ok, put_in(state.waiters[id], pid)}

  def handle_info({:forget, id}, state) when is_binary(id),
    do: {:ok, %{state | waiters: Map.delete(state.waiters, id)}}

  @impl true
  def terminate(_reason, _state), do: :ok

  defp answer(state, id, result) do
    case Map.pop(state.waiters, id) do
      {nil, _waiters} ->
        Logger.warning(
          "desktop snapshot: #{state.device_id} answered #{id}, which no run waits for"
        )

        state

      {pid, waiters} ->
        send(pid, {:desktop_snapshot, id, result})
        %{state | waiters: waiters}
    end
  end
end
