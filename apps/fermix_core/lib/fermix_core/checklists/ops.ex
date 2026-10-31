defmodule FermixCore.Checklists.Ops do
  @moduledoc """
  What each op of a `checklist_edit` call does to the owner's lists
  (MILESTONE_85 §05, §06): pure functions over the rows one transaction
  loaded, run by `Memory.Repo.ChecklistsSql` inside that transaction, so the
  whole call lands or none of it does.

  `apply/3` takes the owner's live lists and the live rows of every list the
  call names (`referenced/2`), and the call's changes as
  `Checklists.Registry` normalized them, and answers the lists and rows as
  they now stand: which lists changed (each gets its `rev` moved once), the
  rows to write, the rows removed, and per list touched, in first-touch order,
  what happened in a few words and which rows the call added or changed.

  Rows keep their order by `position`, integers with gaps of 1,024; a row put
  between two neighbours takes the midpoint, and when no gap is left the
  whole list is numbered again. A row's `n` comes from its list's `next_n`,
  which only goes up, so a number is never reused within a list.

  After outside content a call may only add and check (§11, `@outside_ops`):
  every other op, `create` included, is refused, since a list's title is
  unstamped and the per-turn note names it on every owner turn. A row it adds
  is stamped, and the stamp is never cleared.

  A new section goes only at a section boundary, after a section's last row
  or at the end, so it never takes items from the section it lands in.

  A removed list's title is free at once, so another list may take it within
  the 30 days the removed one is kept: the wire's `restore`, when it comes,
  must meet that clash rather than let the store's unique index refuse it.

  Refusals are `{:error, {:op_failed, change, op, list, reason}}`, the change
  and the op counted from 1, which `Checklists.Registry.describe_error/1`
  turns into the sentence the model reads.
  """

  alias FermixCore.Checklists.Render

  @gap 1_024
  @max_lists 50
  # The only ops a call that read outside content may run (§11): an allow-list,
  # so an op added later is refused there until it is ruled on.
  @outside_ops [:add, :check]
  @max_rows 500
  @id_alphabet ~c"0123456789abcdefghjkmnpqrstvwxyz"
  @list_id ~r/\Ack_[0-9a-z]{10}\z/

  @typedoc "One list as the store holds it, with what this call did to it."
  @type list_meta :: %{
          required(:id) => String.t(),
          required(:title) => String.t(),
          required(:folder) => String.t() | nil,
          required(:position) => integer(),
          required(:rev) => non_neg_integer(),
          required(:next_n) => pos_integer(),
          optional(atom()) => term()
        }

  @typedoc "What `apply/3` hands back: the store's next state and the call's summary."
  @type result :: %{
          lists: %{String.t() => list_meta()},
          rows: %{String.t() => [map()]},
          removed_rows: [map()],
          changed: [String.t()],
          summary: [map()]
        }

  @doc "The most live lists an owner keeps."
  @spec max_lists() :: pos_integer()
  def max_lists, do: @max_lists

  @doc "The most live rows, sections and items together, a list holds."
  @spec max_rows() :: pos_integer()
  def max_rows, do: @max_rows

  @doc "A new id: `prefix` and ten lowercase base32 characters."
  @spec new_id(String.t()) :: String.t()
  def new_id(prefix) when prefix in ["ck_", "ci_"] do
    suffix =
      10
      |> :crypto.strong_rand_bytes()
      |> :binary.bin_to_list()
      |> Enum.map(&Enum.at(@id_alphabet, rem(&1, 32)))

    prefix <> List.to_string(suffix)
  end

  @doc """
  The live list `ref` names: its id, or its title compared case-blind, which
  names one list because titles are unique that way.
  """
  @spec resolve([list_meta()], String.t()) :: {:ok, list_meta()} | {:error, term()}
  def resolve(lists, ref) when is_list(lists) and is_binary(ref) do
    case Enum.find(lists, &names?(&1, ref)) do
      nil -> {:error, {:no_list, ref, Enum.map(lists, & &1.title)}}
      list -> {:ok, list}
    end
  end

  defp names?(list, ref) do
    if Regex.match?(@list_id, ref), do: list.id == ref, else: same_words?(list.title, ref)
  end

  @doc """
  The live lists in `folder`, compared case-blind, in picker order; a folder no
  list carries is refused with the folders that exist.
  """
  @spec folder_lists([list_meta()], String.t()) :: {:ok, [list_meta()]} | {:error, term()}
  def folder_lists(lists, folder) when is_list(lists) and is_binary(folder) do
    case Enum.filter(lists, &(is_binary(&1.folder) and same_words?(&1.folder, folder))) do
      [] -> {:error, {:no_folder, folder, folders(lists)}}
      members -> {:ok, members}
    end
  end

  @doc "The folders the lists carry, in the order their first list sits in the picker."
  @spec folders([list_meta()]) :: [String.t()]
  def folders(lists) when is_list(lists) do
    lists |> Enum.map(& &1.folder) |> Enum.reject(&is_nil/1) |> Enum.uniq()
  end

  @doc """
  The ids of the existing lists a call's `changes` name, as the list a change
  edits or a move's `to_list`, whose rows the transaction loads.
  """
  @spec referenced([list_meta()], [map()]) :: [String.t()]
  def referenced(lists, changes) when is_list(lists) and is_list(changes) do
    changes
    |> Enum.flat_map(fn change -> [change.list | Enum.flat_map(change.ops, &to_list/1)] end)
    |> Enum.flat_map(fn ref -> lists |> resolve(ref) |> found_id() end)
    |> Enum.uniq()
  end

  defp to_list(%{op: :move, to_list: ref}) when is_binary(ref), do: [ref]
  defp to_list(_op), do: []

  defp found_id({:ok, list}), do: [list.id]
  defp found_id({:error, _reason}), do: []

  @doc "A list's open and done item counts."
  @spec counts([map()]) :: {non_neg_integer(), non_neg_integer()}
  def counts(rows) when is_list(rows) do
    items = Enum.filter(rows, &(&1.kind == :item))
    done = Enum.count(items, & &1.done)
    {length(items) - done, done}
  end

  @doc """
  Applies `changes` to `state` (`%{lists: [list_meta], rows: %{id => rows}}`)
  under `edit` (`now`, `outside?`, `made_via`), all of them or none.
  """
  @spec apply(map(), [map()], map()) :: {:ok, result()} | {:error, term()}
  def apply(%{lists: lists, rows: rows}, changes, %{now: %DateTime{}} = edit)
      when is_list(lists) and is_map(rows) and is_list(changes) do
    initial = %{
      lists: Map.new(lists, &{&1.id, &1}),
      rows: rows,
      removed_rows: [],
      changed: [],
      order: [],
      events: %{},
      touched_rows: %{}
    }

    changes
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, initial}, &apply_change(&1, &2, edit))
    |> finish(edit)
  end

  defp apply_change({change, index}, {:ok, state}, edit) do
    case change_list(state, change, edit) do
      {:ok, {id, ops, offset}, state} ->
        ops |> Enum.with_index(offset) |> run_ops(id, state, edit) |> wrap(index, change)

      {:error, reason} ->
        {:halt, {:error, {:op_failed, index, change.list, 1, reason}}}
    end
  end

  defp wrap({:ok, state}, _index, _change), do: {:cont, {:ok, state}}

  defp wrap({:error, op_index, reason}, index, change),
    do: {:halt, {:error, {:op_failed, index, change.list, op_index, reason}}}

  # The list a change edits: one its first op creates, or an existing live one.
  defp change_list(state, %{list: title, ops: [%{op: :create} = create | rest]}, edit) do
    with :ok <- outside_allows(edit, create),
         {:ok, id, state} <- create(state, title, create, edit),
         do: {:ok, {id, rest, 2}, touch(state, id)}
  end

  defp change_list(state, %{list: ref, ops: ops}, _edit) do
    with {:ok, list} <- resolve(live(state), ref),
         do: {:ok, {list.id, ops, 1}, touch(state, list.id)}
  end

  defp run_ops(indexed, id, state, edit) do
    Enum.reduce_while(indexed, {:ok, state}, fn {op, op_index}, {:ok, acc} ->
      case op(acc, id, op, edit) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, op_index, reason}}
      end
    end)
  end

  # --- lists -----------------------------------------------------------------

  defp create(state, title, %{folder: folder}, edit) do
    lists = live(state)

    cond do
      length(lists) >= @max_lists -> {:error, :too_many_lists}
      title_taken?(lists, title, nil) -> {:error, {:title_taken, title}}
      true -> put_new_list(state, new_id("ck_"), {title, folder_spelling(lists, folder)}, edit)
    end
  end

  defp put_new_list(state, id, {title, folder}, edit) do
    last = state.lists |> Map.values() |> Enum.map(& &1.position) |> Enum.max(fn -> 0 end)

    list = %{
      id: id,
      title: title,
      folder: folder,
      position: last + @gap,
      rev: 0,
      next_n: 1,
      created_at: edit.now,
      updated_at: edit.now,
      removed_at: nil,
      created?: true
    }

    state =
      state
      |> put_in([:lists, id], list)
      |> put_in([:rows, id], [])
      |> changed(id)
      |> event(id, "created" <> folder_words(folder))

    {:ok, id, state}
  end

  defp folder_words(nil), do: ""
  defp folder_words(folder), do: " in " <> Render.quoted(folder)

  # Nothing reaches a list a call removed, and after outside content nothing
  # but an add or a check; a list's own ops come first, then its rows'.
  defp op(state, id, op, edit) do
    cond do
      op.op == :create -> {:error, :create_not_first}
      outside_allows(edit, op) != :ok -> {:error, :outside_content}
      list(state, id).removed_at -> {:error, :list_removed}
      op.op in [:folder, :rename, :remove_list] -> list_op(state, id, op, edit)
      true -> row_op(state, id, op, edit)
    end
  end

  defp list_op(state, id, %{op: :folder, text: folder}, _edit) do
    list = list(state, id)
    folder = folder_spelling(live(state), folder)

    if list.folder == folder,
      do: {:ok, event(state, id, "already" <> in_folder(folder))},
      else: {:ok, state |> update_list(id, folder: folder) |> event(id, moved_folder(folder))}
  end

  defp list_op(state, id, %{op: :rename, text: title}, _edit) do
    list = list(state, id)

    cond do
      list.title == title -> {:ok, event(state, id, "already named " <> Render.quoted(title))}
      title_taken?(live(state), title, id) -> {:error, {:title_taken, title}}
      true -> {:ok, state |> update_list(id, title: title) |> event(id, renamed(list))}
    end
  end

  defp list_op(state, id, %{op: :remove_list}, edit),
    do: {:ok, state |> update_list(id, removed_at: edit.now) |> event(id, "removed the list")}

  defp in_folder(nil), do: " in no folder"
  defp in_folder(folder), do: " in " <> Render.quoted(folder)

  defp moved_folder(nil), do: "taken out of its folder"
  defp moved_folder(folder), do: "put in " <> Render.quoted(folder)

  defp renamed(list), do: "renamed from " <> Render.quoted(list.title)

  # A folder is only the label its lists carry, compared case-blind, so a list
  # put in one that exists takes the spelling its lists already have.
  defp folder_spelling(_lists, nil), do: nil

  defp folder_spelling(lists, folder),
    do: Enum.find(folders(lists), folder, &same_words?(&1, folder))

  defp title_taken?(lists, title, except_id),
    do: Enum.any?(lists, &(&1.id != except_id and same_words?(&1.title, title)))

  defp update_list(state, id, fields) do
    state
    |> update_in([:lists, id], &Map.merge(&1, Map.new(fields)))
    |> changed(id)
  end

  # --- rows ------------------------------------------------------------------

  defp row_op(state, id, %{op: :add} = op, edit) do
    rows = rows(state, id)

    with :ok <- room(state, id),
         {:ok, index} <- place_index(rows, op) do
      {row, state} = new_row(state, id, :item, op, edit)

      state
      |> insert(id, index, row, edit.now)
      |> added(id, row, "added ")
      |> ok()
    end
  end

  defp row_op(state, id, %{op: done_op, n: n}, edit) when done_op in [:check, :uncheck] do
    with {:ok, index, row} <- item(rows(state, id), n) do
      set_done(state, id, {index, row}, done_op == :check, edit.now)
    end
  end

  defp row_op(state, id, %{op: :edit, n: n} = op, edit) do
    with {:ok, index, row} <- find(rows(state, id), n),
         :ok <- editable(row, op),
         :ok <- section_name_free(rows(state, id), row, op.text) do
      reworded = row |> reword(op) |> dirty(edit.now)

      state
      |> replace_row(id, index, reworded)
      |> event(id, "edited " <> handle(reworded))
      |> touch_row(id, reworded.id)
      |> changed(id)
      |> ok()
    end
  end

  defp row_op(state, id, %{op: :move, to_list: nil} = op, edit),
    do: move_within(state, id, op, edit)

  defp row_op(state, id, %{op: :move} = op, edit), do: move_across(state, id, op, edit)

  defp row_op(state, id, %{op: :section, text: text} = op, edit) do
    rows = rows(state, id)

    with :ok <- room(state, id),
         :ok <- section_name_free(rows, nil, text),
         {:ok, index} <- section_index(rows, op) do
      {row, state} = new_row(state, id, :section, %{text: text, note: nil}, edit)

      state
      |> insert(id, index, row, edit.now)
      |> added(id, row, "added section ")
      |> ok()
    end
  end

  defp row_op(state, id, %{op: :remove, n: n}, edit) do
    rows = rows(state, id)

    with {:ok, index, row} <- find(rows, n),
         :ok <- empty_section(rows, index, row) do
      removed = %{row | updated_at: edit.now} |> Map.put(:removed_at, edit.now)

      state
      |> put_rows(id, List.delete_at(rows, index))
      |> Map.update!(:removed_rows, &[removed | &1])
      |> event(id, "removed " <> handle(row))
      |> changed(id)
      |> ok()
    end
  end

  defp row_op(state, id, %{op: :replace} = op, edit) do
    list = list(state, id)

    with :ok <- current(list, op.rev),
         {:ok, plan} <- replacement(rows(state, id), op.rows) do
      replaced(state, id, plan, edit)
    end
  end

  defp ok(state), do: {:ok, state}

  defp added(state, id, row, verb) when is_binary(verb), do: added(state, id, row, {verb, ""})

  defp added(state, id, row, {verb, from}) do
    state
    |> event(id, verb <> handle(row) <> from <> under(rows(state, id), row))
    |> touch_row(id, row.id)
    |> changed(id)
  end

  defp new_row(state, id, kind, fields, edit) do
    list = list(state, id)

    row = %{
      id: new_id("ci_"),
      checklist_id: id,
      n: list.next_n,
      kind: kind,
      text: fields.text,
      note: fields.note,
      done: false,
      done_at: nil,
      position: 0,
      stamped: edit.outside?,
      made_via: edit.made_via,
      created_at: edit.now,
      updated_at: edit.now,
      dirty: :new
    }

    {row, put_in(state, [:lists, id, :next_n], list.next_n + 1)}
  end

  defp set_done(state, id, {_index, %{done: done} = row}, done, _now) do
    word = if done, do: " was already checked", else: " was not checked"
    {:ok, event(state, id, handle(row) <> word)}
  end

  defp set_done(state, id, {index, row}, done, now) do
    updated = dirty(%{row | done: done, done_at: if(done, do: now)}, now)
    verb = if done, do: "checked ", else: "unchecked "

    state
    |> replace_row(id, index, updated)
    |> event(id, verb <> handle(updated))
    |> touch_row(id, row.id)
    |> changed(id)
    |> ok()
  end

  defp editable(%{kind: :section, n: n}, %{note: note}) when note != :keep,
    do: {:error, {:note_on_section, n}}

  defp editable(_row, _op), do: :ok

  defp reword(row, %{text: text, note: :keep}), do: %{row | text: text || row.text}
  defp reword(row, %{text: text, note: note}), do: %{row | text: text || row.text, note: note}

  defp move_within(state, id, %{n: n} = op, edit) do
    with {:ok, index, row} <- item(rows(state, id), n),
         :ok <- not_self(op, n),
         :ok <- placed(op),
         rest = List.delete_at(rows(state, id), index),
         {:ok, target} <- place_index(rest, op) do
      moved = dirty(row, edit.now)
      state = state |> put_rows(id, rest) |> insert(id, target, moved, edit.now)

      state
      |> event(id, "moved " <> handle(moved) <> under(rows(state, id), moved))
      |> touch_row(id, moved.id)
      |> changed(id)
      |> ok()
    end
  end

  defp move_across(state, id, %{n: n, to_list: ref} = op, edit) do
    with {:ok, index, row} <- item(rows(state, id), n),
         {:ok, target} <- resolve(live(state), ref),
         :ok <- other_list(id, target.id),
         :ok <- room(state, target.id),
         {:ok, at} <- place_index(rows(state, target.id), op) do
      source = list(state, id)
      arrived = arrived(state, target.id, row, edit.now)

      state
      |> put_rows(id, List.delete_at(rows(state, id), index))
      |> event(id, "moved " <> handle(row) <> " to " <> Render.quoted(target.title))
      |> changed(id)
      |> touch(target.id)
      |> put_in([:lists, target.id, :next_n], arrived.n + 1)
      |> insert(target.id, at, arrived, edit.now)
      |> added(target.id, arrived, {"got ", " from " <> Render.quoted(source.title)})
      |> ok()
    end
  end

  defp arrived(state, target_id, row, now) do
    %{row | checklist_id: target_id, n: list(state, target_id).next_n, updated_at: now}
    |> Map.update!(:dirty, &(&1 || :changed))
  end

  defp not_self(%{after: n}, n), do: {:error, {:after_self, n}}
  defp not_self(_op, _n), do: :ok

  defp placed(%{section: nil, after: nil}), do: {:error, :move_needs_place}
  defp placed(_op), do: :ok

  defp other_list(id, id), do: {:error, :same_list}
  defp other_list(_id, _target), do: :ok

  defp empty_section(rows, index, %{kind: :section, n: n}) do
    case Enum.at(rows, index + 1) do
      %{kind: :item} -> {:error, {:section_not_empty, n}}
      _section_or_end -> :ok
    end
  end

  defp empty_section(_rows, _index, _item), do: :ok

  defp section_name_free(_rows, _row, nil), do: :ok

  defp section_name_free(rows, row, text) do
    if (row == nil or row.kind == :section) and section_named?(rows, text, row),
      do: {:error, {:section_exists, text}},
      else: :ok
  end

  defp section_named?(rows, text, row) do
    Enum.any?(rows, &(&1.kind == :section and &1 != row and same_words?(&1.text, text)))
  end

  # --- replace ---------------------------------------------------------------

  defp current(%{created?: true}, _rev), do: :ok
  defp current(%{rev: rev}, rev), do: :ok
  defp current(%{rev: current}, rev), do: {:error, {:stale, rev, current}}

  # Every numbered line names a live row of the same kind; a line with no
  # number is new; a live row no line names is removed.
  defp replacement(rows, parsed) do
    by_n = Map.new(rows, &{&1.n, &1})

    with {:ok, pairs} <- pair_lines(parsed, by_n), do: {:ok, plan(rows, pairs)}
  end

  defp pair_lines(parsed, by_n) do
    parsed
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
      case existing(by_n, line) do
        {:ok, row} -> {:cont, {:ok, [{line, row} | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> reversed()
  end

  defp reversed({:ok, pairs}), do: {:ok, Enum.reverse(pairs)}
  defp reversed({:error, reason}), do: {:error, reason}

  defp existing(_by_n, %{n: nil}), do: {:ok, nil}

  defp existing(by_n, %{n: n, kind: kind}) do
    case Map.fetch(by_n, n) do
      {:ok, %{kind: ^kind} = row} -> {:ok, row}
      {:ok, _other_kind} -> {:error, {:kind_changed, n}}
      :error -> {:error, {:no_row, n}}
    end
  end

  defp plan(rows, pairs) do
    named =
      pairs |> Enum.flat_map(fn {_line, row} -> List.wrap(row && row.id) end) |> MapSet.new()

    %{pairs: pairs, removed: Enum.reject(rows, &MapSet.member?(named, &1.id))}
  end

  defp replaced(state, id, %{pairs: pairs, removed: removed}, edit) do
    if length(pairs) > @max_rows do
      {:error, {:list_full, list(state, id).title}}
    else
      {rows, state, tally} = rebuild(state, id, pairs, edit)
      gone = Enum.map(removed, &(%{&1 | updated_at: edit.now} |> Map.put(:removed_at, edit.now)))

      state
      |> put_rows(id, renumber(rows, edit.now))
      |> Map.update!(:removed_rows, &(gone ++ &1))
      |> event(id, replaced_words(tally, length(gone)))
      |> changed(id)
      |> ok()
    end
  end

  defp rebuild(state, id, pairs, edit) do
    {rows, state, tally} =
      Enum.reduce(pairs, {[], state, %{added: 0, changed: 0, same: 0}}, fn pair,
                                                                           {acc, st, tally} ->
        {row, st, outcome} = rebuilt(st, id, pair, edit)
        {[row | acc], touch_if(st, id, row, outcome), Map.update!(tally, outcome, &(&1 + 1))}
      end)

    {Enum.reverse(rows), state, Map.delete(tally, :same)}
  end

  defp touch_if(state, _id, _row, :same), do: state
  defp touch_if(state, id, row, _added_or_changed), do: touch_row(state, id, row.id)

  defp rebuilt(state, id, {line, nil}, edit) do
    fields = %{text: line.text, note: line.note}

    {row, state} =
      new_row(state, id, line.kind, fields, %{edit | outside?: line.stamped})

    {%{row | done: line.done, done_at: if(line.done, do: edit.now)}, state, :added}
  end

  defp rebuilt(state, _id, {line, row}, edit) do
    updated = %{
      row
      | text: line.text,
        note: line.note,
        done: line.done,
        done_at: done_at(row, line.done, edit.now),
        stamped: row.stamped or line.stamped
    }

    if updated == row, do: {row, state, :same}, else: {dirty(updated, edit.now), state, :changed}
  end

  defp done_at(%{done: true, done_at: at}, true, _now), do: at
  defp done_at(_row, true, now), do: now
  defp done_at(_row, false, _now), do: nil

  defp replaced_words(tally, removed) do
    "replaced: #{tally.added} added, #{tally.changed} changed, #{removed} removed"
  end

  # --- where a row goes ------------------------------------------------------

  # An add or a move lands at the end of the named section, right after the
  # row `after` names, or with neither at the end of the list's first group:
  # the items above its first heading, or else its first section.
  defp place_index(rows, %{section: name}) when is_binary(name) do
    case Enum.find_index(rows, &(&1.kind == :section and same_words?(&1.text, name))) do
      nil -> {:error, {:no_section, name, section_names(rows)}}
      index -> {:ok, section_end(rows, index)}
    end
  end

  defp place_index(rows, %{after: n}) when is_integer(n) do
    with {:ok, index, _row} <- find(rows, n), do: {:ok, index + 1}
  end

  defp place_index([], _op), do: {:ok, 0}
  defp place_index([%{kind: :section} | _rest] = rows, _op), do: {:ok, section_end(rows, 0)}

  defp place_index(rows, _op),
    do: {:ok, Enum.find_index(rows, &(&1.kind == :section)) || length(rows)}

  # A new section goes right after the row `after` names when that row ends
  # its section (or the first group), or at the list's end: anywhere else it
  # would take the items below it.
  defp section_index(rows, %{after: n}) when is_integer(n) do
    with {:ok, index, _row} <- find(rows, n) do
      case Enum.at(rows, index + 1) do
        %{kind: :item} -> {:error, {:section_inside, n}}
        _section_or_end -> {:ok, index + 1}
      end
    end
  end

  defp section_index(rows, _op), do: {:ok, length(rows)}

  defp section_end(rows, index) do
    rows
    |> Enum.drop(index + 1)
    |> Enum.find_index(&(&1.kind == :section))
    |> case do
      nil -> length(rows)
      offset -> index + 1 + offset
    end
  end

  defp section_names(rows), do: for(%{kind: :section, text: text} <- rows, do: text)

  # The section an item sits under, for the answer: " under Active", or nothing.
  defp under(_rows, %{kind: :section}), do: ""

  defp under(rows, row) do
    rows
    |> Enum.take_while(&(&1.id != row.id))
    |> Enum.filter(&(&1.kind == :section))
    |> List.last()
    |> case do
      nil -> ""
      section -> " under " <> Render.words(section)
    end
  end

  defp insert(state, id, index, row, now) do
    rows = rows(state, id)
    previous = if index == 0, do: 0, else: Enum.at(rows, index - 1).position
    next = rows |> Enum.at(index) |> next_position(previous)

    placed =
      if next - previous >= 2,
        do: List.insert_at(rows, index, %{row | position: previous + div(next - previous, 2)}),
        else: rows |> List.insert_at(index, row) |> renumber(now)

    put_rows(state, id, placed)
  end

  defp next_position(nil, previous), do: previous + 2 * @gap
  defp next_position(row, _previous), do: row.position

  defp renumber(rows, now) do
    rows
    |> Enum.with_index(1)
    |> Enum.map(fn {row, i} -> renumbered(row, i * @gap, now) end)
  end

  defp renumbered(%{position: position} = row, position, _now), do: row
  defp renumbered(row, position, now), do: dirty(%{row | position: position}, now)

  # --- lookups and bookkeeping -----------------------------------------------

  defp find(rows, n) do
    case Enum.find_index(rows, &(&1.n == n)) do
      nil -> {:error, {:no_row, n}}
      index -> {:ok, index, Enum.at(rows, index)}
    end
  end

  defp item(rows, n) do
    case find(rows, n) do
      {:ok, _index, %{kind: :section}} -> {:error, {:not_an_item, n}}
      found -> found
    end
  end

  defp room(state, id) do
    if length(rows(state, id)) < @max_rows,
      do: :ok,
      else: {:error, {:list_full, list(state, id).title}}
  end

  defp outside_allows(%{outside?: true}, %{op: op}) when op not in @outside_ops,
    do: {:error, :outside_content}

  defp outside_allows(_edit, _op), do: :ok

  defp live(state),
    do: state.lists |> Map.values() |> Enum.filter(&is_nil(&1.removed_at)) |> sorted()

  defp sorted(lists), do: Enum.sort_by(lists, &{&1.position, &1.id})

  defp list(state, id), do: Map.fetch!(state.lists, id)
  defp rows(state, id), do: Map.fetch!(state.rows, id)
  defp put_rows(state, id, rows), do: put_in(state, [:rows, id], rows)

  defp replace_row(state, id, index, row),
    do: put_rows(state, id, List.replace_at(rows(state, id), index, row))

  defp dirty(row, now), do: %{row | updated_at: now, dirty: row.dirty || :changed}

  defp handle(row), do: "[#{row.n}] " <> Render.words(row)

  defp touch(state, id) do
    if id in state.order, do: state, else: %{state | order: state.order ++ [id]}
  end

  defp changed(state, id) do
    if id in state.changed, do: state, else: %{state | changed: state.changed ++ [id]}
  end

  defp event(state, id, words),
    do: update_in(state, [:events], &Map.update(&1, id, [words], fn kept -> kept ++ [words] end))

  defp touch_row(state, id, row_id) do
    update_in(state, [:touched_rows], fn touched ->
      Map.update(touched, id, [row_id], &if(row_id in &1, do: &1, else: &1 ++ [row_id]))
    end)
  end

  defp same_words?(a, b), do: String.downcase(String.trim(a)) == String.downcase(String.trim(b))

  # --- the end of the call ---------------------------------------------------

  # Each list the call changed moves its rev once; the summary is what the
  # call touched, in first-touch order.
  defp finish({:error, reason}, _edit), do: {:error, reason}

  defp finish({:ok, state}, edit) do
    lists =
      Enum.reduce(state.changed, state.lists, fn id, lists ->
        Map.update!(lists, id, &%{&1 | rev: &1.rev + 1, updated_at: edit.now})
      end)

    state = %{state | lists: lists}

    {:ok,
     %{
       lists: lists,
       rows: state.rows,
       removed_rows: state.removed_rows,
       changed: state.changed,
       summary: Enum.map(state.order, &summary(state, &1))
     }}
  end

  defp summary(state, id) do
    list = list(state, id)
    rows = rows(state, id)
    live_ids = MapSet.new(rows, & &1.id)
    {open, done} = counts(rows)

    %{
      list_id: id,
      title: list.title,
      folder: list.folder,
      rev: list.rev,
      open: open,
      done: done,
      removed?: not is_nil(list.removed_at),
      changed?: id in state.changed,
      events: Map.get(state.events, id, []),
      rows: state.touched_rows |> Map.get(id, []) |> Enum.filter(&MapSet.member?(live_ids, &1))
    }
  end
end
