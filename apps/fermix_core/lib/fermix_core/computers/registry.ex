defmodule FermixCore.Computers.Registry do
  @moduledoc """
  What the home knows live of each connected computer (M97 §3.2), on the
  primary: whose session is up, the offers it sent in that session, and the
  path its session runs (`direct` or `relay`), as the computer reports it.

  The computer's server-side family (`FermixChannels.Desktop.ComputerFamily`,
  in the computer's `Desktop.Peer`) tells it each fact as it comes:
  `connected/3` as the session's peer starts, `offers/4` and `path/3` as
  their events arrive, and `disconnected/3` as the peer ends. A session's
  offers start empty: a computer that has not sent `offers` in this session
  offers nothing, and a payload the family refused is recorded as nothing,
  so a bad one fails closed for that computer alone. A word from a session
  that is no longer the computer's newest is ignored.

  The live facts are read lock-free (`live/1`) from a `:protected` table
  only this process writes. The lasting ones go to the computers' records
  (`Computers.Store`): the offers and their revision as they arrive, and when
  the session ended as the time the home last heard the computer. A record
  that fails is logged, and the live facts stand.

  It monitors each session, so a session that ended without its family's
  word is let go all the same. Primary-only (`Home.Role`). If it restarts,
  its live facts are gone until each computer's next event: the list of
  computers (`FermixCore.Computers.list/1`) still reads who is connected
  from the link and each computer's last offers from the records, and loses
  only the path until it next changes.

  Each change tells the Always On watch (`Home.StatusWatch`, `:computers`).

  Seams: `:name`, `:home`, `:clock` (0-arity, the wall clock) and
  `:status_changed` (0-arity, in place of telling the watch).
  """

  use GenServer

  require Logger

  alias FermixCore.Computers.Offers
  alias FermixCore.Computers.Store
  alias FermixCore.Home.StatusWatch
  alias FermixCore.Setup.ConfigStore

  @typedoc "One connected computer's live facts."
  @type live :: %{
          since: DateTime.t(),
          session: pid(),
          offers: [Offers.offer()],
          offers_rev: String.t() | nil,
          path: :direct | :relay | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "The computer `device_id`'s session `session` is up since `since`."
  @spec connected(GenServer.server(), String.t(), %{since: DateTime.t(), session: pid()}) :: :ok
  def connected(server \\ __MODULE__, device_id, %{since: %DateTime{}, session: session} = facts)
      when is_binary(device_id) and is_pid(session),
      do: GenServer.cast(server, {:connected, device_id, facts})

  @doc """
  The computer `device_id`'s session `session` sent `offers` at revision
  `rev`; `[]` with nil for a payload refused.
  """
  @spec offers(GenServer.server(), String.t(), pid(), [Offers.offer()], String.t() | nil) :: :ok
  def offers(server \\ __MODULE__, device_id, session, offers, rev)
      when is_binary(device_id) and is_pid(session) and is_list(offers),
      do: GenServer.cast(server, {:offers, device_id, session, offers, rev})

  @doc "The computer `device_id`'s session `session` runs `path`."
  @spec path(GenServer.server(), String.t(), pid(), :direct | :relay) :: :ok
  def path(server \\ __MODULE__, device_id, session, path)
      when is_binary(device_id) and is_pid(session) and path in [:direct, :relay],
      do: GenServer.cast(server, {:path, device_id, session, path})

  @doc "The computer `device_id`'s session `session` ended."
  @spec disconnected(GenServer.server(), String.t(), pid()) :: :ok
  def disconnected(server \\ __MODULE__, device_id, session)
      when is_binary(device_id) and is_pid(session),
      do: GenServer.cast(server, {:disconnected, device_id, session})

  @doc """
  The live facts of every connected computer, by device id, read from the
  table of the registry named `server`; none when it does not run.
  """
  @spec live(atom()) :: %{String.t() => live()}
  def live(server \\ __MODULE__) when is_atom(server) do
    server |> table() |> :ets.tab2list() |> Map.new()
  rescue
    ArgumentError -> %{}
  end

  @impl true
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    table = :ets.new(table(name), [:named_table, :protected, :set, read_concurrency: true])

    {:ok,
     %{
       table: table,
       home: Keyword.get_lazy(opts, :home, &ConfigStore.fermix_home/0),
       clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
       status_changed:
         Keyword.get(opts, :status_changed, fn -> StatusWatch.changed(:computers) end),
       monitors: %{}
     }}
  end

  @impl true
  def handle_cast({:connected, device_id, facts}, state),
    do: {:noreply, connect(device_id, facts, state)}

  def handle_cast({:offers, device_id, session, offers, rev}, state),
    do: {:noreply, offered(device_id, session, offers, rev, state)}

  def handle_cast({:path, device_id, session, path}, state),
    do: {:noreply, update_live(device_id, session, &%{&1 | path: path}, state)}

  def handle_cast({:disconnected, device_id, session}, state),
    do: {:noreply, disconnect(device_id, session, state)}

  @impl true
  def handle_info({:DOWN, ref, :process, session, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {{device_id, ^session}, monitors} ->
        {:noreply, ended(device_id, session, %{state | monitors: monitors})}

      {nil, _monitors} ->
        {:noreply, state}
    end
  end

  # -- the facts -------------------------------------------------------------

  defp connect(device_id, %{since: since, session: session}, state) do
    ref = Process.monitor(session)

    true =
      :ets.insert(
        state.table,
        {device_id, %{since: since, session: session, offers: [], offers_rev: nil, path: nil}}
      )

    changed(%{state | monitors: Map.put(state.monitors, ref, {device_id, session})})
  end

  defp offered(device_id, session, offers, rev, state) do
    case current(device_id, session, state) do
      {:ok, live} ->
        true = :ets.insert(state.table, {device_id, %{live | offers: offers, offers_rev: rev}})
        :ok = keep(state, device_id, %{offers: offers, offers_rev: rev})
        changed(state)

      :stale ->
        state
    end
  end

  defp update_live(device_id, session, change, state) do
    case current(device_id, session, state) do
      {:ok, live} ->
        true = :ets.insert(state.table, {device_id, change.(live)})
        changed(state)

      :stale ->
        state
    end
  end

  defp disconnect(device_id, session, state) do
    {ref, monitors} = pop_monitor(state.monitors, device_id, session)
    if ref, do: Process.demonitor(ref, [:flush])
    ended(device_id, session, %{state | monitors: monitors})
  end

  defp ended(device_id, session, state) do
    case current(device_id, session, state) do
      {:ok, _live} ->
        true = :ets.delete(state.table, device_id)
        :ok = keep(state, device_id, %{seen_at: state.clock.()})
        changed(state)

      :stale ->
        state
    end
  end

  defp pop_monitor(monitors, device_id, session) do
    case Enum.find(monitors, fn {_ref, value} -> value == {device_id, session} end) do
      {ref, _value} -> {ref, Map.delete(monitors, ref)}
      nil -> {nil, monitors}
    end
  end

  # The computer's newest session: a word from an older one is not its own.
  defp current(device_id, session, state) do
    case :ets.lookup(state.table, device_id) do
      [{^device_id, %{session: ^session} = live}] -> {:ok, live}
      _none_or_newer -> :stale
    end
  end

  defp keep(state, device_id, fields) do
    case Store.record(state.home, device_id, fields) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("computer #{device_id}: its record was not kept: #{inspect(reason)}")
    end
  end

  defp changed(state) do
    :ok = state.status_changed.()
    state
  end

  defp table(name), do: :"#{name}.Live"
end
