defmodule FermixCore.Capabilities.AccessGate.Pending do
  @moduledoc """
  The parked access-sensitive calls waiting on the owner (`Capabilities.AccessGate`).

  A record is the exact call the owner is asked about — tool, arguments, the
  plugin and auth profile it ran against, and a snapshot of the parking turn's
  correlation context — so a confirmation runs precisely that call and nothing a
  model supplies later. The channel-side `/confirm` token lives in the sandbox
  confirmations store; this process holds the substance, the same split the
  vendor-config acknowledgment uses.

  One GenServer serializes every lookup and write, so two identical parks can
  never both be new and one record can never be taken twice. A record lives for
  the `/confirm` family's 60 seconds; parking the same call again while it waits
  answers `:existing` and restarts that window, because the gate may then have
  sent the owner a fresh token for it (the last one was denied or expired).
  Taking a record marks it running (`:running` to a re-park, never a second
  prompt); finishing it leaves a tombstone with the outcome for another window,
  so a model that calls the same command again learns it already ran instead of
  asking the owner twice. At most 64 records are live; expired rows are dropped
  on every call, and a restart forgets everything, which fails closed (the owner
  is asked again).
  """

  use GenServer

  @ttl_ms 60_000
  @max_live 64

  @type binding :: {:conversation, term()} | {:voice_call, String.t()}
  @type status :: :pending | :running | {:done, String.t()}

  @type record :: %{
          id: String.t(),
          tool: String.t(),
          args: map(),
          digest: String.t(),
          plugin: String.t() | nil,
          auth_profile: String.t() | nil,
          binding: binding(),
          sources: [String.t()],
          snapshot: map(),
          seq: non_neg_integer(),
          expires_at_ms: integer(),
          status: status()
        }

  @type park_result ::
          {:ok, String.t(), :new | :existing | :running}
          | {:ok, String.t(), {:done, String.t()}}
          | {:error, :too_many_pending}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "How long a parked call waits for the owner, in milliseconds."
  @spec ttl_ms() :: pos_integer()
  def ttl_ms, do: @ttl_ms

  @doc "The most records the store holds at once."
  @spec max_live() :: pos_integer()
  def max_live, do: @max_live

  @doc """
  Park a call, or find the live record for the same binding and arguments.
  `attrs` carries every `record()` field except `:id`, `:seq`, `:expires_at_ms`
  and `:status`, which the store assigns.
  """
  @spec park(map(), GenServer.server()) :: park_result()
  def park(%{binding: _binding, digest: digest} = attrs, server \\ __MODULE__)
      when is_binary(digest) do
    GenServer.call(server, {:park, attrs})
  end

  @doc "Take a pending record for its one confirmed run. Marks it running."
  @spec take(String.t(), GenServer.server()) :: {:ok, record()} | :error
  def take(id, server \\ __MODULE__) when is_binary(id), do: GenServer.call(server, {:take, id})

  @doc """
  Record a taken call's outcome as a tombstone for the next window. Only the
  record `take/2` returned is accepted, so a malformed one fails at the caller
  and never inside the store.
  """
  @spec finish(record(), String.t(), GenServer.server()) :: :ok
  def finish(%{id: id, status: :running} = record, outcome, server \\ __MODULE__)
      when is_binary(id) and is_binary(outcome) do
    GenServer.call(server, {:finish, record, outcome})
  end

  @doc "Drop a record the owner declined."
  @spec discard(String.t(), GenServer.server()) :: :ok
  def discard(id, server \\ __MODULE__) when is_binary(id),
    do: GenServer.call(server, {:discard, id})

  @doc "The command a live record names, whatever its status."
  @spec tool(String.t(), GenServer.server()) :: {:ok, String.t()} | :error
  def tool(id, server \\ __MODULE__) when is_binary(id), do: GenServer.call(server, {:tool, id})

  @doc "The newest pending record parked on voice call `call_id`."
  @spec voice_pending(String.t(), GenServer.server()) :: {:ok, String.t()} | :none
  def voice_pending(call_id, server \\ __MODULE__) when is_binary(call_id),
    do: GenServer.call(server, {:voice_pending, call_id})

  @doc """
  The newest record the turn (or voice call) `session_id` parked that still
  waits on the owner: whether that session may act again yet, and which
  command a Live delegation's own reply asked about.
  """
  @spec pending_from(String.t(), GenServer.server()) :: {:ok, String.t()} | :none
  def pending_from(session_id, server \\ __MODULE__) when is_binary(session_id),
    do: GenServer.call(server, {:pending_from, session_id})

  @impl true
  def init(opts) do
    clock = Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)
    {:ok, %{records: %{}, clock: clock, seq: 0}}
  end

  @impl true
  def handle_call(request, _from, state) do
    state = purge_expired(state)
    {reply, state} = handle(request, state)
    {:reply, reply, state}
  end

  defp handle({:park, attrs}, state) do
    case find_live(state, attrs.binding, attrs.digest) do
      {:ok, %{status: :pending} = record} -> refresh(record, state)
      {:ok, record} -> {existing_reply(record), state}
      :none -> insert(attrs, state)
    end
  end

  defp handle({:take, id}, state) do
    case Map.fetch(state.records, id) do
      {:ok, %{status: :pending} = record} ->
        running = %{record | status: :running, expires_at_ms: expiry(state)}
        {{:ok, running}, put_record(state, running)}

      _missing_or_used ->
        {:error, state}
    end
  end

  defp handle({:finish, record, outcome}, state) do
    tombstone = %{record | status: {:done, outcome}, expires_at_ms: expiry(state)}
    {:ok, put_record(state, tombstone)}
  end

  defp handle({:discard, id}, state),
    do: {:ok, %{state | records: Map.delete(state.records, id)}}

  defp handle({:tool, id}, state) do
    case Map.fetch(state.records, id) do
      {:ok, record} -> {{:ok, record.tool}, state}
      :error -> {:error, state}
    end
  end

  defp handle({:voice_pending, call_id}, state),
    do: {newest_pending(state, &(&1.binding == {:voice_call, call_id})), state}

  defp handle({:pending_from, session_id}, state),
    do: {newest_pending(state, &(Map.get(&1.snapshot, :session_id) == session_id)), state}

  defp newest_pending(state, matches) do
    state.records
    |> Map.values()
    |> Enum.filter(&(&1.status == :pending and matches.(&1)))
    |> Enum.max_by(& &1.seq, fn -> nil end)
    |> case do
      nil -> :none
      record -> {:ok, record.id}
    end
  end

  defp find_live(state, binding, digest) do
    case Enum.find(Map.values(state.records), &(&1.binding == binding and &1.digest == digest)) do
      nil -> :none
      record -> {:ok, record}
    end
  end

  defp refresh(record, state) do
    refreshed = %{record | expires_at_ms: expiry(state)}
    {{:ok, record.id, :existing}, put_record(state, refreshed)}
  end

  defp existing_reply(%{id: id, status: {:done, outcome}}), do: {:ok, id, {:done, outcome}}
  defp existing_reply(%{id: id, status: :running}), do: {:ok, id, :running}

  defp insert(attrs, state) do
    if map_size(state.records) >= @max_live do
      {{:error, :too_many_pending}, state}
    else
      id = new_id()

      record =
        attrs
        |> Map.take([
          :tool,
          :args,
          :digest,
          :plugin,
          :auth_profile,
          :binding,
          :sources,
          :snapshot
        ])
        |> Map.merge(%{id: id, seq: state.seq, expires_at_ms: expiry(state), status: :pending})

      {{:ok, id, :new}, put_record(%{state | seq: state.seq + 1}, record)}
    end
  end

  defp put_record(state, record),
    do: %{state | records: Map.put(state.records, record.id, record)}

  defp purge_expired(state) do
    now = state.clock.()
    live = Map.reject(state.records, fn {_id, record} -> record.expires_at_ms < now end)
    %{state | records: live}
  end

  defp expiry(state), do: state.clock.() + @ttl_ms

  defp new_id, do: 8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
end
