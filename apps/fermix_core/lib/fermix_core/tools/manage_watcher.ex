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
  purpose, the words to listen for, the active instructions, numbered and
  dated, and its examples by id, label and cue. It returns no outside text: no
  snapshot, example note, decision reason or hint (`list_cues` is where an
  item's text is read, framed). So it is not one of `UntrustedContent`'s
  relaying modules and leaves the turn untainted, and reading the list with
  `show` and then changing it in the same turn is consent (design §8.4: "before
  adding, the agent sees the active list"). Should `show` ever return outside
  text, it must frame it and join the relaying modules.

  ## Follow-ups (M60_WATCHER_CODING_RUNS.md §3)

  `create` and `update` take a `follow_up`: a job in the owner's words that a
  passing item sets off and that is handed nothing from it. `stop_follow_up`
  removes it and `run_follow_up` is the owner's run of it by hand. Its tools
  are bounded by this turn as `schedule_job` bounds a job's, the readiness
  check names what is missing, and `always_allow: false` takes back the
  owner's Always allow, which only a card grants: `ManageWatcher.FollowUp`.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.AccessGate
  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Clock
  alias FermixCore.Cues
  alias FermixCore.Cues.FollowUpReadiness
  alias FermixCore.Cues.FollowUps
  alias FermixCore.Cues.Overview
  alias FermixCore.Cues.Watchers
  alias FermixCore.Jobs.Registry, as: JobsRegistry
  alias FermixCore.Memory.Repo
  alias FermixCore.Temporal.Access
  alias FermixCore.Tools.ManageWatcher.FollowUp
  alias FermixCore.Tools.Support

  @read_actions ~w(list show)
  @change_actions ~w(create pause resume remove add_instructions remove_instructions
                     restore_instruction merge_instructions set_purpose add_example
                     remove_example update stop_follow_up run_follow_up)
  @actions @read_actions ++ @change_actions

  @update_keys ~w(sources filter listen_for purpose task_job_id task_notes daily_cap
                  filter_budget)

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
      "wakes its task, a job that runs on cues, for each item that passes. A watcher that " <>
      "filters listens for keywords (listen_for): only an item containing one of them reaches " <>
      "its filter, and the keywords never decide a pass. Draft them yourself, broadly, from the " <>
      "owner's purpose and instructions: names, products, common abbreviations, and the " <>
      "languages the source likely carries, since an item no keyword matches is never judged; " <>
      "never ask the owner for a pattern. A watcher with no filter cannot listen to a stream " <>
      "source. Instructions are a list of single criteria that Fermix never rewrites: read " <>
      "the list with show before adding, and remove one that a new instruction contradicts in " <>
      "the same change. A watcher holds at most 20 active instructions of at most 300 " <>
      "characters; past that, merge several into one. An example must be an item the watcher " <>
      "received, or one of a stream watcher's recent drops (find either with list_cues). " <>
      "Changes need the owner's own request in a private chat; Fermix answers every change " <>
      "with its own summary, which you pass on to the owner as written. A watcher may also " <>
      "have a follow-up (follow_up): the owner's own job that each passing item sets off, " <>
      "with fixed instructions and tools, asking first on a card. Fermix hands it nothing " <>
      "from the item, so work on the item's content is the task's or a mandate's; say so " <>
      "when the owner asks for it."
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
        listen_for: %{
          type: "array",
          items: %{type: "string"},
          description:
            "Keywords and short phrases an item this watcher should see would contain (create, " <>
              "update, where it replaces the list): 1 to 200, each at most 64 characters, " <>
              "matched as whole words ignoring case and accents. Needed for filter llm."
        },
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
          description:
            "Source names from settings the watcher listens to; list_cues view sources lists them."
        },
        filter: %{
          type: "string",
          enum: ["llm", "none"],
          description:
            "llm judges each item with the Cues filter model set in settings; none passes " <>
              "every item."
        },
        daily_cap: %{
          type: "string",
          description:
            ~s(Most runs a day of its task and follow-up together, as a whole number, or ) <>
              ~s("none". Required for filter none.)
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
        drop_key: %{
          type: "integer",
          description:
            "In place of cue_id: a stream watcher's recent drop an example names, from list_cues."
        },
        label: %{
          type: "string",
          enum: ["pass", "drop"],
          description: "pass: it should have reached the task; drop: it should not have."
        },
        note: %{type: "string", description: "Why, in a few words (at most 300 characters)."},
        example_id: %{type: "string", description: "The example to remove."},
        follow_up: FollowUp.schema()
      }
    }
  end

  @impl true
  def when_to_use do
    "When the owner asks Fermix to watch sources for something, to change what a watcher " <>
      "looks for or where it reports, to react to an item a watcher passed or missed, to have " <>
      "something done whenever a watcher passes an item, or asks what a watcher is watching for."
  end

  @impl true
  def failure_modes do
    [
      %{tag: "not_attended", description: "the turn is not the owner's own attended turn"},
      %{
        tag: "no_consent",
        description: "a change from a shared chat or a turn that read outside text"
      },
      %{tag: "instruction_cap", description: "20 active instructions; merge first"},
      %{tag: "needs_words", description: "a model filter with no keywords to listen for"},
      %{tag: "no_filter_on_stream", description: "a watcher with no filter on a stream source"}
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
    with {:ok, watchers} <- Watchers.list(opts(context)),
         do: {:ok, render_list(watchers, context)}
  end

  defp dispatch("show", args, context) do
    with {:ok, name} <- watcher_name(args),
         {:ok, watcher} <- Watchers.show(name, opts(context)) do
      {:ok, render_show(watcher, context)}
    end
  end

  defp dispatch("create", args, context) do
    opts = opts(context)

    with {:ok, params} <- create_params(args),
         {:ok, _name} <- watcher_name(args) do
      case FollowUp.params(Map.get(args, "follow_up"), context, opts) do
        {:ok, follow_up} ->
          params
          |> put_follow_up(follow_up)
          |> Watchers.create(context, opts)
          |> FollowUp.summarize(context, opts)

        {:unoffered, sentence} ->
          create_without_follow_up(params, sentence, context, opts)

        {:error, sentence} ->
          {:error, sentence}
      end
    end
  end

  defp dispatch("update", args, context) do
    with {:ok, name} <- watcher_name(args) do
      "update"
      |> change(name, args, context)
      |> FollowUp.summarize(context, opts(context))
    end
  end

  defp dispatch(action, args, context) do
    with {:ok, name} <- watcher_name(args) do
      echo_of(change(action, name, args, context))
    end
  end

  defp put_follow_up(params, nil), do: params
  defp put_follow_up(params, follow_up), do: Map.put(params, :follow_up, follow_up)

  # A follow-up naming a tool this computer does not have is left out (§3.2);
  # the watcher is still made with its task, so the owner hears from it
  # meanwhile. With no task it would do nothing, so nothing is made.
  defp create_without_follow_up(params, sentence, context, opts) do
    if Enum.any?([:task, :task_job_id], &(Map.get(params, &1) not in [nil, ""])) do
      with {:ok, %{echo: echo}} <- Watchers.create(params, context, opts),
           do: {:ok, echo <> "\n" <> FollowUp.not_set_up(sentence)}
    else
      {:error,
       FollowUp.not_set_up(sentence) <>
         " Nothing was set up: without its follow-up the watcher would have no task."}
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
    label = Map.get(args, "label")
    note = Map.get(args, "note")

    case {Map.get(args, "cue_id"), Map.get(args, "drop_key")} do
      {nil, key} when not is_nil(key) ->
        Watchers.add_drop_example(name, key, label, note, opts(context))

      {cue_id, nil} ->
        Watchers.add_example(name, cue_id, label, note, opts(context))

      {_cue_id, _key} ->
        {:error, "Name the item by cue_id or by drop_key, not both."}
    end
  end

  defp change("remove_example", name, args, context),
    do: Watchers.remove_example(name, Map.get(args, "example_id"), opts(context))

  defp change("update", name, args, context) do
    opts = opts(context)

    with {:ok, changes} <- update_changes(args) do
      case FollowUp.params(Map.get(args, "follow_up"), context, opts) do
        {:ok, follow_up} -> update(name, changes, follow_up, context, opts)
        {:unoffered, sentence} -> update_without_follow_up(name, changes, sentence, opts)
        {:error, sentence} -> {:error, sentence}
      end
    end
  end

  defp change("stop_follow_up", name, _args, context),
    do: Watchers.remove_follow_up(name, opts(context))

  defp change("run_follow_up", name, _args, context),
    do: FollowUp.run_now(name, context, opts(context))

  # The watcher first, then its follow-up.
  defp update(name, changes, nil, _context, opts), do: Watchers.update(name, changes, opts)

  defp update(name, changes, follow_up, context, opts) when map_size(changes) == 0,
    do: Watchers.set_follow_up(name, follow_up, context, opts)

  defp update(name, changes, follow_up, context, opts) do
    with {:ok, %{echo: changed}} <- Watchers.update(name, changes, opts) do
      case Watchers.set_follow_up(name, follow_up, context, opts) do
        {:ok, result} -> {:ok, %{result | echo: changed <> "\n" <> result.echo}}
        {:error, sentence} -> {:error, changed <> "\nThe follow-up did not change: " <> sentence}
      end
    end
  end

  # A follow-up change naming a tool this computer does not have is left out
  # (§3.2); the rest of the change is made.
  defp update_without_follow_up(_name, changes, sentence, _opts) when map_size(changes) == 0,
    do: {:error, FollowUp.not_changed(sentence)}

  defp update_without_follow_up(name, changes, sentence, opts) do
    with {:ok, %{echo: echo} = result} <- Watchers.update(name, changes, opts),
         do: {:ok, %{result | echo: echo <> "\n" <> FollowUp.not_changed(sentence)}}
  end

  defp echo_of({:ok, %{echo: echo}}), do: {:ok, echo}
  defp echo_of({:error, sentence}), do: {:error, sentence}

  # --- arguments -------------------------------------------------------------------------

  defp watcher_name(%{"name" => name}) when is_binary(name) and name != "", do: {:ok, name}
  defp watcher_name(_args), do: {:error, "Name the watcher."}

  defp create_params(args) do
    with {:ok, daily_cap} <- count_arg(args, "daily_cap"),
         {:ok, budget} <- count_arg(args, "filter_budget") do
      keys = ~w(name purpose listen_for instructions sources filter task_notes task_job_id task
                task_name task_timeout_minutes delivery_target delivery_mode)

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

  # The seams a turn's context carries for the domain calls: the registries, the
  # scheduler, and the follow-up's sender and readiness reads (tests).
  @context_seams [
                   :skill_registry,
                   :scheduler,
                   :capability_registry,
                   :cues_config,
                   :follow_up_sender,
                   :proposal_listener
                 ] ++ FollowUpReadiness.seams()

  defp opts(context) do
    [repo: Map.get(context, :memory_repo, Repo)] ++
      Enum.flat_map(@context_seams, fn key ->
        case Map.fetch(context, key) do
          {:ok, nil} when key != :scheduler -> []
          {:ok, value} -> [{key, value}]
          :error -> []
        end
      end)
  end

  # --- rendering (Fermix's words; outside text framed) ----------------------------------

  defp render_list([], _context), do: "There are no watchers yet."

  defp render_list(watchers, context) do
    streams = Watchers.stream_refs(opts(context))

    Enum.map_join(watchers, "\n", fn watcher ->
      "#{watcher.name}: #{state_word(watcher, streams)}; #{filter_word(watcher)}; " <>
        "#{watcher.active_instructions} active instructions; sources " <>
        "#{Enum.join(watcher.sources, ", ")}; #{jobs_words(watcher)}"
    end)
  end

  defp render_show(watcher, context) do
    streams = Watchers.stream_refs(opts(context))

    [
      "Watcher #{watcher.name} (#{watcher.id}): #{state_word(watcher, streams)}; " <>
        "#{filter_word(watcher)}; #{jobs_words(watcher)}; task notes " <>
        "#{if watcher.task_notes?, do: "on", else: "off"}.",
      filter_hold_line(watcher, context),
      follow_up_line(watcher, context),
      needs_line(Watchers.update_needed(watcher, streams)),
      "Sources: #{Enum.join(watcher.sources, ", ")}." <> missing(watcher, context),
      "Daily cap: #{count_word(watcher.daily_cap, "runs")}. Filter budget: " <>
        "#{count_word(watcher.filter_budget, "calls")}.",
      if(watcher.purpose, do: "Purpose: #{watcher.purpose}"),
      Watchers.words_line(watcher),
      instructions_block(watcher.instructions),
      removed_block(watcher.removed_instructions),
      examples_block(watcher.examples)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  # A filter held because the screen's decision model cannot run, in the words
  # of its notice (`Cues.Overview.filter_hold/2`); any other hold is not shown.
  defp filter_hold_line(watcher, context) do
    case Overview.filter_hold(watcher.id, opts(context)) do
      {:ok, nil} -> nil
      {:ok, sentence} -> "Its filter is held. #{sentence}"
      {:error, reason} -> "Its filter's hold could not be read (#{inspect(reason)})."
    end
  end

  defp jobs_words(%{task_job_id: nil} = watcher), do: "no task" <> follow_up_words(watcher)

  defp jobs_words(watcher),
    do: "task job #{watcher.task_job_id}" <> follow_up_words(watcher)

  defp follow_up_words(%{follow_up_job_id: nil}), do: ""

  defp follow_up_words(watcher),
    do: "; follow-up job #{watcher.follow_up_job_id}"

  # The follow-up as it stands: what it runs, how, and whether it is held now.
  defp follow_up_line(%{follow_up_job_id: nil}, _context), do: nil

  defp follow_up_line(watcher, context) do
    opts = opts(context)

    with {:ok, job} <- JobsRegistry.get_job(watcher.follow_up_job_id, repo: opts[:repo]),
         {:ok, allowed?} <- Watchers.always_allowed(watcher, opts) do
      ~s(Follow-up "#{job.name}": uses #{Enum.join(job.allowed_tools, ", ")}; ) <>
        "#{allow_words(allowed?)}; #{held_words(FollowUps.held(job, opts))}"
    else
      {:error, sentence} when is_binary(sentence) -> "Follow-up: #{sentence}"
      {:error, reason} -> "Follow-up: its job could not be read (#{inspect(reason)})."
    end
  end

  defp allow_words(true), do: "always allowed, so it runs with no card"
  defp allow_words(false), do: "asks first on a card"

  defp held_words(nil), do: "ready."
  defp held_words({_label, sentence}), do: "held: #{sentence}"

  defp missing(watcher, context) do
    case Watchers.missing_sources(watcher.sources, opts(context)) do
      [] -> ""
      lines -> " " <> Enum.join(lines, " ")
    end
  end

  defp state_word(%{enabled?: false}, _streams), do: "paused"

  defp state_word(watcher, streams) do
    case Watchers.update_needed(watcher, streams) do
      nil -> "listening"
      :words -> "needs keywords to listen for"
      :filter -> "needs a filter to listen to a stream"
    end
  end

  defp needs_line(nil), do: nil

  defp needs_line(:words),
    do: "It needs keywords to listen for, and no item reaches it until an update gives it some."

  defp needs_line(:filter),
    do:
      "It passes every item and listens to a stream, so nothing reaches it until an update " <>
        "gives it a model filter or other sources."

  defp filter_word(%{filter: "none"}), do: "no filter (every item passes)"
  defp filter_word(_watcher), do: "filter: the Cues filter model"

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

  defp clock(%DateTime{} = at), do: Clock.stated_instant(at)
  defp clock(nil), do: "at an unknown time"
end
