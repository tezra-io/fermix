defmodule FermixCore.Realtime.CallSweep do
  @moduledoc """
  Boot reconciliation for Live call records (M56 §4.2), in the shape of
  `Meetings.Sweep`.

  A Live session holds its call in memory and writes the record as it goes, so a
  daemon that restarts mid-call leaves a record with no end and tasks that claim
  to be running with nothing behind them. One pass at boot closes every such
  record as `daemon_restarted`, its bill unsettled, and fails its unfinished
  tasks with the same reason (`CallRecord.sweep/2`).

  The cutoff is taken in `init/1`, and `Realtime.Supervisor` starts this before
  the voice socket that starts calls, so a call this boot starts is never swept
  however long the pass takes.

  A `:transient` child that stops `:normal` once the pass is done: a boot step,
  not a service. The pass runs in `handle_continue/2` so a slow write never sits
  inside the supervisor's start.
  """

  use GenServer, restart: :transient

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
    |> CallRecord.sweep(CallRecord.repo_opts(state.repo))
    |> report()

    {:stop, :normal, state}
  end

  defp report({:ok, []}), do: :ok

  defp report({:ok, uuids}) do
    Logger.warning(
      "voice_live: closed #{length(uuids)} call record(s) a daemon restart left open: " <>
        Enum.join(uuids, ", ")
    )

    report_page(length(uuids))
  end

  # Memory being off is a configuration, not a failure: there is no table.
  defp report({:error, :disabled}), do: :ok

  defp report({:error, reason}) do
    Logger.error(
      "voice_live: the boot sweep of call records failed (#{inspect(reason)}); " <>
        "records may claim calls that are not running"
    )
  end

  # One page is closed per boot. A full page may have left more open, which
  # the next boot closes.
  defp report_page(count) do
    if count >= VoiceCallsSql.list_limit() do
      Logger.warning(
        "voice_live: the boot sweep closed a full page; the next boot closes the rest"
      )
    end
  end
end
