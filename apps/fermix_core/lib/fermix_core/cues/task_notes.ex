defmodule FermixCore.Cues.TaskNotes do
  @moduledoc """
  A task's notes (M60 §9.10 item 2): what a cue run keeps for its task's later
  runs, only while the owner has task notes on for its watcher (S6).

  A note is a row of the memory table in the task's own scope (scope type
  `job`, scope id its job's memory source) with `source_type = "cue_task"` and
  category `task_note`, so it never reaches USER.md or MEMORY.md (S7). In a cue
  run, `memory_store`, `memory_recall` and `memory_forget` come here and reach
  only those notes: a category is refused, a task keeps at most 50 notes of at
  most 500 characters, and at the cap a new note is refused until one is
  forgotten. With notes off the three tools refuse (they are not in the run's
  surface either, `Jobs.CueSurface`).

  Outside a cue run notes are left out or framed: the main agent's `all` search
  leaves them out (`Memory.Search`), the reviewer never changes one
  (`Memory.ReviewTools`), recall frames them wherever they come back
  (`UntrustedContent.untrusted_source_type?/1`), and `list_cues` shows them
  framed (`render/1`).

  A task runs one run at a time (design §9.2), so the cap's count and the write
  that follows it are never raced by a second run of the same task.
  """

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Capabilities.UntrustedContent
  alias FermixCore.Memory.Config
  alias FermixCore.Memory.Repo
  alias FermixCore.Tools.MemorySupport

  @source_type "cue_task"
  @category "task_note"
  @frame_label "cue task notes"
  @archive_actor "cue_task"

  # Design §9.10: at most 50 notes of at most 500 characters per task. A key is
  # a short name; the design states no bound, so this one is ours.
  @notes_max 50
  @note_max_chars 500
  @key_max_chars 100

  @notes_off "This task keeps no notes: task notes are off for its watcher, and only the " <>
               "owner can turn them on."
  @category_refused "A task keeps notes for itself only; leave out the category."
  @id_refused "A task changes a note by saving it again under its key; leave out the id."
  @key_taken "That key holds Fermix's own record for this task; pick another key."
  @not_own_note "No note of this task has that id."
  @no_source "This task's memory source is missing, so it cannot keep notes."

  @typedoc "Where a task's notes live: its agent, owner and job memory source."
  @type scope :: %{
          agent_id: String.t(),
          owner_id: String.t(),
          source_id: String.t()
        }

  @doc "The `source_type` every task note carries."
  @spec source_type() :: String.t()
  def source_type, do: @source_type

  @doc "The most notes a task keeps."
  @spec notes_max() :: pos_integer()
  def notes_max, do: @notes_max

  @doc "Whether `context` is a run a cue woke (its run row says `trigger = \"cue\"`)."
  @spec cue_run?(map()) :: boolean()
  def cue_run?(context) when is_map(context), do: Map.get(context, :trigger) == "cue"

  @doc """
  The scope of the notes of a watcher's task, from its job: the agent the
  runner gives the job's runs (`created_by_agent_id`) and the owner.
  """
  @spec job_scope(%{memory_source_id: String.t(), created_by_agent_id: String.t()}) :: scope()
  def job_scope(%{memory_source_id: source_id, created_by_agent_id: agent_id})
      when is_binary(source_id) and is_binary(agent_id) do
    %{agent_id: agent_id, owner_id: Config.owner_id(), source_id: source_id}
  end

  @doc "The task's live notes, most recently saved first."
  @spec list(scope(), keyword()) :: {:ok, [Repo.memory_row()]} | {:error, term()}
  def list(%{source_id: source_id} = scope, opts) when is_binary(source_id) and is_list(opts) do
    Repo.get_memories(Map.put(selector(scope), :archived?, false),
      server: Keyword.get(opts, :repo, Repo)
    )
  end

  @doc """
  The notes as one framed block: a model wrote them in a run that read outside
  text, so they are data wherever they are shown. `nil` for no notes.
  """
  @spec render([map()]) :: String.t() | nil
  def render([]), do: nil

  def render(notes) when is_list(notes) do
    lines = Enum.map_join(notes, "\n", fn note -> "id=#{note.id} #{note.key}: #{note.value}" end)
    UntrustedContent.frame(@frame_label, lines)
  end

  # --- the three memory tools in a cue run -------------------------------------------

  @doc "`memory_store` in a cue run: saves or replaces one of the task's own notes."
  @spec store(map(), map()) :: {:ok, Tool.tool_result()}
  def store(args, context) when is_map(args) and is_map(context),
    do: tool_result(stored(args, context))

  @doc """
  `memory_recall` in a cue run: the task's own notes, framed, whatever scope or
  source the call names; `search` and `key` narrow within them.
  """
  @spec recall(map(), map()) :: {:ok, Tool.tool_result()}
  def recall(args, context) when is_map(args) and is_map(context),
    do: tool_result(recalled_text(args, context))

  @doc "`memory_forget` in a cue run: archives one of the task's own notes, by id."
  @spec forget(map(), map()) :: {:ok, Tool.tool_result()}
  def forget(args, context) when is_map(args) and is_map(context),
    do: tool_result(forgotten(args, context))

  # --- private -------------------------------------------------------------------

  defp stored(args, context) do
    with {:ok, scope} <- run_scope(context),
         :ok <- refuse_present(args, "category", @category_refused),
         :ok <- refuse_present(args, "id", @id_refused),
         {:ok, key, value} <- note_fields(args),
         {:ok, rows} <- scope_rows(scope, context),
         {:ok, count} <- room_for(key, rows) do
      write(scope, key, value, count, context)
    end
  end

  defp recalled_text(args, context) do
    with {:ok, scope} <- run_scope(context),
         {:ok, notes} <- recalled(args, scope, context) do
      {:ok, recall_text(args, notes)}
    end
  end

  defp forgotten(args, context) do
    with {:ok, scope} <- run_scope(context),
         {:ok, id} <- note_id(args),
         {:ok, note} <- own_note(scope, id, context),
         {:ok, archived} <- archive(scope, note, args, context) do
      {:ok,
       "Forgotten: note id=#{archived.id} (#{archived.key}). It no longer counts toward " <>
         "this task's #{@notes_max} notes."}
    end
  end

  defp run_scope(context) do
    cond do
      not notes_on?(context) -> {:error, @notes_off}
      not is_binary(Map.get(context, :memory_source_id)) -> {:error, @no_source}
      true -> {:ok, context_scope(context)}
    end
  end

  # `cue.task_notes?` is the watcher's switch, read when the run started (lane C2).
  defp notes_on?(%{cue: %{task_notes?: true}}), do: true
  defp notes_on?(_context), do: false

  defp context_scope(context) do
    %{
      agent_id: Map.get(context, :memory_agent_id) || Config.agent_id(),
      owner_id: Map.get(context, :memory_owner_id) || Config.owner_id(),
      source_id: Map.fetch!(context, :memory_source_id)
    }
  end

  defp selector(scope) do
    %{
      agent_id: scope.agent_id,
      owner_id: scope.owner_id,
      scope_type: "job",
      scope_id: scope.source_id,
      source_type: @source_type
    }
  end

  defp repo(context), do: Map.get(context, :memory_repo) || Repo

  defp refuse_present(args, name, sentence) do
    if is_nil(Map.get(args, name)), do: :ok, else: {:error, sentence}
  end

  defp note_fields(%{"key" => key, "value" => value}) when is_binary(key) and is_binary(value) do
    key = String.trim(key)
    value = String.trim(value)

    cond do
      key == "" -> {:error, "key must not be empty."}
      String.length(key) > @key_max_chars -> {:error, "A note's key is at most 100 characters."}
      value == "" -> {:error, "value must not be empty."}
      String.length(value) > @note_max_chars -> {:error, too_long(String.length(value))}
      true -> {:ok, key, value}
    end
  end

  defp note_fields(_args), do: {:error, "Give the note a key and a value."}

  defp too_long(length) do
    "A task's note is at most #{@note_max_chars} characters; this one is #{length}. " <>
      "Shorten it and save again."
  end

  # Every live row of the job's scope: the task's notes and any row Fermix wrote
  # there, whose key a note must not take over.
  defp scope_rows(scope, context) do
    selector = scope |> selector() |> Map.delete(:source_type) |> Map.put(:archived?, false)

    case Repo.get_memories(selector, server: repo(context)) do
      {:ok, rows} -> {:ok, rows}
      {:error, reason} -> {:error, MemorySupport.refusal(reason)}
    end
  end

  # `{:ok, notes after the write}`, or the refusal: a key Fermix's own row holds,
  # or a new note past the cap. Replacing a note's value is never refused.
  defp room_for(key, rows) do
    {notes, others} = Enum.split_with(rows, &(&1.source_type == @source_type))

    cond do
      Enum.any?(others, &(&1.key == key)) -> {:error, @key_taken}
      Enum.any?(notes, &(&1.key == key)) -> {:ok, length(notes)}
      length(notes) >= @notes_max -> {:error, at_cap()}
      true -> {:ok, length(notes) + 1}
    end
  end

  defp at_cap do
    "This task keeps #{@notes_max} notes already; forget one with memory_forget before " <>
      "saving another."
  end

  defp write(scope, key, value, count, context) do
    attrs = %{
      agent_id: scope.agent_id,
      owner_id: scope.owner_id,
      scope_type: "job",
      scope_id: scope.source_id,
      category: @category,
      key: key,
      value: value,
      confidence: 1.0,
      promote_target: "none",
      source_id: scope.source_id,
      source_type: @source_type,
      source_name: Map.get(context, :memory_source_name),
      session_id: Map.get(context, :session_id),
      run_id: Map.get(context, :run_id)
    }

    case Repo.upsert_memory(attrs, server: repo(context)) do
      {:ok, memory} ->
        {:ok,
         "Saved note id=#{memory.id} (#{key}) for this task's later runs. It keeps " <>
           "#{count} of #{@notes_max} notes."}

      {:error, reason} ->
        {:error, MemorySupport.refusal(reason)}
    end
  end

  defp recalled(%{"search" => search}, scope, context) when is_binary(search) do
    selector = Map.put(selector(scope), :archived?, false)

    case Repo.search_memories(search,
           server: repo(context),
           selector: selector,
           limit: @notes_max
         ) do
      {:ok, notes} -> {:ok, notes}
      {:error, reason} -> {:error, "The note search failed: #{inspect(reason)}"}
    end
  end

  defp recalled(args, scope, context) do
    case list(scope, repo: repo(context)) do
      {:ok, notes} -> {:ok, by_key(notes, Map.get(args, "key"))}
      {:error, reason} -> {:error, MemorySupport.refusal(reason)}
    end
  end

  defp by_key(notes, key) when is_binary(key), do: Enum.filter(notes, &(&1.key == key))
  defp by_key(notes, _key), do: notes

  defp recall_text(%{"search" => search}, []) when is_binary(search),
    do: "No note of this task matches: #{search}"

  defp recall_text(%{"key" => key}, []) when is_binary(key), do: "This task has no note #{key}."
  defp recall_text(_args, []), do: "This task keeps no notes yet."

  defp recall_text(_args, notes) do
    "This task's notes, as earlier runs saved them (#{length(notes)} shown; at most " <>
      "#{@notes_max} kept):\n" <> render(notes)
  end

  defp note_id(args) do
    case MemorySupport.parse_id(Map.get(args, "id")) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, "Missing required parameter: id, a positive integer"}
    end
  end

  defp own_note(scope, id, context) do
    selector = scope |> selector() |> Map.merge(%{id: id, archived?: false})

    case Repo.get_memory(selector, server: repo(context)) do
      {:ok, note} -> {:ok, note}
      {:error, :not_found} -> {:error, @not_own_note}
      {:error, reason} -> {:error, MemorySupport.refusal(reason)}
    end
  end

  defp archive(scope, note, args, context) do
    selector = scope |> selector() |> Map.merge(%{id: note.id, archived?: false})
    now = Map.get(context, :clock, &DateTime.utc_now/0).()

    case Repo.archive_memory(selector, @archive_actor, reason(args), now, server: repo(context)) do
      {:ok, archived} -> {:ok, archived}
      {:error, reason} -> {:error, MemorySupport.refusal(reason)}
    end
  end

  defp reason(args) do
    case Map.get(args, "reason") do
      reason when is_binary(reason) and reason != "" -> reason
      _absent -> "the task forgot it"
    end
  end

  defp tool_result({:ok, text}), do: {:ok, Tool.success(text)}
  defp tool_result({:error, sentence}) when is_binary(sentence), do: {:ok, Tool.error(sentence)}
end
