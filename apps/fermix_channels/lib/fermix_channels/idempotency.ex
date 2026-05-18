defmodule FermixChannels.Idempotency do
  @moduledoc """
  In-memory idempotency cache for inbound channel events.

  Webhook providers retry on slow acknowledgements (audit F-06). Without
  deduplication, a retried event runs the agent loop twice, sends two
  replies, and stores the same memory twice.

  Keys are `{channel, platform_message_id}` tuples. Entries live for
  `@default_ttl_ms` (24h). The cache is process-local to the BEAM node:
  a daemon restart starts fresh, which is acceptable since provider
  retry windows are typically minutes, not hours.

  Atomicity model (audit F-06 second-pass review):

  The check-and-set runs inside the GenServer's `handle_call/3`, so
  concurrent callers are serialized by the BEAM mailbox. There is no
  in-flight window where two callers can both observe the same state
  and both decide they are `:fresh` — the prior `:ets.insert_new` + a
  later `:ets.insert` for the expired-entry path had exactly that
  window (review at audit follow-up commit 88e1eb6). The throughput
  cost — one GenServer.call per inbound webhook message — is fine for
  the single-user daemon's QPS budget, and the simplicity is worth
  more than a clever ETS CAS at this scale.

  ETS is still used as the storage backend so reads outside the
  GenServer (e.g. operational dashboards) can `:ets.tab2list/1` the
  table without blocking the writer.
  """

  use GenServer

  @table __MODULE__.Table
  @default_ttl_ms 24 * 60 * 60 * 1_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Returns `:fresh` if this is the first time we have seen the key, or
  `:duplicate` if it has been seen within the TTL. The check-and-set is
  atomic from the caller's perspective; concurrent callers with the
  same key will see exactly one `:fresh` and the rest `:duplicate`.
  """
  @spec check_and_record(atom(), term(), keyword()) :: :fresh | :duplicate
  def check_and_record(channel, message_id, opts \\ [])
      when is_atom(channel) and not is_nil(message_id) do
    server = Keyword.get(opts, :server, __MODULE__)
    ttl_ms = Keyword.get(opts, :ttl_ms, @default_ttl_ms)
    GenServer.call(server, {:check_and_record, {channel, message_id}, ttl_ms})
  end

  @doc """
  Removes a previously-recorded entry. Used by the webhook controller to
  roll back the idempotency record when the async dispatch task fails to
  start — without this, a failed start_child would silently burn the
  message id and suppress the provider's retry. (Audit F-06 follow-up.)
  """
  @spec forget(atom(), term(), keyword()) :: :ok
  def forget(channel, message_id, opts \\ [])
      when is_atom(channel) and not is_nil(message_id) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:forget, {channel, message_id}})
  end

  @impl true
  def init(opts) do
    table = Keyword.get(opts, :table, @table)

    case :ets.whereis(table) do
      :undefined ->
        :ets.new(table, [:named_table, :public, :set, read_concurrency: true])

      _existing ->
        :ok
    end

    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:check_and_record, key, ttl_ms}, _from, state) do
    now_ms = System.monotonic_time(:millisecond)
    deadline = now_ms + ttl_ms

    result =
      case :ets.lookup(state.table, key) do
        [{^key, existing}] when existing > now_ms ->
          :duplicate

        _missing_or_expired ->
          :ets.insert(state.table, {key, deadline})
          :fresh
      end

    {:reply, result, state}
  end

  def handle_call({:forget, key}, _from, state) do
    :ets.delete(state.table, key)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(_other, state), do: {:noreply, state}
end
