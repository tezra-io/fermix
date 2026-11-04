defmodule FermixChannels.Companion.Checklists do
  @moduledoc """
  What one companion connection holds of the owner's lists (M85 §07), and the
  wire shapes of what it sends: pure, kept in the connection's own state, so
  lists add no process.

  A connection that pulled the index (`index_pulled/1`) hears every change as
  the whole index again; one that pulled a list holds it (`hold/3`), at most
  16, the oldest let go, and hears every committed change to it as the whole
  list. A change is marked pending (`changed/2`) and every pending push goes
  out when the connection's window ends (`take_due/1`), so a burst of edits is
  one push per list carrying its final rev, and `made` carries what each of a
  device's adds or creates made, at most 100 a list. A device drops a push
  whose rev is below the one it shows: every push is whole state, never a
  delta.
  """

  @max_held 16
  @max_made 100

  @type t :: %{
          index?: boolean(),
          held: [String.t()],
          with_removed: MapSet.t(String.t()),
          pending: %{String.t() => %{String.t() => String.t()}},
          index_pending?: boolean(),
          timer: reference() | nil
        }

  @doc "The most lists one connection holds."
  @spec max_held() :: pos_integer()
  def max_held, do: @max_held

  @spec new() :: t()
  def new,
    do: %{
      index?: false,
      held: [],
      with_removed: MapSet.new(),
      pending: %{},
      index_pending?: false,
      timer: nil
    }

  @doc "Whether the connection pulled the index: its client draws lists."
  @spec draws?(t()) :: boolean()
  def draws?(%{index?: index?}), do: index?

  @spec index_pulled(t()) :: t()
  def index_pulled(lists), do: %{lists | index?: true}

  @doc """
  Holds `list_id` as the newest, with its removed rows when `removed?`; past
  #{@max_held} the oldest is let go, with anything pending for it.
  """
  @spec hold(t(), String.t(), boolean()) :: t()
  def hold(lists, list_id, removed?) when is_binary(list_id) and is_boolean(removed?) do
    held = List.delete(lists.held, list_id) ++ [list_id]
    {gone, kept} = Enum.split(held, max(length(held) - @max_held, 0))

    with_removed =
      if removed?,
        do: MapSet.put(lists.with_removed, list_id),
        else: MapSet.delete(lists.with_removed, list_id)

    %{
      lists
      | held: kept,
        with_removed: Enum.reduce(gone, with_removed, &MapSet.delete(&2, &1)),
        pending: Map.drop(lists.pending, gone)
    }
  end

  @spec let_go(t(), String.t()) :: t()
  def let_go(lists, list_id) do
    %{
      lists
      | held: List.delete(lists.held, list_id),
        with_removed: MapSet.delete(lists.with_removed, list_id),
        pending: Map.delete(lists.pending, list_id)
    }
  end

  @doc """
  Marks what `changes` (`[%{list_id, rev, made}]`) move: each held list, with
  what it made, and the index when it was pulled. Answers whether anything is
  now pending.
  """
  @spec changed(t(), [map()]) :: {t(), boolean()}
  def changed(lists, changes) when is_list(changes) do
    pending =
      Enum.reduce(changes, lists.pending, fn %{list_id: id} = change, pending ->
        if id in lists.held,
          do: Map.update(pending, id, made(%{}, change), &made(&1, change)),
          else: pending
      end)

    lists = %{lists | pending: pending, index_pending?: lists.index_pending? or lists.index?}
    {lists, pending?(lists)}
  end

  @doc "Marks one held list pending with what a duplicate edit had made."
  @spec redeliver(t(), String.t(), String.t(), String.t() | nil) :: {t(), boolean()}
  def redeliver(lists, list_id, client_msg_id, made_id) do
    made = if made_id, do: %{client_msg_id => made_id}, else: %{}
    changed(lists, [%{list_id: list_id, made: made}])
  end

  defp made(kept, %{made: made}) when map_size(kept) >= @max_made or map_size(made) == 0,
    do: kept

  defp made(kept, %{made: made}), do: Map.merge(kept, made)
  defp made(kept, _change), do: kept

  defp pending?(lists), do: lists.pending != %{} or lists.index_pending?

  @doc """
  What the ended window sends: each pending list, oldest held first, with
  whether to send its removed rows and what it made, and whether to send the
  index. The state comes back with nothing pending and no timer.
  """
  @spec take_due(t()) :: {[{String.t(), boolean(), map()}], boolean(), t()}
  def take_due(lists) do
    due =
      for id <- lists.held,
          Map.has_key?(lists.pending, id),
          do: {id, MapSet.member?(lists.with_removed, id), Map.fetch!(lists.pending, id)}

    {due, lists.index_pending?, %{lists | pending: %{}, index_pending?: false, timer: nil}}
  end

  @doc "Whether `list_id` is held, with its removed rows."
  @spec with_removed?(t(), String.t()) :: boolean()
  def with_removed?(lists, list_id), do: MapSet.member?(lists.with_removed, list_id)

  # --- the wire's shapes --------------------------------------------------------------

  @doc "The `checklists` payload: the index, in picker order."
  @spec index_payload(String.t(), [map()]) :: map()
  def index_payload(profile_id, lists) do
    %{"profile_id" => profile_id, "lists" => Enum.map(lists, &index_entry/1)}
  end

  defp index_entry(list) do
    %{
      "list_id" => list.id,
      "title" => list.title,
      "open" => list.open,
      "done" => list.done,
      "rev" => list.rev
    }
    |> put_present("folder", list.folder)
  end

  @doc """
  The `checklist` payload: the whole list in order, its removed rows when
  `removed?`, `removed_at` when the list itself was removed, and `made` when
  a device's add or create made something.
  """
  @spec list_payload(String.t(), map(), boolean(), map()) :: map()
  def list_payload(profile_id, %{list: list, rows: rows} = snapshot, removed?, made) do
    wire_list =
      %{
        "list_id" => list.id,
        "title" => list.title,
        "rev" => list.rev,
        "rows" => Enum.map(rows, &row/1)
      }
      |> put_present("removed_at", stamp(list.removed_at))
      |> put_removed(removed?, Map.get(snapshot, :removed_rows, []))

    %{"profile_id" => profile_id, "list" => wire_list}
    |> then(&if(made == %{}, do: &1, else: Map.put(&1, "made", made)))
  end

  defp put_removed(list, false, _rows), do: list

  defp put_removed(list, true, rows),
    do:
      Map.put(
        list,
        "removed",
        Enum.map(rows, &Map.put(row(&1), "removed_at", stamp(&1.removed_at)))
      )

  defp row(%{kind: :section} = row),
    do: %{"row_id" => row.id, "kind" => "section", "text" => row.text}

  defp row(%{kind: :item} = row) do
    %{"row_id" => row.id, "kind" => "item", "text" => row.text, "done" => row.done}
    |> put_present("note", row.note)
    |> put_present("done_at", stamp(row.done_at))
  end

  defp stamp(nil), do: nil
  defp stamp(%DateTime{} = at), do: DateTime.to_iso8601(at)

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
