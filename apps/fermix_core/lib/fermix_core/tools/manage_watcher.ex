defmodule FermixCore.Tools.ManageWatcher do
  @moduledoc """
  `manage_watcher` (M60 §8, §15): create, read and change the owner's
  watchers through `FermixCore.Cues.Watchers`.

  ## Who may call it

  Offered only while the cue tree runs and on an attended operator turn, and
  refused at execution on any other turn (`AccessGate.check_attended/2`), so a
  job run that names it gets a refusal and no cue text (C42). Every change
  needs the owner-consent turn (`AccessGate.owner_consent_turn?/1`, S6) except
  adding a `drop` example, which needs only the owner's private chat
  (`AccessGate.owner_private_turn?/1`): finding "that one" reads `list_cues`,
  which taints the turn (design §8.4). A `pass` example needs consent like any
  other change.

  ## What it returns

  Fermix's own sentences: the echo of every change, and for `show` the
  purpose and the active instructions, numbered and dated, and its examples
  by id, label and cue. It returns no outside text: no snapshot, example
  note, decision reason or hint (`list_cues` is where an item's text is read,
  framed). So it is not one of `UntrustedContent`'s relaying modules and
  leaves the turn untainted, and reading the list with `show` and then
  changing it in the same turn is consent (design §8.4: "before adding, the
  agent sees the active list"). Should `show` ever return outside text, it
  must frame it and join the relaying modules.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.AccessGate
  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Cues
  alias FermixCore.Cues.Watchers
  alias FermixCore.Memory.Repo
  alias FermixCore.Temporal.Access
  alias FermixCore.Tools.Support

  @read_actions ~w(list show)
  @change_actions ~w(create pause resume remove add_instructions remove_instructions
                     restore_instruction merge_instructions set_purpose add_example
                     remove_example update)
  @actions @read_actions ++ @change_actions

  @update_keys ~w(sources filter filter_provider filter_model purpose task_job_id task_notes
                  daily_cap filter_budget)

  @shared_chat_create "Create the watcher from a private chat with Fermix."
  @shared_chat_change "Change the watcher from a private chat with Fermix."
  @tainted "This turn has read outside text, so it cannot change a watcher; ask for the change " <>
             "again in a new message."

  @impl true
  @spec name() :: String.t()
  def name, do: "manage_watcher"

  @impl true
  @spec description() :: String.t()
  def description do
    "Manage the owner's watchers. A watcher reads the cue sources set up in settings (feeds, " <>
      "streams, webhooks), judges each item against its one-line purpose and numbered " <>
      "instructions with a filter model (or passes every item when its filter is none), and " <>
      "wakes its task, a job that runs on cues, for each item that passes. Instructions are " <>
      "a list of single criteria that Fermix never rewrites: read the list with show before " <>
      "adding, and remove one that a new instruction contradicts in the same change. A " <>
      "watcher holds at most 20 active instructions of at most 300 characters; past that, " <>
      "merge several into one. An example must be an item the watcher received (find it with " <>
      "list_cues). Changes need the owner's own request in a private chat; Fermix answers " <>
      "every change with its own summary, which you pass on to the owner as written."
  end

  @impl true
  @spec parameters() :: map()
  def parameters do
    %{
      type: "object",
      required: ["action"],
      properties: %{
        action: %{type: "string", enum: @actions, description: "What to do."},
        name: %{
          type: "string",
          description: "The watcher's name: lowercase letters, digits and dashes."
        },
        purpose: %{type: "string", description: "One line, at most 200 characters."},
        instructions: %{
          type: "array",
          items: %{type: "string"},
          description: "Instructions to add (create, add_instructions), one criterion each."
        },
        remove: %{
          type: "array",
          items: %{type: "integer"},
          description:
            "With add_instructions: active instruction numbers to remove in the same change."
        },
        numbers: %{
          type: "array",
          items: %{type: "integer"},
          description: "Instruction numbers (remove_instructions, merge_instructions)."
        },
        number: %{type: "integer", description: "The instruction to restore."},
        instruction: %{type: "string", description: "The one instruction a merge leaves."},
        sources: %{
          type: "array",
          items: %{type: "string"},
          description: "Source names from settings the watcher listens to."
        },
        filter: %{
          type: "string",
          enum: ["llm", "none"],
          description: "llm judges each item with a model; none passes every item."
        },
        filter_provider: %{type: "string", description: "The filter model's provider."},
        filter_model: %{
          type: "string",
          description:
            "The filter model; without it the default filter model in settings is used, " <>
              "else the main model."
        },
        daily_cap: %{
          type: "string",
          description:
            ~s(Most task runs a day, as a whole number, or "none". Required for filter none.)
        },
        filter_budget: %{
          type: "string",
          description: ~s(Most filter calls a day, as a whole number, or "none".)
        },
        task_notes: %{type: "boolean", description: "Whether the task may keep notes for itself."},
        task_job_id: %{
          type: "string",
          description: "An existing job that runs on cues, to link as the task."
        },
        task: %{type: "string", description: "The prompt of a new task, when none is linked."},
        task_name: %{type: "string", description: "A name for a new task's job."},
        task_timeout_minutes: %{type: "integer", description: "A new task's run limit, 1 to 30."},
        delivery_target: %{
          type: "object",
          description:
            ~s(Where a new task reports: "platform" plus "chat_id" or "channel_id". ) <>
              "Without it the task reports to this chat."
        },
        delivery_mode: %{type: "string", enum: ["origin", "channel", "none"]},
        cue_id: %{type: "integer", description: "The cue an example names, from list_cues."},
        label: %{
          type: "string",
          enum: ["pass", "drop"],
          description: "pass: it should have reached the task; drop: it should not have."
        },
        note: %{type: "string", description: "Why, in a few words (at most 300 characters)."},
        example_id: %{type: "string", description: "The example to remove."}
      }
    }
  end

  @impl true
  def when_to_use do
    "When the owner asks Fermix to watch sources for something, to change what a watcher " <>
      "looks for or where it reports, to react to an item a watcher passed or missed, or asks " <>
      "what a watcher is watching for."
  end

  @impl true
  def failure_modes do
    [
      %{tag: "not_attended", description: "the turn is not the owner's own attended turn"},
      %{
        tag: "no_consent",
        description: "a change from a shared chat or a turn that read outside text"
      },
      %{tag: "instruction_cap", description: "20 active instructions; merge first"}
    ]
  end

  @impl true
  def requires_setup, do: nil

  @impl true
  def category, do: :scheduling

  @doc """
  Offered only while the cue tree runs (`Cues.running?/0`, so a switch flipped
  live changes nothing until a restart), on an attended operator turn.
  """
  @spec advertise?(map()) :: boolean()
  def advertise?(context) when is_map(context),
    do: Cues.running?() and Access.attended_operator_turn?(context)

  @impl true
  @spec execute(map(), Tool.context()) :: {:ok, Tool.tool_result()} | {:error, term()}
  def execute(args, context) when is_map(args) and is_map(context) do
    Support.run(name(), context, fn -> run(args, context) end)
  end

  defp run(args, context) do
    with :ok <- AccessGate.check_attended(name(), context),
         {:ok, action} <- action(args),
         :ok <- consent(action, args, context),
         {:ok, text} <- dispatch(action, args, context) do
      {:ok, Tool.success(text)}
    else
      {:error, sentence} when is_binary(sentence) -> {:ok, Tool.error(sentence)}
    end
  end

  defp action(%{"action" => action}) when action in @actions, do: {:ok, action}

  defp action(_args),
    do: {:error, "Pick an action: #{Enum.join(@actions, ", ")}."}

  # --- consent (S6, design §8.4) ---------------------------------------------------------

  defp consent(action, _args, _context) when action in @read_actions, do: :ok

  defp consent("add_example", %{"label" => "drop"}, context) do
    if AccessGate.owner_private_turn?(context), do: :ok, else: {:error, @shared_chat_change}
  end

  defp consent(action, _args, context) do
    cond do
      AccessGate.owner_consent_turn?(context) -> :ok
      not AccessGate.owner_private_turn?(context) -> {:error, shared_chat(action)}
      true -> {:error, @tainted}
    end
  end

  defp shared_chat("create"), do: @shared_chat_create
  defp shared_chat(_action), do: @shared_chat_change

  # --- actions -------------------------------------------------------------------------

  defp dispatch("list", _args, context) do
    with {:ok, watchers} <- Watchers.list(opts(context)), do: {:ok, render_list(watchers)}
  end

  defp dispatch("show", args, context) do
    with {:ok, name} <- watcher_name(args),
         {:ok, watcher} <- Watchers.show(name, opts(context)) do
      {:ok, render_show(watcher, context)}
    end
  end

  defp dispatch("create", args, context) do
    with {:ok, params} <- create_params(args) do
      echo_of(Watchers.create(params, context, opts(context)))
    end
  end

  defp dispatch(action, args, context) do
    with {:ok, name} <- watcher_name(args) do
      echo_of(change(action, name, args, context))
    end
  end

  defp change("pause", name, _args, context), do: Watchers.pause(name, opts(context))
  defp change("resume", name, _args, context), do: Watchers.resume(name, opts(context))
  defp change("remove", name, _args, context), do: Watchers.remove(name, opts(context))

  defp change("add_instructions", name, args, context) do
    Watchers.add_instructions(
      name,
      list(args, "instructions"),
      list(args, "remove"),
      Watchers.origin(context),
      opts(context)
    )
  end

  defp change("remove_instructions", name, args, context),
    do:
      Watchers.remove_instructions(
        name,
        list(args, "numbers"),
        Watchers.origin(context),
        opts(context)
      )

  defp change("restore_instruction", name, args, context),
    do:
      Watchers.restore_instruction(
        name,
        Map.get(args, "number"),
        Watchers.origin(context),
        opts(context)
      )

  defp change("merge_instructions", name, args, context) do
    Watchers.merge_instructions(
      name,
      list(args, "numbers"),
      Map.get(args, "instruction"),
      Watchers.origin(context),
      opts(context)
    )
  end

  defp change("set_purpose", name, args, context),
    do: Watchers.set_purpose(name, Map.get(args, "purpose"), opts(context))

  defp change("add_example", name, args, context) do
    Watchers.add_example(
      name,
      Map.get(args, "cue_id"),
      Map.get(args, "label"),
      Map.get(args, "note"),
      opts(context)
    )
  end

  defp change("remove_example", name, args, context),
    do: Watchers.remove_example(name, Map.get(args, "example_id"), opts(context))

  defp change("update", name, args, context) do
    with {:ok, changes} <- update_changes(args), do: Watchers.update(name, changes, opts(context))
  end

  defp echo_of({:ok, %{echo: echo}}), do: {:ok, echo}
  defp echo_of({:error, sentence}), do: {:error, sentence}

  # --- arguments -------------------------------------------------------------------------

  defp watcher_name(%{"name" => name}) when is_binary(name) and name != "", do: {:ok, name}
  defp watcher_name(_args), do: {:error, "Name the watcher."}

  defp create_params(args) do
    with {:ok, daily_cap} <- count_arg(args, "daily_cap"),
         {:ok, budget} <- count_arg(args, "filter_budget") do
      keys = ~w(name purpose instructions sources filter filter_provider filter_model task_notes
                task_job_id task task_name task_timeout_minutes delivery_target delivery_mode)

      {:ok,
       args
       |> Map.take(keys)
       |> atomize()
       |> put_given(:daily_cap, daily_cap)
       |> put_given(:filter_budget, budget)}
    end
  end

  defp update_changes(args) do
    with {:ok, daily_cap} <- count_arg(args, "daily_cap"),
         {:ok, budget} <- count_arg(args, "filter_budget") do
      {:ok,
       args
       |> Map.take(@update_keys -- ["daily_cap", "filter_budget"])
       |> atomize()
       |> put_given(:daily_cap, daily_cap)
       |> put_given(:filter_budget, budget)}
    end
  end

  # A count arrives as a whole number, its digits, or "none".
  defp count_arg(args, key) do
    case Map.get(args, key) do
      nil -> {:ok, :absent}
      "none" -> {:ok, "none"}
      n when is_integer(n) -> {:ok, n}
      text when is_binary(text) -> parse_count(String.trim(text), key)
      _other -> {:error, ~s(#{key} is a whole number or "none".)}
    end
  end

  defp parse_count(text, key) do
    case Integer.parse(text) do
      {n, ""} -> {:ok, n}
      _other -> {:error, ~s(#{key} is a whole number or "none".)}
    end
  end

  defp put_given(params, _key, :absent), do: params
  defp put_given(params, key, value), do: Map.put(params, key, value)

  defp atomize(map),
    do: Map.new(map, fn {key, value} -> {String.to_existing_atom(key), value} end)

  defp list(args, key) do
    case Map.get(args, key) do
      values when is_list(values) -> values
      _absent -> []
    end
  end

  defp opts(context) do
    [repo: Map.get(context, :memory_repo, Repo)] ++
      Enum.flat_map([:skill_registry, :scheduler], fn key ->
        if Map.has_key?(context, key), do: [{key, Map.fetch!(context, key)}], else: []
      end)
  end

  # --- rendering (Fermix's words; outside text framed) ----------------------------------

  defp render_list([]), do: "There are no watchers yet."

  defp render_list(watchers) do
    Enum.map_join(watchers, "\n", fn watcher ->
      "#{watcher.name}: #{state_word(watcher)}; #{filter_word(watcher)}; " <>
        "#{watcher.active_instructions} active instructions; sources " <>
        "#{Enum.join(watcher.sources, ", ")}; task job #{watcher.task_job_id}"
    end)
  end

  defp render_show(watcher, context) do
    [
      "Watcher #{watcher.name} (#{watcher.id}): #{state_word(watcher)}; #{filter_word(watcher)}; " <>
        "task job #{watcher.task_job_id}; task notes #{if watcher.task_notes?, do: "on", else: "off"}.",
      "Sources: #{Enum.join(watcher.sources, ", ")}." <> missing(watcher, context),
      "Daily cap: #{count_word(watcher.daily_cap, "runs")}. Filter budget: " <>
        "#{count_word(watcher.filter_budget, "calls")}.",
      if(watcher.purpose, do: "Purpose: #{watcher.purpose}"),
      instructions_block(watcher.instructions),
      removed_block(watcher.removed_instructions),
      examples_block(watcher.examples)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp missing(watcher, context) do
    case Watchers.missing_sources(watcher.sources, opts(context)) do
      [] -> ""
      lines -> " " <> Enum.join(lines, " ")
    end
  end

  defp state_word(%{enabled?: true}), do: "listening"
  defp state_word(_watcher), do: "paused"

  defp filter_word(%{filter: "none"}), do: "no filter (every item passes)"
  defp filter_word(%{filter_model: nil}), do: "filter: the default filter model"
  defp filter_word(watcher), do: "filter: #{watcher.filter_provider} #{watcher.filter_model}"

  defp count_word(0, _unit), do: "none"
  defp count_word(n, unit), do: "#{n} #{unit} in 24 hours"

  defp instructions_block([]), do: "Active instructions: none."

  defp instructions_block(rows) do
    "Active instructions (numbers are never reused):\n" <>
      Enum.map_join(rows, "\n", fn row ->
        "#{row.number}. #{row.text} (added #{clock(row.added_at)}#{from(row.added_from)})"
      end)
  end

  defp removed_block([]), do: nil

  defp removed_block(rows) do
    "Removed instructions (restorable while there is room):\n" <>
      Enum.map_join(rows, "\n", fn row ->
        "#{row.number}. #{row.text} (removed #{clock(row.removed_at)}#{from(row.removed_from)})"
      end)
  end

  defp examples_block([]), do: nil

  defp examples_block(examples) do
    "Examples, most recent first (list_cues shows an item's text):\n" <>
      Enum.map_join(examples, "\n", fn example ->
        "- #{example.id}: #{example.label}, cue #{example.cue_id}, " <>
          "stored #{clock(example.created_at)}#{if example.note, do: ", with a note", else: ""}"
      end)
  end

  defp from(nil), do: ""
  defp from(origin), do: " from #{origin}"

  defp clock(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")
  defp clock(nil), do: "at an unknown time"
end
