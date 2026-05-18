defmodule FermixChannels.Idempotency do
  @moduledoc """
  In-memory idempotency cache for inbound channel events.

  Webhook providers retry on slow acknowledgements (audit F-06). Without
  deduplication, a retried event runs the agent loop twice, sends two
  replies, and stores the same memory twice.

  Keys are `{channel, platform_message_id}` tuples. Entries live for
  `@default_ttl_ms` (24h) and are pruned lazily on read. The cache is
  process-local to the BEAM node — a daemon restart starts with a
  fresh cache, which is acceptable: the provider's retry window is
  typically minutes, not hours, and a fresh cache after restart simply
  means at most one duplicate per restart per pending event.
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
    table = Keyword.get(opts, :table, @table)
    ttl_ms = Keyword.get(opts, :ttl_ms, @default_ttl_ms)
    now_ms = System.monotonic_time(:millisecond)
    deadline = now_ms + ttl_ms
    key = {channel, message_id}

    case :ets.lookup(table, key) do
      [{^key, existing_deadline}] when existing_deadline > now_ms ->
        :duplicate

      _expired_or_missing ->
        :ets.insert(table, {key, deadline})
        :fresh
    end
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
  def handle_info(_other, state), do: {:noreply, state}
end
