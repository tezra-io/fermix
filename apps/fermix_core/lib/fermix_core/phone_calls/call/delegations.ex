defmodule FermixCore.PhoneCalls.Call.Delegations do
  @moduledoc """
  The delegation slots of one phone call (M94 §07, §10): at most
  `Limits.max_active_delegations/0` running and
  `Limits.max_pending_delegations/0` waiting. Pure; `PhoneCalls.Call` owns the
  turns, the timers and the wire.

  A delegation id is taken once: the same id again is a duplicate whether it
  is running, waiting, finished or was refused, so one request never runs two
  turns. Live delegations carry no revised text, so every record runs under
  revision 1; the revision still rides with each turn and fences its answer.

  Each started turn gets its own handle, minted by the worker. A control a
  turn presents is accepted only for a running record's handle; a handle of a
  turn that has finished, timed out or been stopped is `:stale_handle`, any
  other `:bad_handle`. Handles are compared in constant time.

  Both remembered lists are bounded (`Limits.max_remembered_delegations/0`):
  an id or handle past the bound is forgotten, the oldest first. Every started turn consumes one of
  the call's `Limits.max_core_turns_per_call/0`, so the handles never reach
  it; the ids are bounded against a stream of delegation events.

  Why not `Realtime.LiveDelegation`, whose two-slot rule this is: the rule is
  the same, but its record is not. LiveDelegation fixes one running and one
  waiting slot in its own code, where a phone call's slots are
  `PhoneCalls.Limits`'; it requires every delegation to carry an offset,
  where a phone call's delegation event may carry none (`OpenAILive.Events`
  never fills one in); it revises a delegation in place for Grok's re-asked
  tasks, which GPT-Live has no event for; and it holds no handle, which is
  what fences a phone call's in-call controls. Reusing it would mean
  inventing offsets and keeping the handles beside it, a second state for one
  slot.
  """

  alias FermixCore.PhoneCalls.Limits

  @revision 1

  defstruct active: [], pending: [], seen: [], retired: []

  @type record :: %{id: String.t(), revision: pos_integer(), handle: String.t() | nil}
  @type t :: %__MODULE__{
          active: [record()],
          pending: [record()],
          seen: [String.t()],
          retired: [String.t()]
        }

  @doc "No delegations yet."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Takes a new delegation: `{:active, record, state}` when a running slot is
  free, `{:pending, record, state}` when it waits, `{:full, state}` when both
  are taken (it is refused, not queued) and `{:duplicate, state}` for an id
  already taken.
  """
  @spec create(t(), String.t()) ::
          {:active | :pending, record(), t()} | {:full, t()} | {:duplicate, t()}
  def create(%__MODULE__{} = state, id) when is_binary(id) and id != "" do
    record = %{id: id, revision: @revision, handle: nil}
    seen = remember(state.seen, id)

    cond do
      id in state.seen ->
        {:duplicate, state}

      length(state.active) < Limits.max_active_delegations() ->
        {:active, record, %{state | active: state.active ++ [record], seen: seen}}

      length(state.pending) < Limits.max_pending_delegations() ->
        {:pending, record, %{state | pending: state.pending ++ [record], seen: seen}}

      true ->
        {:full, %{state | seen: seen}}
    end
  end

  @doc "Records the handle of the turn a running record started."
  @spec start(t(), String.t(), String.t()) :: {:ok, t()} | :error
  def start(%__MODULE__{} = state, id, handle) when is_binary(id) and is_binary(handle) do
    case Enum.split_with(state.active, &(&1.id == id)) do
      {[record], others} -> {:ok, %{state | active: others ++ [%{record | handle: handle}]}}
      {[], _others} -> :error
    end
  end

  @doc """
  Ends a running record, only when `id` and `revision` are current:
  `{:ok, record, state}`, its handle retired; `:stale` for anything else, so
  a late or repeated answer changes nothing.
  """
  @spec finish(t(), String.t(), pos_integer()) :: {:ok, record(), t()} | :stale
  def finish(%__MODULE__{} = state, id, revision) when is_binary(id) and is_integer(revision) do
    case Enum.split_with(state.active, &(&1.id == id and &1.revision == revision)) do
      {[record], others} -> {:ok, record, retire(%{state | active: others}, [record])}
      {[], _others} -> :stale
    end
  end

  @doc "Moves the oldest waiting record into a free running slot."
  @spec promote(t()) :: {:ok, record(), t()} | :none
  def promote(%__MODULE__{active: active, pending: [next | rest]} = state) do
    if length(active) < Limits.max_active_delegations(),
      do: {:ok, next, %{state | active: active ++ [next], pending: rest}},
      else: :none
  end

  def promote(%__MODULE__{pending: []}), do: :none

  @doc "Stops everything: the running records (to cancel) and the waiting ones, dropped."
  @spec stop_all(t()) :: {[record()], t()}
  def stop_all(%__MODULE__{} = state) do
    {state.active, retire(%{state | active: [], pending: []}, state.active)}
  end

  @doc "Whether `id` and `revision` name a running record."
  @spec current?(t(), String.t(), pos_integer()) :: boolean()
  def current?(%__MODULE__{} = state, id, revision),
    do: Enum.any?(state.active, &(&1.id == id and &1.revision == revision))

  @doc "Whether anything runs or waits."
  @spec busy?(t()) :: boolean()
  def busy?(%__MODULE__{active: active, pending: pending}), do: active != [] or pending != []

  @doc """
  The running record whose turn presented `handle`, or why there is none:
  `:stale_handle` for a retired turn's, `:bad_handle` otherwise.
  """
  @spec check_handle(t(), term()) :: {:ok, record()} | {:error, :bad_handle | :stale_handle}
  def check_handle(%__MODULE__{} = state, handle) when is_binary(handle) do
    cond do
      record = Enum.find(state.active, &same?(&1.handle, handle)) -> {:ok, record}
      Enum.any?(state.retired, &same?(&1, handle)) -> {:error, :stale_handle}
      true -> {:error, :bad_handle}
    end
  end

  def check_handle(%__MODULE__{}, _handle), do: {:error, :bad_handle}

  @doc "The slots as a status prints them: counts, ids and revisions, never a handle."
  @spec printable(t()) :: map()
  def printable(%__MODULE__{} = state) do
    %{
      active: Enum.map(state.active, &printable_record/1),
      pending: Enum.map(state.pending, &printable_record/1),
      seen: length(state.seen),
      retired: length(state.retired)
    }
  end

  defp printable_record(%{handle: nil} = record), do: record
  defp printable_record(record), do: %{record | handle: :redacted}

  @doc "The revision every phone delegation runs under."
  @spec revision() :: pos_integer()
  def revision, do: @revision

  defp retire(state, records) do
    handles = for %{handle: handle} <- records, is_binary(handle), do: handle
    %{state | retired: Enum.take(handles ++ state.retired, Limits.max_remembered_delegations())}
  end

  defp remember(seen, id), do: Enum.take([id | seen], Limits.max_remembered_delegations())

  defp same?(known, given) when is_binary(known) and byte_size(known) == byte_size(given),
    do: :crypto.hash_equals(known, given)

  defp same?(_known, _given), do: false
end
