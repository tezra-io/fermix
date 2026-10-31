defmodule FermixCore.Checklists.Registry do
  @moduledoc """
  The one writer of the owner's lists (MILESTONE_85 §05, §06, §11): a module
  of functions over `Memory.Repo`, never a process. The model's tools, and
  later the Mac and the phone, read and change a list only through it.

  It owns:

    * **the gate** — `Checklists.Access`: the owner's private turn or voice
      call, or a scheduled job whose allowed tools name the tool;
    * **the shape of a call** — every change and op is checked here, in the
      caller, before the store is asked: at most 8 lists and 100 ops a call,
      each text within its bound and on one line, a `replace`'s markdown read
      into rows (`Checklists.Parse`);
    * **one transaction** — the call goes to the Repo whole, where
      `Checklists.Ops` applies it to the rows it loaded and every list it
      changed moves its `rev` once, or nothing changes;
    * **provenance** — a call on a turn that had read outside content stamps
      the rows whose words it writes, and its removals, replaces and moves to
      another list are refused (`Checklists.Ops`);
    * **the answers** — a read rendered as markdown (`Checklists.Render`), an
      edit's one line per list, and one sentence for every refusal
      (`describe_error/1`).

  Every read and edit emits its event (`Checklists.Telemetry`).

  Seams (`opts`): `:repo` (the Repo server; nil when the turn has none) and
  `:now`.
  """

  alias FermixCore.Checklists.Access
  alias FermixCore.Checklists.Ops
  alias FermixCore.Checklists.Parse
  alias FermixCore.Checklists.Render
  alias FermixCore.Checklists.Telemetry
  alias FermixCore.Memory.Repo

  @max_changes 8
  @max_ops 100
  @title_max 80
  @folder_max 40
  @text_max 280
  @note_max 1_000
  @markdown_max_bytes 262_144
  @ops ~w(create add check uncheck edit move section remove folder rename remove_list replace)
  # A line break, another control character, a line or paragraph separator,
  # or a bidi override: none belongs in one line of a list.
  @forbidden ~r/[\p{Cc}\p{Zl}\p{Zp}\x{202A}-\x{202E}\x{2066}-\x{2069}]/u

  @typedoc "A list a call read or changed, as a reply's block names it."
  @type touch :: %{list_id: String.t(), title: String.t(), rows: [String.t()]}

  @type answer :: %{text: String.t(), touched: [touch()]}

  @doc "The most lists one `checklist_edit` call changes."
  @spec max_changes() :: pos_integer()
  def max_changes, do: @max_changes

  @doc "The most ops one `checklist_edit` call carries."
  @spec max_ops() :: pos_integer()
  def max_ops, do: @max_ops

  # --- read ------------------------------------------------------------------

  @doc """
  Reads one list (`"list"`: its title or id), every list in a folder
  (`"folder"`), or with neither the index of every list with its counts, as
  markdown. `touched` names each list it returned, with no rows: a read
  changes none.
  """
  @spec read(map(), map(), keyword()) :: {:ok, answer()} | {:error, term()}
  def read(params, context, opts \\ []) when is_map(params) and is_map(context) do
    start = System.monotonic_time(:microsecond)
    scope = read_scope(params)
    result = with :ok <- gate(context, "checklist_read"), do: do_read(scope, context, opts)
    emit_read(context, scope, result, start)
    result
  end

  defp read_scope(%{"list" => list, "folder" => folder}) when list != nil and folder != nil,
    do: {:error, :list_and_folder}

  defp read_scope(%{"list" => list}) when is_binary(list), do: ref_scope(:list, list)
  defp read_scope(%{"folder" => folder}) when is_binary(folder), do: ref_scope(:folder, folder)
  defp read_scope(%{"list" => _not_text}), do: {:error, {:invalid_param, :list}}
  defp read_scope(%{"folder" => _not_text}), do: {:error, {:invalid_param, :folder}}
  defp read_scope(_params), do: {:ok, :index}

  defp ref_scope(kind, value) do
    case String.trim(value) do
      "" -> {:error, {:invalid_param, kind}}
      trimmed -> {:ok, {kind, trimmed}}
    end
  end

  defp do_read({:error, reason}, _context, _opts), do: {:error, reason}

  defp do_read({:ok, :index}, context, opts) do
    with {:ok, lists} <- store(context, opts, :index),
         do: {:ok, %{text: Render.index(lists), touched: []}}
  end

  defp do_read({:ok, {:list, ref}}, context, opts) do
    with {:ok, %{list: list, rows: rows}} <- store(context, opts, {:read_list, ref}) do
      {:ok, %{text: Render.list(list, rows), touched: [read_touch(list)]}}
    end
  end

  defp do_read({:ok, {:folder, name}}, context, opts) do
    with {:ok, entries} <- store(context, opts, {:read_folder, name}) do
      folder = entries |> hd() |> get_in([:list, :folder])
      touched = Enum.map(entries, &read_touch(&1.list))
      {:ok, %{text: Render.folder(folder, entries), touched: touched}}
    end
  end

  defp read_touch(list), do: %{list_id: list.id, title: list.title, rows: []}

  # --- edit ------------------------------------------------------------------

  @doc """
  Applies a `checklist_edit` call (`"changes"`: `[%{"list", "ops"}]`) in one
  transaction. The answer is one line per list the call touched, in the order
  it first touched them; `touched` names each with the rows the call added or
  changed.
  """
  @spec edit(map(), map(), keyword()) :: {:ok, answer()} | {:error, term()}
  def edit(params, context, opts \\ []) when is_map(params) and is_map(context) do
    start = System.monotonic_time(:microsecond)

    result =
      with :ok <- gate(context, "checklist_edit"),
           {:ok, changes} <- changes(Map.get(params, "changes")),
           {:ok, applied} <- store(context, opts, {:edit, changes, edit_context(context, opts)}) do
        {:ok, edit_answer(applied.summary)}
      end

    emit_edit(context, params, result, start)
    result
  end

  defp edit_context(context, opts) do
    %{now: now(opts), outside?: Access.read_outside?(context), made_via: Access.made_via(context)}
  end

  defp edit_answer(summary) do
    %{
      text: Enum.map_join(summary, "\n", &Render.answer/1),
      touched: Enum.map(summary, &Map.take(&1, [:list_id, :title, :rows]))
    }
  end

  @doc """
  The live lists' titles and folders in picker order, for the per-turn index
  note: no counts and no rows, so a read that is cheap on every turn.
  """
  @spec names(map(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def names(context, opts \\ []) when is_map(context), do: store(context, opts, :names)

  # --- the store -------------------------------------------------------------

  defp store(context, opts, request) do
    case Keyword.get(opts, :repo, Repo) do
      nil -> {:error, :disabled}
      repo -> Repo.checklists_call(request(context, request), repo_opts(repo, opts))
    end
  end

  defp request(context, :index), do: {:index, owner_id(context), agent_id(context)}
  defp request(context, :names), do: {:names, owner_id(context), agent_id(context)}

  defp request(context, {:read_list, ref}),
    do: {:read_list, owner_id(context), agent_id(context), ref}

  defp request(context, {:read_folder, name}),
    do: {:read_folder, owner_id(context), agent_id(context), name}

  defp request(context, {:edit, changes, edit}),
    do: {:edit, owner_id(context), agent_id(context), changes, edit}

  defp repo_opts(repo, opts), do: [server: repo] ++ Keyword.take(opts, [:on_timeout, :timeout])

  defp owner_id(context), do: Map.get(context, :memory_owner_id, "default")
  defp agent_id(context), do: Map.get(context, :memory_agent_id, "main")

  defp now(opts) do
    opts |> Keyword.get_lazy(:now, &DateTime.utc_now/0) |> DateTime.shift_zone!("Etc/UTC")
  end

  defp gate(context, tool) do
    if Access.permitted?(context, tool), do: :ok, else: {:error, {:not_permitted, tool}}
  end

  # --- the shape of a call ---------------------------------------------------

  defp changes(changes) when is_list(changes) and changes != [] do
    cond do
      length(changes) > @max_changes -> {:error, :too_many_changes}
      op_count(changes) > @max_ops -> {:error, :too_many_ops}
      true -> changes |> Enum.with_index(1) |> collect(&change/1)
    end
  end

  defp changes(_absent), do: {:error, {:invalid_param, :changes}}

  defp op_count(changes) do
    Enum.reduce(changes, 0, fn
      %{"ops" => ops}, sum when is_list(ops) -> sum + length(ops)
      _change, sum -> sum
    end)
  end

  defp change({%{"list" => list, "ops" => [_ | _] = ops}, index}) when is_binary(list) do
    creates? = match?(%{"op" => "create"}, hd(ops))

    with {:ok, list} <- list_name(list, creates?, index),
         {:ok, ops} <- ops |> Enum.with_index(1) |> collect(&op(&1, index, creates?)) do
      {:ok, %{list: list, ops: ops}}
    end
  end

  defp change({_change, index}), do: {:error, {:invalid_change, index}}

  # A change that creates its list names it with its title; any other names a
  # list by title or id.
  defp list_name(title, true, index), do: located(text(title, :title, @title_max), index, 1)

  defp list_name(ref, false, index) do
    case String.trim(ref) do
      "" -> {:error, {:invalid_change, index}}
      trimmed -> {:ok, trimmed}
    end
  end

  defp op({%{"op" => name} = op, op_index}, index, creates?) when name in @ops,
    do: located(op_fields(String.to_existing_atom(name), op, creates?), index, op_index)

  defp op({%{"op" => name}, op_index}, index, _creates?),
    do: {:error, {:invalid_op, index, op_index, {:unknown_op, name}}}

  defp op({_op, op_index}, index, _creates?),
    do: {:error, {:invalid_op, index, op_index, {:missing, :op}}}

  defp located({:ok, value}, _index, _op_index), do: {:ok, value}

  defp located({:error, reason}, index, op_index),
    do: {:error, {:invalid_op, index, op_index, reason}}

  defp op_fields(:create, op, _creates?) do
    with {:ok, folder} <- optional_text(op, "folder", :folder, @folder_max),
         do: {:ok, %{op: :create, folder: folder}}
  end

  defp op_fields(:add, op, _creates?) do
    with {:ok, text} <- required_text(op, "text", :text, @text_max),
         {:ok, note} <- note(op, :absent_is_nil),
         {:ok, place} <- place(op) do
      {:ok, Map.merge(%{op: :add, text: text, note: note}, place)}
    end
  end

  defp op_fields(done_op, op, _creates?) when done_op in [:check, :uncheck, :remove] do
    with {:ok, n} <- row_number(op, "n"), do: {:ok, %{op: done_op, n: n}}
  end

  defp op_fields(:edit, op, _creates?) do
    with {:ok, n} <- row_number(op, "n"),
         {:ok, text} <- optional_text(op, "text", :text, @text_max),
         {:ok, note} <- note(op, :absent_is_keep),
         :ok <- something_to_edit(text, note) do
      {:ok, %{op: :edit, n: n, text: text, note: note}}
    end
  end

  defp op_fields(:move, op, _creates?) do
    with {:ok, n} <- row_number(op, "n"),
         {:ok, place} <- place(op),
         {:ok, to_list} <- optional_ref(op, "to_list") do
      {:ok, Map.merge(%{op: :move, n: n, to_list: to_list}, place)}
    end
  end

  defp op_fields(:section, op, _creates?) do
    with {:ok, text} <- required_text(op, "text", :text, @text_max),
         {:ok, after_n} <- optional_number(op, "after") do
      {:ok, %{op: :section, text: text, after: after_n}}
    end
  end

  defp op_fields(:folder, op, _creates?) do
    with {:ok, folder} <- optional_text(op, "text", :folder, @folder_max),
         do: {:ok, %{op: :folder, text: folder}}
  end

  defp op_fields(:rename, op, _creates?) do
    with {:ok, title} <- required_text(op, "text", :title, @title_max),
         do: {:ok, %{op: :rename, text: title}}
  end

  defp op_fields(:remove_list, _op, _creates?), do: {:ok, %{op: :remove_list}}

  defp op_fields(:replace, op, creates?) do
    with {:ok, rev} <- replace_rev(op, creates?),
         {:ok, markdown} <- markdown(op),
         {:ok, rows} <- parsed(markdown) do
      {:ok, %{op: :replace, rev: rev, rows: rows}}
    end
  end

  defp something_to_edit(nil, :keep), do: {:error, :nothing_to_edit}
  defp something_to_edit(_text, _note), do: :ok

  defp place(op) do
    with {:ok, section} <- optional_text(op, "section", :section, @text_max),
         {:ok, after_n} <- optional_number(op, "after") do
      if section && after_n,
        do: {:error, :place_conflict},
        else: {:ok, %{section: section, after: after_n}}
    end
  end

  # A list this same change creates has no rev to read yet.
  defp replace_rev(op, true), do: {:ok, Map.get(op, "rev")}

  defp replace_rev(op, false) do
    case Map.get(op, "rev") do
      rev when is_integer(rev) and rev >= 0 -> {:ok, rev}
      nil -> {:error, {:missing, :rev}}
      _other -> {:error, {:not_a_number, :rev}}
    end
  end

  defp markdown(op) do
    case Map.get(op, "markdown") do
      text when is_binary(text) and byte_size(text) <= @markdown_max_bytes -> {:ok, text}
      text when is_binary(text) -> {:error, :markdown_too_long}
      _absent -> {:error, {:missing, :markdown}}
    end
  end

  # The markdown's rows, each held to the bounds an op's text is, every number
  # named once and every section name once.
  defp parsed(markdown) do
    with {:ok, rows} <- Parse.rows(markdown),
         {:ok, rows} <- rows |> Enum.with_index(1) |> collect(&parsed_row/1),
         :ok <- unique(rows, & &1.n, :duplicate_n),
         :ok <- unique(sections(rows), &String.downcase/1, :duplicate_section) do
      {:ok, rows}
    end
  end

  defp parsed_row({row, number}) do
    with {:ok, text} <- text(row.text, :text, @text_max),
         {:ok, note} <- note_text(row.note) do
      {:ok, %{row | text: text, note: note}}
    else
      {:error, reason} -> {:error, {:replace_row, number, reason}}
    end
  end

  defp sections(rows), do: for(%{kind: :section, text: text} <- rows, do: text)

  defp unique(rows, key, tag) do
    rows
    |> Enum.map(key)
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
    |> Enum.find(fn {_value, count} -> count > 1 end)
    |> case do
      nil -> :ok
      {value, _count} -> {:error, {tag, value}}
    end
  end

  defp row_number(op, key) do
    case Map.get(op, key) do
      n when is_integer(n) and n >= 1 -> {:ok, n}
      nil -> {:error, {:missing, String.to_existing_atom(key)}}
      _other -> {:error, {:not_a_number, String.to_existing_atom(key)}}
    end
  end

  defp optional_number(op, key) do
    case Map.get(op, key) do
      nil -> {:ok, nil}
      n when is_integer(n) and n >= 1 -> {:ok, n}
      _other -> {:error, {:not_a_number, String.to_existing_atom(key)}}
    end
  end

  defp optional_ref(op, key) do
    case Map.get(op, key) do
      nil ->
        {:ok, nil}

      ref when is_binary(ref) ->
        if String.trim(ref) == "", do: {:ok, nil}, else: {:ok, String.trim(ref)}

      _other ->
        {:error, {:invalid_param, :to_list}}
    end
  end

  defp required_text(op, key, field, max) do
    case Map.get(op, key) do
      nil -> {:error, {:missing, field}}
      value -> text(value, field, max)
    end
  end

  defp optional_text(op, key, field, max) do
    case Map.get(op, key) do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      value -> text(value, field, max)
    end
  end

  # One line of words: trimmed, never empty, nothing that breaks a line, and
  # within `max` characters as the store counts them (code points).
  defp text(value, field, max) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" -> {:error, {:missing, field}}
      Regex.match?(@forbidden, trimmed) -> {:error, {:not_one_line, field}}
      code_points(trimmed) > max -> {:error, {:too_long, field, max}}
      true -> {:ok, trimmed}
    end
  end

  defp text(_value, field, _max), do: {:error, {:invalid_param, field}}

  # A note: an absent key is nil on an add and leaves the note as it is on an
  # edit; null or "" clears it.
  defp note(op, absent) do
    case {Map.fetch(op, "note"), absent} do
      {:error, :absent_is_keep} -> {:ok, :keep}
      {:error, :absent_is_nil} -> {:ok, nil}
      {{:ok, value}, _absent} -> note_text(value)
    end
  end

  # Its lines trimmed and the empty ones dropped; nil when nothing is left.
  defp note_text(nil), do: {:ok, nil}

  defp note_text(value) when is_binary(value) do
    note =
      value
      |> String.split(["\r\n", "\n"])
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    joined = Enum.join(note, "\n")

    cond do
      note == [] -> {:ok, nil}
      Enum.any?(note, &Regex.match?(@forbidden, &1)) -> {:error, {:not_one_line, :note}}
      code_points(joined) > @note_max -> {:error, {:too_long, :note, @note_max}}
      true -> {:ok, joined}
    end
  end

  defp note_text(_value), do: {:error, {:invalid_param, :note}}

  defp code_points(text), do: text |> String.codepoints() |> length()

  defp collect(indexed, fun) do
    indexed
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end)
  end

  # --- telemetry -------------------------------------------------------------

  defp emit_read(context, scope, result, start) do
    {outcome, lists} =
      case result do
        {:ok, %{touched: touched}} -> {:ok, length(touched)}
        {:error, reason} -> {outcome(reason), 0}
      end

    Telemetry.emit_read(
      context,
      %{
        scope: telemetry_scope(scope),
        lists: lists,
        outcome: outcome,
        made_via: Access.made_via(context),
        error_code: code(result)
      },
      elapsed(start)
    )
  end

  defp telemetry_scope({:ok, {kind, _ref}}), do: kind
  defp telemetry_scope(_index_or_refused), do: :index

  defp emit_edit(context, params, result, start) do
    {outcome, lists} =
      case result do
        {:ok, %{touched: touched}} -> {:ok, length(touched)}
        {:error, reason} -> {outcome(reason), 0}
      end

    Telemetry.emit_edit(
      context,
      %{
        lists: lists,
        ops: params |> Map.get("changes") |> List.wrap() |> op_count(),
        outcome: outcome,
        made_via: Access.made_via(context),
        error_code: code(result)
      },
      elapsed(start)
    )
  end

  defp outcome(reason) do
    if error_tag(reason) == "storage_failed", do: :failed, else: :refused
  end

  defp code({:ok, _answer}), do: nil
  defp code({:error, reason}), do: error_tag(reason)

  defp elapsed(start), do: max(System.monotonic_time(:microsecond) - start, 0)

  # --- error vocabulary ------------------------------------------------------

  @doc """
  The tag a refused call is traced under: the reason's leading atom, or the
  op failure's own reason's, and `storage_failed` for a term with neither.
  """
  @spec error_tag(term()) :: String.t()
  def error_tag({:op_failed, _change, _list, _op, reason}), do: error_tag(reason)
  def error_tag({:invalid_op, _change, _op, reason}), do: error_tag(reason)

  def error_tag(reason) when is_atom(reason) and reason not in [nil, true, false],
    do: Atom.to_string(reason)

  def error_tag(reason) when is_tuple(reason) and is_atom(elem(reason, 0)),
    do: Atom.to_string(elem(reason, 0))

  def error_tag(_reason), do: "storage_failed"

  @doc """
  Every refusal as one sentence that tells the model what to do. A refused op
  says which change and op it was, and that nothing in the call changed.
  """
  @spec describe_error(term()) :: String.t()
  def describe_error({:op_failed, change, list, op, reason}),
    do: describe_error(reason) <> where(change, list, op)

  def describe_error({:invalid_op, change, op, reason}),
    do:
      describe_error(reason) <> " Nothing in this call was changed (change #{change}, op #{op})."

  def describe_error({:not_permitted, tool}), do: Access.refusal(tool)
  def describe_error(:outside_content), do: Access.outside_refusal()

  def describe_error({:stale, rev, _current}),
    do: "The list changed since you read it at rev #{rev}; read it again."

  def describe_error({:list_full, _title}),
    do: "A list holds at most #{Ops.max_rows()} items. Clear what's done to make room."

  def describe_error(:too_many_lists) do
    "The owner keeps at most #{Ops.max_lists()} lists. Remove one they no longer need to " <>
      "make room."
  end

  def describe_error({:no_list, ref, titles}) do
    "No list is named #{Render.quoted(ref)}#{titles_part(titles)}. To make one, start the " <>
      "change with a create op, and only when the owner names a new list."
  end

  def describe_error({:no_folder, folder, []}),
    do: "No list is in a folder named #{Render.quoted(folder)}; no list is in a folder."

  def describe_error({:no_folder, folder, folders}) do
    "No list is in a folder named #{Render.quoted(folder)}; the folders are " <>
      Enum.map_join(folders, ", ", &Render.quoted/1) <> "."
  end

  def describe_error({:title_taken, title}),
    do: "A list named #{Render.quoted(title)} already exists; name another, or change that one."

  def describe_error({:no_section, name, []}),
    do: "This list has no section named #{Render.quoted(name)}, and no sections at all."

  def describe_error({:no_section, name, sections}) do
    "This list has no section named #{Render.quoted(name)}; its sections are " <>
      Enum.map_join(sections, ", ", &Render.quoted/1) <> ". Add one with a section op first."
  end

  def describe_error({:section_exists, name}),
    do: "This list already has a section named #{Render.quoted(name)}."

  def describe_error({:no_row, n}),
    do: "This list has no row [#{n}]; read it again for its numbers."

  def describe_error({:not_an_item, n}), do: "[#{n}] is a section, not an item."

  def describe_error({:kind_changed, n}),
    do: "[#{n}] cannot change between a section and an item; give the new one no number."

  def describe_error({:section_not_empty, n}),
    do: "Section [#{n}] still holds items; move or remove them first."

  def describe_error({:note_on_section, n}), do: "[#{n}] is a section, and a section has no note."
  def describe_error({:after_self, n}), do: "[#{n}] cannot be moved after itself."
  def describe_error(:same_list), do: "to_list names the list the item is already in."
  def describe_error(:move_needs_place), do: "A move needs a section, an after or a to_list."
  def describe_error(:place_conflict), do: "Give section or after, not both."
  def describe_error(:nothing_to_edit), do: "An edit needs a text, a note, or both."
  def describe_error(:create_not_first), do: "create must be the first op of its change."
  def describe_error(:list_removed), do: "This list was removed earlier in the call."
  def describe_error(:list_and_folder), do: "Give list or folder, not both."

  def describe_error(:too_many_changes),
    do: "One call changes at most #{@max_changes} lists; split the rest into another call."

  def describe_error(:too_many_ops),
    do: "One call carries at most #{@max_ops} ops; split the rest into another call."

  def describe_error({:invalid_change, index}),
    do: "Change #{index} needs a list (its title or id) and at least one op."

  def describe_error({:unknown_op, name}),
    do: "#{inspect(name)} is not an op; the ops are #{Enum.join(@ops, ", ")}."

  def describe_error({:missing, field}), do: "The op needs #{field}."
  def describe_error({:not_a_number, field}), do: "#{field} must be a row number, 1 or more."

  def describe_error({:not_one_line, field}),
    do: "The #{field} must be words on one line, with no control characters."

  def describe_error({:too_long, field, max}), do: "The #{field} is over #{max} characters."
  def describe_error(:markdown_too_long), do: "The markdown is too long for one list."
  def describe_error({:invalid_param, field}), do: "#{field} must be text."

  def describe_error({:replace_row, number, reason}),
    do: "Row #{number} of the markdown: " <> describe_error(reason)

  def describe_error({:duplicate_n, n}), do: "The markdown names [#{n}] twice."

  def describe_error({:duplicate_section, name}),
    do: "The markdown names the section #{Render.quoted(name)} twice."

  def describe_error({:line, number, reason}),
    do: "Line #{number} of the markdown #{line_problem(reason)}"

  def describe_error(:disabled),
    do: "The owner's lists are unavailable because memory is off on this install."

  def describe_error(reason) do
    "The lists could not be read or saved (#{inspect(reason)}), so nothing changed; tell the " <>
      "owner and do not retry in this turn."
  end

  defp where(change, list, op),
    do: " Nothing in this call was changed (change #{change}, #{Render.quoted(list)}, op #{op})."

  defp titles_part([]), do: "; the owner keeps no lists yet"

  defp titles_part(titles),
    do: "; the lists are " <> Enum.map_join(titles, ", ", &Render.quoted/1)

  defp line_problem(:not_a_row) do
    "is not a list row: write an item as `- [ ] words`, a section as `## Name`, and a note " <>
      "as an indented line under its item."
  end

  defp line_problem(:note_without_item), do: "is a note with no item above it."
  defp line_problem(:note_on_section), do: "is a note under a section; only an item has one."
  defp line_problem(:bad_frame), do: "has a frame whose words are not one quoted string."
  defp line_problem(:second_list), do: "starts a second list; replace takes one list."
end
