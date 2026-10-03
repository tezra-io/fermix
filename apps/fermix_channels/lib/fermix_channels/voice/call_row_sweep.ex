defmodule FermixChannels.Voice.CallRowSweep do
  @moduledoc """
  Boot reconciliation for the chat rows Live calls owe (M56 §4.2, §8), in the
  shape of `FermixCore.Realtime.CallSweep`.

  A call in the chat closes its record owing the chat one row, and a gist
  when anything was said; a task the session spawned makes the gist and
  writes the row. A daemon that dies in between leaves the record owing both.
  One pass at boot fails each gist still pending, since the process making it
  is gone, and writes each owed row from the record, the task list in place of
  the gist (`CallRecord.sweep_rows/3`). The row is keyed by the call, so a row
  the dead daemon had already written is found, not written twice.

  It is Channels', not Core's: the row's writer is the companion channel,
  which starts after Core, so `FermixChannels.Application` starts this after
  `Companion.Supervisor`, and it writes through `Voice.Bridge.show/2` as the
  session's task does. Core's `CallSweep` closes the records a restart cut
  off mid-call; those owe no row.

  The cutoff is taken in `init/1`: a call this boot started is left to its
  own session's task.

  A `:transient` child that stops `:normal` once the pass is done: a boot
  step, not a service. The pass runs in `handle_continue/2` so a slow write
  never sits inside the supervisor's start.
  """

  use GenServer, restart: :transient

  alias FermixChannels.Voice.Bridge
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.VoiceCallsSql
  alias FermixCore.Realtime.CallRecord

  require Logger

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    state = %{cutoff: DateTime.utc_now(), repo: Keyword.get(opts, :record_repo, Repo)}
    {:ok, state, {:continue, :sweep}}
  end

  @impl true
  def handle_continue(:sweep, state) do
    state.cutoff
    |> CallRecord.sweep_rows(&Bridge.show/2, CallRecord.repo_opts(state.repo))
    |> report()

    {:stop, :normal, state}
  end

  defp report({:ok, []}), do: :ok

  defp report({:ok, uuids}) do
    Logger.warning(
      "voice_live: wrote #{length(uuids)} chat row(s) a daemon restart left owed: " <>
        Enum.join(uuids, ", ")
    )

    report_page(length(uuids))
  end

  # Memory being off is a configuration, not a failure: there is no table.
  defp report({:error, :disabled}), do: :ok

  defp report({:error, reason}) do
    Logger.error(
      "voice_live: the boot pass over owed chat rows failed (#{inspect(reason)}); " <>
        "the next boot writes what is left"
    )
  end

  # One page is written per boot. A full page may have left more owed, which
  # the next boot writes.
  defp report_page(count) do
    if count >= VoiceCallsSql.list_limit() do
      Logger.warning(
        "voice_live: the boot pass wrote a full page of chat rows; the next boot writes the rest"
      )
    end
  end
end
