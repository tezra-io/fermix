defmodule FermixCore.Meetings.Sweep do
  @moduledoc """
  Boot reconciliation for the meetings table (MILESTONE_21 C2 §2.8).

  A `Meetings.Session` is `:temporary` and holds the whole meeting in memory, so
  a daemon that restarts mid-meeting leaves rows claiming to be joining,
  capturing, or summarizing with no process behind any of them. Left alone they
  would make `list_meetings(scope: :active)` lie for as long as the database
  lives. One indexed read at boot fails them all, with a reason an operator can
  recognize.

  It runs unconditionally — not behind the meetings enable toggle. Rows stranded
  by a since-disabled install are exactly the ones nobody would come back for.

  A `:transient` child that stops `:normal` as soon as the pass is done: this is
  a boot step, not a service. The pass runs in `handle_continue/2` so a slow
  write never sits inside the supervisor's start.
  """

  use GenServer, restart: :transient

  alias FermixCore.Meetings.Store

  require Logger

  # What the swept rows say happened. Also the operator-visible `error` text.
  @error_text "daemon_restarted"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    {:ok, %{store_opts: Keyword.get(opts, :store_opts, [])}, {:continue, :sweep}}
  end

  @impl true
  def handle_continue(:sweep, state) do
    @error_text
    |> Store.sweep_live(state.store_opts)
    |> report()

    {:stop, :normal, state}
  end

  defp report({:ok, []}), do: :ok

  defp report({:ok, ids}) do
    Logger.warning(
      "meetings: failed #{length(ids)} meeting(s) stranded by a daemon restart: " <>
        Enum.join(ids, ", ")
    )
  end

  # Memory being off is a configuration, not a failure: there is no table to
  # reconcile, and nothing else is attempted either way.
  defp report({:error, :disabled}), do: :ok

  defp report({:error, reason}) do
    Logger.error(
      "meetings: boot sweep failed (#{inspect(reason)}); live rows may claim meetings " <>
        "that are not running"
    )
  end
end
