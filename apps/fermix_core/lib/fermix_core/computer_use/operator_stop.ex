defmodule FermixCore.ComputerUse.OperatorStop do
  @moduledoc """
  The hold a Stop on the on-screen indicator leaves behind (M42 slice 5 §4).

  **Why this exists.** Stop ends the session, and ending a session is not the
  same as stopping the work: the model is mid-turn, its next `computer_use` call
  finds no session, and `SessionManager.ensure/3` cheerfully starts a fresh one
  with a fresh, unbarred helper. The person's Stop would hold for seconds. The
  chat `/stop` does not have this problem because it cancels the running TURN —
  but that cancellation lives in `FermixChannels.Gateway.Queue`, which is the
  layer above this one and which core cannot call. So the hold is made here, at
  the one door a computer-use session is opened through.

  **What "until they ask again" means.** A turn. The tool's context carries the
  turn's own `session_id` (the same value a session records as `parent_session`),
  so a Stop records which turn was stopped and every later call FROM THAT TURN is
  refused. The next turn is the person speaking again, and it clears the record
  on its way through. There is no configuration: an operator who has just pressed
  Stop should not also have to decide how long it lasts.

  **Bounded.** One entry per conversation, replaced rather than accumulated,
  cleared the moment a different turn asks, and expired after
  `#{div(600_000, 60_000)} minutes` for the conversation that never speaks again.

  Not running (computer-use disabled, so no CU tree) answers `:ok` — there is no
  session for a stop to have ended — the same shape `InputOwner` and
  `CaptureHealth` use for the same reason.
  """

  use GenServer

  require Logger

  # The backstop for a conversation that is simply abandoned after a Stop. The
  # record's real clearer is the person's next turn; this only keeps a dead
  # conversation's entry from living in memory forever.
  @ttl_ms 600_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Record that the person stopped computer use in `conversation`, during `turn`.

  A stop with no turn identity records NOTHING and says so: a hold the person's
  next message cannot lift is worse than no hold, and the refusal the pending
  caller already read is what stops this turn either way.
  """
  @spec record(term(), String.t() | nil, GenServer.server()) :: :ok
  def record(conversation, turn, server \\ __MODULE__)

  def record(_conversation, nil, _server) do
    Logger.warning(
      "computer_use: an operator stop had no turn to record against; " <>
        "the next computer-use call in this turn is not held"
    )
  end

  def record(conversation, turn, server) when is_binary(turn) do
    GenServer.cast(server, {:record, conversation, turn, now_ms()})
  catch
    :exit, _reason -> :ok
  end

  @doc """
  Whether a computer-use session may be opened for `conversation` from `turn`.

  `{:error, :operator_stopped}` while the asking turn is the one the person
  stopped. Any other turn clears the record and proceeds, which is what makes
  the hold last exactly as long as the turn it interrupted.
  """
  @spec check(term(), String.t() | nil, GenServer.server()) ::
          :ok | {:error, :operator_stopped}
  def check(conversation, turn, server \\ __MODULE__) do
    GenServer.call(server, {:check, conversation, turn, now_ms()})
  catch
    # NOT RUNNING is a pass, for the same reason `InputOwner` grants: no CU tree
    # means no session was ever open to be stopped.
    :exit, _reason -> :ok
  end

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:check, conversation, turn, now_ms}, _from, holds) do
    case Map.fetch(holds, conversation) do
      {:ok, %{turn: ^turn, at_ms: at}} when is_binary(turn) ->
        if now_ms - at < @ttl_ms,
          do: {:reply, {:error, :operator_stopped}, holds},
          else: {:reply, :ok, Map.delete(holds, conversation)}

      {:ok, _other_turn} ->
        {:reply, :ok, Map.delete(holds, conversation)}

      :error ->
        {:reply, :ok, holds}
    end
  end

  @impl true
  def handle_cast({:record, conversation, turn, now_ms}, holds) do
    {:noreply, Map.put(holds, conversation, %{turn: turn, at_ms: now_ms})}
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
