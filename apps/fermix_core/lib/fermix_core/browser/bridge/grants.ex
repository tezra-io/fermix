defmodule FermixCore.Browser.Bridge.Grants do
  @moduledoc """
  The table of granted tabs: one row per tab the person clicked the extension on.

  A row is keyed by `{peer, tab_id}` and never by the tab id alone. Tab ids are a
  browser's own counter, so two connected extensions — a second browser, a second
  profile — hand out the same small integers, and a table keyed on the id alone
  would let one browser's grant replace another's and one browser's events reach
  the other's transport.

  A grant is found by that key (which is how a `cdp` reply and an `event` find
  the transport waiting for them) and claimed by exactly one conversation (which
  is what stops a second conversation acting in a tab the first is working in).
  Two processes appear in a row and both are monitored, because both can die
  without saying so:

    * the `Peer` that carries the grant — its death takes every grant it holds,
    * the `ExtensionTransport` that claimed it — its death releases the tab and
      tells the extension to detach, which is the single release path for a
      stopped profile, an idle sweep and a finished conversation alike.

  A release DELETES the row. The extension detaches the debugger when it is told
  to, so a row that outlived the release would advertise a tab nothing is
  attached to and hand the next claimer a dead handle.

  Nothing here is persisted: a grant is a live browser tab with a live debugger
  attached to it, so a grant that outlived the daemon would be a promise about a
  tab nobody is attached to any more.
  """

  use GenServer

  @type key :: {pid(), integer()}

  @type grant :: %{
          key: key(),
          tab_id: integer(),
          peer: pid(),
          url: String.t(),
          title: String.t(),
          owner: String.t() | nil,
          transport: pid() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Record a connected extension so `summary/1` can report it."
  @spec attach_peer(GenServer.server(), pid()) :: :ok
  def attach_peer(server \\ __MODULE__, peer) when is_pid(peer) do
    GenServer.call(server, {:attach_peer, peer})
  end

  @doc "The person clicked the extension on `tab_id` of the browser behind `peer`."
  @spec grant(GenServer.server(), pid(), integer(), map()) :: :ok
  def grant(server \\ __MODULE__, peer, tab_id, attrs)
      when is_pid(peer) and is_integer(tab_id) and is_map(attrs) do
    GenServer.call(server, {:grant, peer, tab_id, attrs})
  end

  @doc """
  The grant is gone — the person clicked again, the tab closed, Chrome's
  debugging bar was dismissed, or DevTools took the debugger.
  """
  @spec revoke(GenServer.server(), pid(), integer(), String.t()) :: :ok
  def revoke(server \\ __MODULE__, peer, tab_id, reason)
      when is_pid(peer) and is_integer(tab_id) and is_binary(reason) do
    GenServer.call(server, {:revoke, peer, tab_id, reason})
  end

  @doc """
  Claim one unclaimed grant for `owner`, or hand back the one it already holds.

  The claim is what makes a tab a conversation's for as long as it works in it;
  `{:error, :no_grant}` is the answer the tool turns into "click the extension
  on the tab you mean".
  """
  @spec claim(GenServer.server(), String.t()) :: {:ok, grant()} | {:error, :no_grant}
  def claim(server \\ __MODULE__, owner) when is_binary(owner) do
    GenServer.call(server, {:claim, owner})
  end

  @doc """
  Bind the transport that will speak for one claimed grant, and monitor it: when
  it goes the tab is released and the extension is told to detach.
  """
  @spec bind(GenServer.server(), key(), pid()) :: {:ok, pid()} | {:error, :unknown_tab}
  def bind(server \\ __MODULE__, key, transport) when is_pid(transport) do
    GenServer.call(server, {:bind, key, transport})
  end

  @doc "The transport bound to one peer's tab, for a reply or an event that names it."
  @spec transport_for(GenServer.server(), pid(), integer()) :: {:ok, pid()} | :error
  def transport_for(server \\ __MODULE__, peer, tab_id)
      when is_pid(peer) and is_integer(tab_id) do
    GenServer.call(server, {:transport_for, {peer, tab_id}})
  end

  @doc "What `fermix browser bridge status` reports: extensions and granted tabs."
  @spec summary(GenServer.server()) :: %{extensions: non_neg_integer(), tabs: non_neg_integer()}
  def summary(server \\ __MODULE__), do: GenServer.call(server, :summary)

  @impl true
  def init(_opts) do
    {:ok, %{grants: %{}, peers: MapSet.new(), monitors: %{}}}
  end

  @impl true
  def handle_call({:attach_peer, peer}, _from, state) do
    {:reply, :ok, %{watch(state, peer) | peers: MapSet.put(state.peers, peer)}}
  end

  def handle_call({:grant, peer, tab_id, attrs}, _from, state) do
    key = {peer, tab_id}

    grant = %{
      key: key,
      tab_id: tab_id,
      peer: peer,
      url: Map.get(attrs, "url", ""),
      title: Map.get(attrs, "title", ""),
      owner: nil,
      transport: nil
    }

    # A second click on a tab somebody already holds takes it back from them, and
    # the old holder is TOLD — a regrant of the same tab is still a detach, and a
    # conversation that silently carried on would be working in a tab whose
    # debugger session it no longer owns.
    state = drop_grant(state, key, "regranted")
    {:reply, :ok, %{watch(state, peer) | grants: Map.put(state.grants, key, grant)}}
  end

  def handle_call({:revoke, peer, tab_id, reason}, _from, state) do
    {:reply, :ok, drop_grant(state, {peer, tab_id}, reason)}
  end

  def handle_call({:claim, owner}, _from, state) do
    case find_claimable(state.grants, owner) do
      {:ok, grant} ->
        grant = %{grant | owner: owner}
        {:reply, {:ok, grant}, %{state | grants: Map.put(state.grants, grant.key, grant)}}

      :error ->
        {:reply, {:error, :no_grant}, state}
    end
  end

  def handle_call({:bind, key, transport}, _from, state) do
    case Map.fetch(state.grants, key) do
      {:ok, grant} ->
        grant = %{grant | transport: transport}
        state = %{watch(state, transport) | grants: Map.put(state.grants, key, grant)}
        {:reply, {:ok, grant.peer}, state}

      :error ->
        {:reply, {:error, :unknown_tab}, state}
    end
  end

  def handle_call({:transport_for, key}, _from, state) do
    case Map.fetch(state.grants, key) do
      {:ok, %{transport: pid}} when is_pid(pid) -> {:reply, {:ok, pid}, state}
      _other -> {:reply, :error, state}
    end
  end

  def handle_call(:summary, _from, state) do
    {:reply, %{extensions: MapSet.size(state.peers), tabs: map_size(state.grants)}, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, state |> forget_peer(pid) |> forget_transport(pid)}
  end

  # A peer's death is every one of its tabs gone: the socket it spoke over is
  # the only way back to that extension.
  defp forget_peer(state, pid) do
    keys = for {{^pid, _tab_id} = key, _grant} <- state.grants, do: key
    state = Enum.reduce(keys, state, &drop_grant(&2, &1, "bridge_closed"))
    %{state | peers: MapSet.delete(state.peers, pid), monitors: Map.delete(state.monitors, pid)}
  end

  # The release path for every way a profile ends — `stop`, the idle sweep, the
  # conversation reaper, a crash. The transport is linked to its ProfileServer,
  # so one monitor here covers all of them.
  defp forget_transport(state, pid) do
    keys = for {key, %{transport: ^pid}} <- state.grants, do: key
    state = Enum.reduce(keys, state, &release_grant(&2, &1))
    %{state | monitors: Map.delete(state.monitors, pid)}
  end

  # A release IS a detach: the extension detaches the debugger and clears the
  # badge when it is told to, so the row goes with it. A row that survived would
  # report a phantom granted tab and hand the next claimer a dead handle.
  defp release_grant(state, key) do
    case Map.fetch(state.grants, key) do
      {:ok, grant} ->
        send(grant.peer, {:release_tab, grant.tab_id})
        %{state | grants: Map.delete(state.grants, key)}

      :error ->
        state
    end
  end

  defp drop_grant(state, key, reason) do
    case Map.fetch(state.grants, key) do
      {:ok, grant} ->
        notify_detached(grant, reason)
        %{state | grants: Map.delete(state.grants, key)}

      :error ->
        state
    end
  end

  defp notify_detached(%{transport: pid, tab_id: tab_id}, reason) when is_pid(pid) do
    send(pid, {:bridge_revoked, tab_id, reason})
  end

  defp notify_detached(_grant, _reason), do: :ok

  defp find_claimable(grants, owner) do
    grants
    |> Map.values()
    |> Enum.sort_by(& &1.tab_id)
    |> Enum.find(&(&1.owner == owner or is_nil(&1.owner)))
    |> case do
      nil -> :error
      grant -> {:ok, grant}
    end
  end

  defp watch(state, pid) do
    if Map.has_key?(state.monitors, pid) do
      state
    else
      %{state | monitors: Map.put(state.monitors, pid, Process.monitor(pid))}
    end
  end
end
