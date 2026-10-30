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

  An in-call record (M84, `AccessGate.ask_in_call/3`) holds no call to run: it
  names the process that waits inside its own tool call for the owner's answer.
  The store monitors that process, and the record ends when the answer is sent
  to it (`answer_in_call/2`, `deny/2`), when it closes its own wait
  (`close_in_call/2`), when the window passes, or when the process dies: `/stop`
  kills the turn it waits in, and the `:DOWN` drops the record. An in-call
  record is never taken, never matched by a park, and never reported by
  `pending_from/2` or `voice_pending/2`, so nothing can run it as a call.
  """

  use GenServer

  require Logger

  @ttl_ms 60_000
  @max_live 64

  @type binding :: {:conversation, term()} | {:voice_call, String.t()}
  @type status :: :pending | :running | {:done, String.t()}

  @typedoc "A call waiting inside itself for the owner (`park_in_call/3`)."
  @type in_call_record :: %{
          id: String.t(),
          session_id: String.t() | nil,
          waiter: pid(),
          monitor: reference(),
          seq: non_neg_integer(),
          expires_at_ms: integer(),
          status: :in_call
        }

  @type record :: %{
          id: String.t(),
          tool: String.t(),
          args: map(),
          digest: String.t(),
          plugin: String.t() | nil,
          auth_profile: String.t() | nil,
          command_ref: term(),
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

  @doc """
  Record a call that waits for the owner inside its own process, `waiter`, and
  monitor it. `attrs` names the turn (`:session_id`) for the log. The id is the
  one the owner's prompt is bound to.
  """
  @spec park_in_call(%{session_id: String.t() | nil}, pid(), GenServer.server()) ::
          {:ok, String.t()} | {:error, :too_many_pending}
  def park_in_call(%{session_id: session_id}, waiter, server \\ __MODULE__)
      when (is_binary(session_id) or is_nil(session_id)) and is_pid(waiter) do
    GenServer.call(server, {:park_in_call, session_id, waiter})
  end

  @doc """
  The owner's yes to an in-call record: sends `{:access_answer, id, :confirmed}`
  to its waiting process and ends the record. `{:error, :not_in_call}` when `id`
  names no live in-call record (a parked call, which `take/2` runs, an ended
  wait, or a waiter that is gone, whose record is dropped here).
  """
  @spec answer_in_call(String.t(), GenServer.server()) :: :ok | {:error, :not_in_call}
  def answer_in_call(id, server \\ __MODULE__) when is_binary(id),
    do: GenServer.call(server, {:answer_in_call, id})

  @doc """
  The owner's no, answered with the kind of record it reached: an in-call
  record's waiter gets `{:access_answer, id, :denied}` (`{:ok, :in_call}`), and
  a parked call still waiting is dropped (`{:ok, :parked}`). `{:error,
  :not_found}` when neither waits (it ended, expired, or is already running).
  """
  @spec deny(String.t(), GenServer.server()) ::
          {:ok, :in_call | :parked} | {:error, :not_found}
  def deny(id, server \\ __MODULE__) when is_binary(id), do: GenServer.call(server, {:deny, id})

  @doc """
  The waiting process ends its own wait (its deadline passed, or the prompt
  never reached the owner). `{:error, :not_found}` when the record had already
  ended: an answer sent before it ended is then in the waiter's mailbox, since
  the store sends it before it replies here.
  """
  @spec close_in_call(String.t(), GenServer.server()) :: :ok | {:error, :not_found}
  def close_in_call(id, server \\ __MODULE__) when is_binary(id),
    do: GenServer.call(server, {:close_in_call, id})

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

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Enum.find(Map.values(state.records), &(Map.get(&1, :monitor) == ref)) do
      nil ->
        {:noreply, state}

      record ->
        Logger.info(
          "access_gate: intent #{record.id} dropped, its waiting call ended (#{inspect(reason)})"
        )

        {:noreply, %{state | records: Map.delete(state.records, record.id)}}
    end
  end

  # A record's snapshot carries the parking turn's session env (an ACP harness's
  # signing keys), and its arguments and a declared command's fixed args can carry
  # secrets, so a crash report or `:sys.get_status/1` shows only each record's
  # non-secret fields.
  @impl true
  def format_status(status) do
    Map.replace_lazy(status, :state, fn
      %{records: records} = state ->
        %{state | records: Map.new(records, fn {id, record} -> {id, printable(record)} end)}

      state ->
        state
    end)
  end

  defp printable(record) when is_map(record) do
    record
    |> Map.merge(%{args: :redacted, snapshot: :redacted})
    |> Map.update(:command_ref, nil, &printable_ref/1)
  end

  defp printable_ref({:command, executable, _args}), do: {:command, executable, :redacted}
  defp printable_ref(ref), do: ref

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

  defp handle({:park_in_call, session_id, waiter}, state) do
    if map_size(state.records) >= @max_live do
      {{:error, :too_many_pending}, state}
    else
      record = %{
        id: new_id(),
        session_id: session_id,
        waiter: waiter,
        monitor: Process.monitor(waiter),
        seq: state.seq,
        expires_at_ms: expiry(state),
        status: :in_call
      }

      {{:ok, record.id}, put_record(%{state | seq: state.seq + 1}, record)}
    end
  end

  defp handle({:answer_in_call, id}, state) do
    case answer_waiter(state, id, :confirmed) do
      {:answered, state} -> {:ok, state}
      {_not_waiting, state} -> {{:error, :not_in_call}, state}
    end
  end

  defp handle({:deny, id}, state) do
    case answer_waiter(state, id, :denied) do
      {:answered, state} -> {{:ok, :in_call}, state}
      {:gone, state} -> {{:error, :not_found}, state}
      {:not_in_call, state} -> discard_waiting(state, id)
    end
  end

  defp handle({:close_in_call, id}, state) do
    case Map.fetch(state.records, id) do
      {:ok, %{status: :in_call} = record} -> {:ok, drop_in_call(state, record)}
      _ended -> {{:error, :not_found}, state}
    end
  end

  defp handle({:tool, id}, state) do
    case Map.fetch(state.records, id) do
      {:ok, %{tool: tool}} -> {{:ok, tool}, state}
      _missing_or_in_call -> {:error, state}
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
    case Enum.find(Map.values(state.records), &parked_match?(&1, binding, digest)) do
      nil -> :none
      record -> {:ok, record}
    end
  end

  defp parked_match?(%{status: :in_call}, _binding, _digest), do: false

  defp parked_match?(record, binding, digest),
    do: record.binding == binding and record.digest == digest

  # The answer goes to a waiter only while it lives: one that died (its `:DOWN`
  # not yet handled) gets nothing, and its record is dropped here. The send
  # comes before this call's reply, so a waiter that closes its wait meanwhile
  # finds the answer in its mailbox.
  defp answer_waiter(state, id, answer) do
    case Map.fetch(state.records, id) do
      {:ok, %{status: :in_call, waiter: waiter} = record} ->
        {send_answer(waiter, Process.alive?(waiter), id, answer), drop_in_call(state, record)}

      _parked_or_missing ->
        {:not_in_call, state}
    end
  end

  defp send_answer(waiter, true, id, answer) do
    send(waiter, {:access_answer, id, answer})
    :answered
  end

  defp send_answer(_waiter, false, _id, _answer), do: :gone

  defp discard_waiting(state, id) do
    case Map.fetch(state.records, id) do
      {:ok, %{status: :pending}} ->
        {{:ok, :parked}, %{state | records: Map.delete(state.records, id)}}

      _running_done_or_missing ->
        {{:error, :not_found}, state}
    end
  end

  defp drop_in_call(state, %{id: id, monitor: monitor}) do
    Process.demonitor(monitor, [:flush])
    %{state | records: Map.delete(state.records, id)}
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
          :command_ref,
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

    {expired, live} =
      Map.split_with(state.records, fn {_id, record} -> record.expires_at_ms < now end)

    for {_id, %{status: :in_call, monitor: monitor}} <- expired,
        do: Process.demonitor(monitor, [:flush])

    %{state | records: live}
  end

  defp expiry(state), do: state.clock.() + @ttl_ms

  defp new_id, do: 8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
end
