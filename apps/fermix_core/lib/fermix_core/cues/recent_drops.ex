defmodule FermixCore.Cues.RecentDrops do
  @moduledoc """
  The last 50 stream items each watcher's filter dropped
  (M60_CUE_INTAKE_AT_SCALE.md §3.2), kept in memory only so the owner can still
  say "that one should have passed": `list_cues` lists them, and labelling one
  stores that item and the example together.

  A protected ETS table that `Cues.LiveFilters` creates and alone writes, so a
  reader never waits on that process. It is gone after a restart, with the
  live queues; while cues are off there is no table and every read is empty.
  """

  alias FermixCore.Cues.Item

  @table :fermix_cue_recent_drops
  @keep 50

  @type drop :: %{
          key: pos_integer(),
          at: DateTime.t(),
          source_ref: String.t(),
          item: Item.t(),
          reason: String.t()
        }

  @doc "Creates the table; called once by its owner, `Cues.LiveFilters`."
  @spec new_table() :: :ets.table()
  def new_table, do: :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])

  @doc "Keeps a drop for `watcher_id`, its newest; the oldest past 50 goes."
  @spec put(String.t(), Item.t(), String.t(), String.t(), DateTime.t()) :: drop()
  def put(watcher_id, %Item{} = item, source_ref, reason, %DateTime{} = at)
      when is_binary(watcher_id) and is_binary(source_ref) and is_binary(reason) do
    drop = %{
      key: System.unique_integer([:positive, :monotonic]),
      at: at,
      source_ref: source_ref,
      item: item,
      reason: reason
    }

    true = :ets.insert(@table, {watcher_id, Enum.take([drop | list(watcher_id)], @keep)})
    drop
  end

  @doc "A watcher's recent drops, newest first."
  @spec list(String.t()) :: [drop()]
  def list(watcher_id) when is_binary(watcher_id) do
    case :ets.whereis(@table) do
      :undefined -> []
      _table -> lookup(watcher_id)
    end
  end

  @doc "One recent drop by its key."
  @spec fetch(String.t(), pos_integer()) :: {:ok, drop()} | :error
  def fetch(watcher_id, key) when is_binary(watcher_id) and is_integer(key) do
    case Enum.find(list(watcher_id), &(&1.key == key)) do
      nil -> :error
      drop -> {:ok, drop}
    end
  end

  @doc "Forgets a watcher's drops (it was removed)."
  @spec forget(String.t()) :: true
  def forget(watcher_id) when is_binary(watcher_id), do: :ets.delete(@table, watcher_id)

  defp lookup(watcher_id) do
    case :ets.lookup(@table, watcher_id) do
      [{^watcher_id, drops}] -> drops
      [] -> []
    end
  end
end
