defmodule FermixCore.Management.McpServers.DraftValues do
  @moduledoc """
  The one owner of `draft_id` (M74 §5, E8): the values a paste carried, held
  in the daemon's memory until `mcp.servers.add` stores them, so the app never
  holds a pasted key again after it sends the paste.

  An id is opaque (random bytes, no server name and no value in it) and means
  something only to this process:

    * it is bound to this boot: a restart, or this process starting again,
      forgets every id;
    * it expires 10 minutes after the draft;
    * it is used once: `take/2` hands its values over and forgets them;
    * at most 64 are held at once, and holding one more drops the oldest.
      A paste holds at most `Interchange.max_servers/0` ids, so the newest
      paste always fits whole.

  The values are never on disk and never logged. They travel as
  `PastedValues`, whose `inspect` shows none of them, and `format_status/1`
  leaves the held values and the message being handled out of a crash report.
  """

  use GenServer

  alias FermixCore.Management.McpServers.PastedValues

  @ttl_ms 600_000
  @max_held 64
  @id_bytes 12

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "How long an id is held after its draft."
  @spec ttl_ms() :: pos_integer()
  def ttl_ms, do: @ttl_ms

  @doc "The most ids held at once."
  @spec max_held() :: pos_integer()
  def max_held, do: @max_held

  @doc "Holds one draft's values and answers the id that names them."
  @spec hold(GenServer.server(), PastedValues.t()) :: String.t()
  def hold(server, %PastedValues{} = values), do: GenServer.call(server, {:hold, values})

  @doc "Whether `id` names values held now: issued in this boot, not expired, not taken."
  @spec held?(GenServer.server(), String.t()) :: boolean()
  def held?(server, id) when is_binary(id), do: GenServer.call(server, {:held?, id})

  @doc "The values `id` names, forgotten as they are handed over."
  @spec take(GenServer.server(), String.t()) :: {:ok, PastedValues.t()} | :error
  def take(server, id) when is_binary(id), do: GenServer.call(server, {:take, id})

  @impl true
  def init(opts) do
    {:ok,
     %{
       held: %{},
       order: [],
       ttl_ms: Keyword.get(opts, :ttl_ms, @ttl_ms),
       max_held: Keyword.get(opts, :max_held, @max_held)
     }}
  end

  @impl true
  def handle_call({:hold, values}, _from, state) do
    id = "draft:" <> Base.url_encode64(:crypto.strong_rand_bytes(@id_bytes), padding: false)
    timer = Process.send_after(self(), {:expire, id}, state.ttl_ms)
    state = %{state | held: Map.put(state.held, id, {values, timer}), order: state.order ++ [id]}
    {:reply, id, within_bound(state)}
  end

  def handle_call({:held?, id}, _from, state), do: {:reply, Map.has_key?(state.held, id), state}

  def handle_call({:take, id}, _from, state) do
    case Map.fetch(state.held, id) do
      {:ok, {values, timer}} ->
        Process.cancel_timer(timer)
        {:reply, {:ok, values}, forget(state, id)}

      :error ->
        {:reply, :error, state}
    end
  end

  @impl true
  def handle_info({:expire, id}, state), do: {:noreply, forget(state, id)}

  @impl true
  def format_status(status) do
    status
    |> Map.replace_lazy(:state, &printable/1)
    |> Map.replace_lazy(:message, &kind/1)
  end

  defp printable(%{held: held}), do: %{held: map_size(held)}
  defp printable(_state), do: :redacted

  defp kind(message) when is_tuple(message) and tuple_size(message) > 0, do: elem(message, 0)
  defp kind(_message), do: :message

  defp within_bound(%{order: order, max_held: max} = state) when length(order) > max do
    [oldest | _rest] = order
    {_values, timer} = Map.fetch!(state.held, oldest)
    Process.cancel_timer(timer)
    within_bound(forget(state, oldest))
  end

  defp within_bound(state), do: state

  defp forget(state, id),
    do: %{state | held: Map.delete(state.held, id), order: List.delete(state.order, id)}
end
