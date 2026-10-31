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
    * **provenance** — a call on a turn that had read outside content may
      only add and check, the rows it adds stamped, and every other op is
      refused (`Checklists.Ops`);
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
  alias FermixCore.Memory.Config, as: MemoryConfig
  alias FermixCore.Memory.Repo

  @max_changes 8
  @max_ops 100
  @title_max 80
  @folder_max 40
  @text_max 280
  @note_max 1_000
  @markdown_max_bytes 262_144
  @ops ~w(create add check uncheck edit move section remove folder rename remove_list replace)
  # A device's ops (M85 §07): the model's by row id, without `replace`, with
  # `clear_done` and `restore`.
  @device_ops ~w(create add check uncheck edit move section remove folder rename remove_list
                 clear_done restore)
  @list_id ~r/\Ack_[0-9a-z]{10}\z/
  @row_id ~r/\Aci_[0-9a-z]{10}\z/
  # The id fields a device's op carries, by the name each is refused under.
  @id_fields %{
    "list_id" => :list_id,
    "row_id" => :row_id,
    "section_id" => :section_id,
    "after_id" => :after_id,
    "to_list_id" => :to_list_id
  }
  # A line break, another control character, a line or paragraph separator,
  # or a bidi override: none belongs in one line of a list.
  @forbidden ~r/[\p{Cc}\p{Zl}\p{Zp}\x{202A}-\x{202E}\x{2066}-\x{2069}]/u

  @typedoc "A list a call read or changed, as a reply's block names it."
  @type touch :: %{list_id: String.t(), title: String.t(), rows: [String.t()]}

  @type answer :: %{text: String.t(), touched: [touch()]}

  @doc "Every op a `checklist_edit` call takes, by name."
  @spec ops() :: [String.t()]
  def ops, do: @ops

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
        :ok = announce(context, applied, %{}, opts)
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

  # --- the owner's devices (M85 §07) -----------------------------------------

  @doc "Every op a device's `checklist_edit` takes, by name."
  @spec device_ops() :: [String.t()]
  def device_ops, do: @device_ops

  @doc """
  The index a device draws (`checklists`): every live list with its counts and
  rev, in picker order. Only a connection placed as the owner's (`caller`
  `:independent`) reads it.
  """
  @spec device_index(atom() | nil, keyword()) :: {:ok, [map()]} | {:error, term()}
  def device_index(caller, opts \\ []) when is_list(opts) do
    with :ok <- device_gate(caller), do: store(device_context(), opts, :index)
  end

  @doc """
  One list a device draws (`checklist`), live or removed and not yet swept:
  `%{list, rows, removed_rows}`, the rows removed in the last 30 days only when
  `removed?`.
  """
  @spec device_list(String.t(), boolean(), atom() | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def device_list(list_id, removed?, caller, opts \\ [])
      when is_binary(list_id) and is_boolean(removed?) and is_list(opts) do
    with :ok <- device_gate(caller),
         :ok <- matches(list_id, @list_id, :list_id),
         do: store(device_context(), opts, {:list_by_id, list_id, removed?})
  end

  @doc """
  One edit a device sent (`checklist_edit`): `"client_msg_id"`, `"op"` and,
  for every op but `create`, `"list_id"`. It goes through the same
  transaction as the model's (`Checklists.Ops`), its rows made via `mac`, and
  once only: an id already applied is answered `duplicate: true` and changes
  nothing. Answers the list it changed and the id an add or create made.
  """
  @spec device_edit(map(), atom() | nil, keyword()) ::
          {:ok, %{list_id: String.t(), made: String.t() | nil, duplicate: boolean()}}
          | {:error, term()}
  def device_edit(%{"client_msg_id" => client_msg_id} = params, caller, opts \\ [])
      when is_binary(client_msg_id) and is_list(opts) do
    start = System.monotonic_time(:microsecond)
    context = device_context()
    edit = %{now: now(opts), outside?: false, made_via: "mac"}

    result =
      with :ok <- device_gate(caller),
           {:ok, change} <- device_change(params),
           {:ok, outcome} <- store(context, opts, {:device_edit, client_msg_id, [change], edit}) do
        device_outcome(outcome, context, {client_msg_id, opts})
      end

    result = device_refusal(result)
    emit_device_edit(result, start)
    result
  end

  # A device sends one op, so its refusal is the op's own sentence, without
  # the place in a call the model is told, and names the fields a device
  # sends where the model's sentence names the model's.
  defp device_refusal({:error, {:op_failed, _change, _list, _op, reason}}),
    do: {:error, device_reason(reason)}

  defp device_refusal({:error, reason}), do: {:error, device_reason(reason)}
  defp device_refusal(result), do: result

  defp device_reason({:no_list, id, _titles}), do: {:no_such_list, id}
  defp device_reason(:move_needs_place), do: {:device, :move_needs_place}
  defp device_reason(:place_conflict), do: {:device, :place_conflict}
  defp device_reason(:same_list), do: {:device, :same_list}
  defp device_reason(reason), do: reason

  defp device_outcome({:applied, applied}, context, {client_msg_id, opts}) do
    [%{list_id: list_id} | _rest] = applied.summary
    made = if applied.made, do: %{list_id => %{client_msg_id => applied.made}}, else: %{}
    :ok = announce(context, applied, made, opts)
    {:ok, %{list_id: list_id, made: applied.made, duplicate: false}}
  end

  defp device_outcome({:duplicate, record}, _context, _id_and_opts),
    do: {:ok, Map.put(record, :duplicate, true)}

  defp device_gate(caller) do
    if Access.device_owner?(caller), do: :ok, else: {:error, :not_owner}
  end

  defp device_context,
    do: %{memory_owner_id: MemoryConfig.owner_id(), memory_agent_id: MemoryConfig.agent_id()}

  # A device's op, as `Checklists.Ops` takes it: rows named `{:id, row_id}`.
  defp device_change(%{"op" => %{"op" => "create"} = op}) do
    with {:ok, title} <- required_text(op, "title", :title, @title_max),
         {:ok, folder} <- optional_text(op, "folder", :folder, @folder_max),
         do: {:ok, %{list: title, ops: [%{op: :create, folder: folder}]}}
  end

  defp device_change(%{"op" => %{"op" => name} = op} = params) when name in @device_ops do
    with {:ok, list_id} <- required_id(params, "list_id", @list_id),
         {:ok, normalized} <- device_op(String.to_existing_atom(name), op),
         do: {:ok, %{list: list_id, ops: [normalized]}}
  end

  defp device_change(%{"op" => %{"op" => name}}), do: {:error, {:unknown_device_op, name}}
  defp device_change(_params), do: {:error, {:missing, :op}}

  defp device_op(:add, op) do
    with {:ok, text} <- required_text(op, "text", :text, @text_max),
         {:ok, note} <- note(op, :absent_is_nil),
         {:ok, place} <- device_place(op),
         do: {:ok, Map.merge(%{op: :add, text: text, note: note}, place)}
  end

  defp device_op(row_op, op) when row_op in [:check, :uncheck, :remove] do
    with {:ok, row} <- required_id(op, "row_id", @row_id), do: {:ok, %{op: row_op, n: {:id, row}}}
  end

  defp device_op(:edit, op) do
    with {:ok, row} <- required_id(op, "row_id", @row_id),
         {:ok, text} <- optional_text(op, "text", :text, @text_max),
         {:ok, note} <- note(op, :absent_is_keep),
         :ok <- something_to_edit(text, note),
         do: {:ok, %{op: :edit, n: {:id, row}, text: text, note: note}}
  end

  defp device_op(:move, op) do
    with {:ok, row} <- required_id(op, "row_id", @row_id),
         {:ok, place} <- device_place(op),
         {:ok, to_list} <- optional_id(op, "to_list_id", @list_id),
         do: {:ok, Map.merge(%{op: :move, n: {:id, row}, to_list: to_list}, place)}
  end

  defp device_op(:section, op) do
    with {:ok, text} <- required_text(op, "text", :text, @text_max),
         {:ok, after_row} <- optional_id(op, "after_id", @row_id),
         do: {:ok, %{op: :section, text: text, after: row_ref(after_row)}}
  end

  defp device_op(:restore, op) do
    with {:ok, row} <- optional_id(op, "row_id", @row_id),
         {:ok, title} <- optional_text(op, "title", :title, @title_max),
         do: {:ok, %{op: :restore, row: row_ref(row), title: title}}
  end

  defp device_op(list_op, _op) when list_op in [:remove_list, :clear_done],
    do: {:ok, %{op: list_op}}

  # `folder` and `rename` take what the model's ops take.
  defp device_op(name, op) when name in [:folder, :rename], do: op_fields(name, op, false)

  defp device_place(op) do
    with {:ok, section} <- optional_id(op, "section_id", @row_id),
         {:ok, after_row} <- optional_id(op, "after_id", @row_id) do
      if section && after_row,
        do: {:error, :place_conflict},
        else: {:ok, %{section: row_ref(section), after: row_ref(after_row)}}
    end
  end

  defp row_ref(nil), do: nil
  defp row_ref(id), do: {:id, id}

  defp required_id(map, key, pattern) do
    case Map.get(map, key) do
      nil -> {:error, {:missing, Map.fetch!(@id_fields, key)}}
      id -> with :ok <- matches(id, pattern, Map.fetch!(@id_fields, key)), do: {:ok, id}
    end
  end

  defp optional_id(map, key, pattern) do
    case Map.get(map, key) do
      nil -> {:ok, nil}
      id -> with :ok <- matches(id, pattern, Map.fetch!(@id_fields, key)), do: {:ok, id}
    end
  end

  defp matches(id, pattern, field) when is_binary(id) do
    if Regex.match?(pattern, id), do: :ok, else: {:error, {:invalid_param, field}}
  end

  defp matches(_id, _pattern, field), do: {:error, {:invalid_param, field}}

  # Every committed change reaches the owner's devices through the notifier
  # the channels app registers (`:checklists_notifier`), right after the store
  # committed it, whoever made it: the lists it changed with their revs, and
  # what a device's add or create made. With none registered nobody listens.
  # `opts[:notifier]` is a test's own.
  defp announce(context, applied, made, opts) do
    lists =
      for %{changed?: true} = entry <- applied.summary,
          do: %{list_id: entry.list_id, rev: entry.rev, made: Map.get(made, entry.list_id, %{})}

    case {lists, notifier(opts)} do
      {[], _notifier} -> :ok
      {_lists, nil} -> :ok
      {lists, notifier} -> notifier.(%{owner_id: owner_id(context), lists: lists})
    end
  end

  defp notifier(opts) do
    Keyword.get_lazy(opts, :notifier, fn ->
      case Application.get_env(:fermix_core, :checklists_notifier) do
        nil -> nil
        module -> &module.changed/1
      end
    end)
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

  defp request(context, {:list_by_id, list_id, removed?}),
    do: {:list_by_id, owner_id(context), agent_id(context), list_id, removed?}

  defp request(context, {:device_edit, client_msg_id, changes, edit}),
    do: {:device_edit, owner_id(context), agent_id(context), client_msg_id, changes, edit}

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

  # The folder a list goes in, named as a create names it. Only an explicit
  # null or "" takes it out: a call that names no folder is refused, never
  # read as one.
  defp op_fields(:folder, op, _creates?) do
    with :ok <- present(op, "folder"),
         {:ok, folder} <- optional_text(op, "folder", :folder, @folder_max),
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

  defp present(op, key) do
    if Map.has_key?(op, key), do: :ok, else: {:error, {:missing, String.to_existing_atom(key)}}
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

  defp emit_device_edit(result, start) do
    {outcome, lists} =
      case result do
        {:ok, %{duplicate: true}} -> {:ok, 0}
        {:ok, _changed} -> {:ok, 1}
        {:error, reason} -> {outcome(reason), 0}
      end

    Telemetry.emit_edit(
      %{},
      %{lists: lists, ops: 1, outcome: outcome, made_via: "mac", error_code: code(result)},
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
  def error_tag({:device, reason}), do: error_tag(reason)

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

  def describe_error({:no_row, {:id, _id}}),
    do: "That row is not in this list any more; pull the list again."

  def describe_error({:no_row, n}),
    do: "This list has no row [#{n}]; read it again for its numbers."

  def describe_error({:not_an_item, n}), do: "#{subject(n)} is a section, not an item."
  def describe_error({:not_a_section, n}), do: "#{subject(n)} is an item, not a section."

  def describe_error({:kind_changed, n}),
    do: "[#{n}] cannot change between a section and an item; give the new one no number."

  def describe_error({:section_inside, n}) do
    "#{subject(n)} has items after it in its section, and a new section there would take the items " <>
      "below it; put the section after that section's last row or at the end, then move the " <>
      "items you want into it."
  end

  def describe_error({:section_not_empty, {:id, _id}}),
    do: "That section still holds items; move or remove them first."

  def describe_error({:section_not_empty, n}),
    do: "Section [#{n}] still holds items; move or remove them first."

  def describe_error({:note_on_section, n}),
    do: "#{subject(n)} is a section, and a section has no note."

  def describe_error({:after_self, n}), do: "#{subject(n)} cannot be moved after itself."
  def describe_error(:not_removed), do: "That is not removed, so there is nothing to restore."

  def describe_error({:title_in_use, title}) do
    "Another list is named #{Render.quoted(title)} now, so this one cannot come back under " <>
      "that name; restore it with a new title, or rename the other list first."
  end

  def describe_error({:no_such_list, _id}),
    do: "No list has that id; it may have been removed more than 30 days ago."

  def describe_error(:not_owner),
    do: "Only the owner's own Fermix app can read or change the owner's lists."

  def describe_error({:device, :move_needs_place}),
    do: "A move needs a section_id, an after_id or a to_list_id."

  def describe_error({:device, :place_conflict}), do: "Give section_id or after_id, not both."

  def describe_error({:device, :same_list}),
    do: "to_list_id names the list the row is already in."

  def describe_error({:unknown_device_op, name}),
    do: "#{inspect(name)} is not an op here; the ops are #{Enum.join(@device_ops, ", ")}."

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

  # A row the model names by its number; a device's, by its id.
  defp subject({:id, _id}), do: "That row"
  defp subject(n), do: "[#{n}]"

  defp titles_part([]), do: "; the owner keeps no lists yet"

  defp titles_part(titles),
    do: "; the lists are " <> Enum.map_join(titles, ", ", &Render.quoted/1)

  defp line_problem(:not_a_row) do
    "is not a list row: write an item as `- [ ] words`, a section as `## Name`, and a note " <>
      "as an indented line under its item."
  end

  defp line_problem(:heading_level),
    do: "is a heading of another level; a section is `## Name`, one level deep."

  defp line_problem(:nested) do
    "is an item or a heading indented under another row; a list does not nest, so write it " <>
      "unindented, or as words in the note."
  end

  defp line_problem(:note_without_item), do: "is a note with no item above it."
  defp line_problem(:note_on_section), do: "is a note under a section; only an item has one."
  defp line_problem(:bad_frame), do: "has a frame whose words are not one quoted string."
  defp line_problem(:second_list), do: "starts a second list; replace takes one list."
end
