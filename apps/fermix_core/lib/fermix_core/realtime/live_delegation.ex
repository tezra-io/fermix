defmodule FermixCore.Realtime.LiveDelegation do
  @moduledoc """
  Authoritative task state for one Live call: at most one ACTIVE delegation and
  at most one PENDING one.

  Live can create delegations faster than a Fermix turn can answer them, and
  every one of them may run tools with real side effects. Two slots is the
  bound the design fixes (M41 §5.1): the operator's current request runs, their
  immediate correction queues behind it, and anything beyond that is refused out
  loud (`:too_many_pending`) rather than silently dropped or run three-deep.

  Duplicate detection is by delegation id and covers finished work too: Live
  re-emitting an id must never start the same task twice, which is the
  difference between a room booked once and a room booked twice.

  `revision` fences a re-asked task against a late answer to the earlier one. It
  is assigned here and carried through the bridge, the wire `task` frame and the
  turn's telemetry, so an answer that arrives after a correction can be
  recognised as stale by whoever reads it.

  Pure: the caller owns the bridge, the wire and the clock.
  """

  # Finished delegations are kept only to recognise a duplicate id. A call is
  # bounded by the max-session timer, so this is generous — and bounded anyway,
  # because an unbounded ledger in a long-lived process is how a leak starts.
  @max_finished 64

  @type status :: :created | :pending | :running | :completed | :failed | :cancelled

  @type record :: %{
          id: String.t(),
          offset_ms: non_neg_integer(),
          created_at_ms: integer(),
          revision: pos_integer(),
          status: status(),
          bridge_ref: term() | nil,
          summary: String.t() | nil
        }

  @type t :: %__MODULE__{
          active: record() | nil,
          pending: record() | nil,
          finished: [record()]
        }

  defstruct active: nil, pending: nil, finished: []

  @doc "Empty task state for a fresh call."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Register a delegation Live just created.

  `{:ok, state}` means it took a slot — the caller checks `active/1` to see
  whether it may start now or waits as pending.
  """
  @spec create(t(), String.t(), non_neg_integer(), integer()) ::
          {:ok, t()} | {:duplicate, t()} | {:rejected, :too_many_pending, t()}
  def create(%__MODULE__{} = state, id, offset_ms, now_ms)
      when is_binary(id) and id != "" and is_integer(offset_ms) and offset_ms >= 0 and
             is_integer(now_ms) do
    cond do
      known?(state, id) -> {:duplicate, state}
      is_nil(state.active) -> {:ok, %{state | active: record(id, offset_ms, now_ms, :created)}}
      is_nil(state.pending) -> {:ok, %{state | pending: record(id, offset_ms, now_ms, :pending)}}
      true -> {:rejected, :too_many_pending, state}
    end
  end

  @doc """
  Promote the pending delegation once the active slot is free.

  `:none` while work is still running — the caller starts exactly one delegation
  at a time and learns from here when the next may go.
  """
  @spec next_to_start(t()) :: {:ok, record(), t()} | :none
  def next_to_start(%__MODULE__{active: nil, pending: %{} = pending} = state) do
    promoted = %{pending | status: :created}
    {:ok, promoted, %{state | active: promoted, pending: nil}}
  end

  def next_to_start(%__MODULE__{}), do: :none

  @doc "Record that the delegation was submitted to the bridge under `revision`."
  @spec start(t(), String.t(), term(), pos_integer()) ::
          {:ok, t()} | {:error, :unknown_delegation}
  def start(%__MODULE__{} = state, id, bridge_ref, revision)
      when is_binary(id) and is_integer(revision) and revision >= 1 do
    update(state, id, fn record ->
      %{record | status: :running, bridge_ref: bridge_ref, revision: revision}
    end)
  end

  @doc "The delegation answered; `summary` is what the operator was told."
  @spec complete(t(), String.t(), String.t() | nil) ::
          {:ok, record(), t()} | {:error, :unknown_delegation}
  def complete(%__MODULE__{} = state, id, summary), do: finish(state, id, :completed, summary)

  @doc "The delegation could not be answered; `reason` is the recorded summary."
  @spec fail(t(), String.t(), String.t() | nil) ::
          {:ok, record(), t()} | {:error, :unknown_delegation}
  def fail(%__MODULE__{} = state, id, reason), do: finish(state, id, :failed, reason)

  @doc "The delegation was cancelled, from either slot."
  @spec cancel(t(), String.t()) :: {:ok, record(), t()} | {:error, :unknown_delegation}
  def cancel(%__MODULE__{} = state, id), do: finish(state, id, :cancelled, nil)

  @doc "The delegation currently owning the backend, if any."
  @spec active(t()) :: record() | nil
  def active(%__MODULE__{active: active}), do: active

  @doc "The delegation queued behind the active one, if any."
  @spec pending(t()) :: record() | nil
  def pending(%__MODULE__{pending: pending}), do: pending

  @doc "Active and pending records, in that order — everything teardown must settle."
  @spec in_flight(t()) :: [record()]
  def in_flight(%__MODULE__{} = state), do: Enum.reject([state.active, state.pending], &is_nil/1)

  @doc "Find a live (non-finished) delegation by id."
  @spec fetch(t(), String.t()) :: {:ok, record()} | :error
  def fetch(%__MODULE__{} = state, id) when is_binary(id) do
    case Enum.find(in_flight(state), &(&1.id == id)) do
      nil -> :error
      record -> {:ok, record}
    end
  end

  @doc "The revision a live delegation is running under, or `nil`."
  @spec revision_for(t(), String.t()) :: pos_integer() | nil
  def revision_for(%__MODULE__{} = state, id) when is_binary(id) do
    case fetch(state, id) do
      {:ok, record} -> record.revision
      :error -> nil
    end
  end

  defp finish(state, id, status, summary) when is_binary(id) do
    with {:ok, record} <- fetch(state, id) do
      finished = %{record | status: status, summary: summary}
      {:ok, finished, clear_slot(state, id, finished)}
    else
      :error -> {:error, :unknown_delegation}
    end
  end

  defp clear_slot(state, id, finished) do
    state
    |> drop_slot(id)
    |> Map.update!(:finished, &Enum.take([finished | &1], @max_finished))
  end

  defp drop_slot(%{active: %{id: id}} = state, id), do: %{state | active: nil}
  defp drop_slot(%{pending: %{id: id}} = state, id), do: %{state | pending: nil}

  defp update(state, id, fun) do
    case fetch(state, id) do
      {:ok, record} -> {:ok, put_slot(state, fun.(record))}
      :error -> {:error, :unknown_delegation}
    end
  end

  defp put_slot(%{active: %{id: id}} = state, %{id: id} = record), do: %{state | active: record}
  defp put_slot(%{pending: %{id: id}} = state, %{id: id} = record), do: %{state | pending: record}

  defp known?(state, id) do
    match?({:ok, _record}, fetch(state, id)) or Enum.any?(state.finished, &(&1.id == id))
  end

  defp record(id, offset_ms, now_ms, status) do
    %{
      id: id,
      offset_ms: offset_ms,
      created_at_ms: now_ms,
      revision: 1,
      status: status,
      bridge_ref: nil,
      summary: nil
    }
  end
end
