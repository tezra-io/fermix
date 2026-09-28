defmodule FermixCore.Browser.TurnMarker do
  @moduledoc """
  The per-turn no-Chrome marker: a turn whose pane task lost the Fermix app's
  browser keeps that answer for the rest of the turn.

  A pane that goes away fails its task with `host_lost`, and the task's
  profile is reaped (`HostServer`). The turn's next browser call would find no
  live profile and be decided afresh, which with the pane gone means Chrome.
  The owner's rule is the opposite: identify the loss early and never redo the
  task in another browser. So the loss is marked against the turn, and every
  browser call that turn makes afterwards answers the same sentence
  (`FermixCore.Browser.execute/2`) instead of being routed. The next turn
  decides fresh.

  A turn is the process that makes the browser calls: tools run inline in the
  process running the agent loop, which is a conversation's turn task, a
  scheduled job's run or a subagent's. A mark lives exactly as long as that
  process: it is monitored, and its exit clears every mark it holds, so the
  table holds no more than the turns running now.

  Reads are lock-free (a protected ETS table named after the server); only a
  mark goes through the process.
  """

  use GenServer

  alias FermixCore.Browser.Error

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, name, name: name)
  end

  @doc """
  Mark `turn`'s browser use for `owner` as having lost the pane with `error`.
  A tree with no marker (an isolated test tree) has no turn to hold it for.
  """
  @spec mark(atom(), String.t(), pid(), Error.t()) :: :ok
  def mark(server \\ __MODULE__, owner, turn, %Error{} = error)
      when is_atom(server) and is_binary(owner) and is_pid(turn) do
    GenServer.call(server, {:mark, owner, turn, error})
  catch
    :exit, {:noproc, _call} -> :ok
  end

  @doc "The loss marked for `owner` on `turn`, or `nil`."
  @spec lookup(atom(), String.t(), pid()) :: Error.t() | nil
  def lookup(server \\ __MODULE__, owner, turn)
      when is_atom(server) and is_binary(owner) and is_pid(turn) do
    case :ets.whereis(server) do
      :undefined -> nil
      table -> table |> :ets.lookup({owner, turn}) |> marked()
    end
  end

  defp marked([{_key, error}]), do: error
  defp marked([]), do: nil

  @impl true
  def init(name) do
    table = :ets.new(name, [:named_table, :protected, :set, read_concurrency: true])
    {:ok, %{table: table, turns: %{}}}
  end

  @impl true
  def handle_call({:mark, owner, turn, error}, _from, state) do
    true = :ets.insert(state.table, {{owner, turn}, error})
    {:reply, :ok, watch(state, turn)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, turn, _reason}, %{turns: turns} = state)
      when is_map_key(turns, turn) and :erlang.map_get(turn, turns) == ref do
    true = :ets.match_delete(state.table, {{:_, turn}, :_})
    {:noreply, %{state | turns: Map.delete(turns, turn)}}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  defp watch(%{turns: turns} = state, turn) when is_map_key(turns, turn), do: state

  defp watch(state, turn),
    do: %{state | turns: Map.put(state.turns, turn, Process.monitor(turn))}
end
