defmodule FermixChannels.Companion.Checklists do
  @moduledoc """
  The owner's lists as a kept kind on a companion connection (M85 §07, M89
  §07): the Registry calls a connection makes for them
  (`FermixCore.Checklists.Registry.device_index/2`, `device_list/4`,
  `device_edit/3`), and the wire shapes of what it sends, `checklists` (the
  index) and `checklist` (one whole list). What a connection holds of them
  and owes is `Companion.Kept`, the same for every kind.
  """

  @behaviour FermixChannels.Companion.KeptKind

  alias FermixCore.Checklists.Registry, as: ChecklistRegistry

  @impl true
  def index(caller, opts), do: ChecklistRegistry.device_index(caller, opts)

  @impl true
  def object(list_id, removed?, caller, opts),
    do: ChecklistRegistry.device_list(list_id, removed?, caller, opts)

  @impl true
  def edit(payload, caller, opts) do
    with {:ok, %{list_id: id, made: made, duplicate: duplicate?}} <-
           ChecklistRegistry.device_edit(payload, caller, opts),
         do: {:ok, %{id: id, made: made, duplicate: duplicate?}}
  end

  @impl true
  def describe_error(reason), do: ChecklistRegistry.describe_error(reason)

  # Swept away since it was pulled.
  @impl true
  def gone?(reason), do: match?({:no_such_list, _id}, reason)

  @impl true
  def index_event, do: "checklists"

  @impl true
  def object_event, do: "checklist"

  @impl true
  def id_field, do: "list_id"

  @impl true
  def flush_message, do: :checklists_flush

  @impl true
  def drawn_kind, do: :lists

  @impl true
  def block_type, do: "checklists"

  @impl true
  def draws_key, do: :draws_lists

  @impl true
  def draws_message, do: :list_channel_draws

  # --- the wire's shapes --------------------------------------------------------------

  @doc "The `checklists` payload: the index, in picker order."
  @impl true
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
  @impl true
  def object_payload(profile_id, %{list: list, rows: rows} = snapshot, removed?, made) do
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
