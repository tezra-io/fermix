defmodule FermixCore.Cues.Watchers do
  @moduledoc """
  Watchers (M60 §8): what a watcher reads, how it filters, and the task it
  wakes. The domain API behind `manage_watcher`; rows live in `memory.db`
  through `Memory.Repo.CuesWatchersSql`.

  This module validates every change and writes the owner-facing sentences:
  refusals and Fermix's echo of what changed (design §8.4: "Added 5: …
  Removed 2: …"). It does not decide who may change a watcher; the caller
  checks consent (S6) before it calls a change.

  Every change records where it came from (`created_from`, `added_from`,
  `removed_from`) as `channel:chat` taken from the tool context by Fermix,
  never from the model.

  Two rules hold for every watcher saved (M60_CUE_INTAKE_AT_SCALE.md §3.1): one
  that filters has words to listen for (`listen_for`, validated by
  `Cues.ListenFor`), and one with no filter listens to no stream. A save that
  breaks either is refused with the fix; a watcher stored before the rules that
  breaks one reads `needs_update` (`update_needed/2`) and is told once
  (`needs_update_notices/1`).

  ## Follow-ups (M60_WATCHER_CODING_RUNS.md §4, §5)

  A watcher has a task (a job that runs on cues and reads each item), a
  follow-up (a job of its own kind, `Jobs.Registry.create_follow_up_job/2`,
  that its passing items set off and that is handed nothing from them), or
  both. A follow-up asks first: each run waits for the owner's tap on a card.
  The owner's Always allow on one of its cards (`Cues.FollowUps`) lets it run
  with no card from then on, bound to `follow_up_digest/2` of what it runs and
  what sets it off: any change to those clears it in its own write
  (`Memory.Repo.CuesFollowUpAllowSql.clear_stale_approval/2`), so undoing the
  change does not bring it back, and the owner takes it back with
  `ask_first/3`. Nothing here grants it. The watcher's own `daily_cap`, when
  set, counts its runs. Removing the watcher removes its follow-up's job.

  ## Options

  `:repo` (the `Memory.Repo` server), `:now`, `:cues_config` (the
  `[fermix_core.cues]` keyword, default the application's), `:scheduler`
  (passed to `Jobs.Registry`), `:skill_registry`, `:wake_scheduler` (a 0-arity
  function, default `Cues.wake_scheduler/0`).
  """

  require Logger

  alias FermixCore.Agents.SkillRegistry
  alias FermixCore.Cues
  alias FermixCore.Cues.Card
  alias FermixCore.Cues.Config
  alias FermixCore.Cues.FollowUps
  alias FermixCore.Cues.ListenFor
  alias FermixCore.Cues.Notices
  alias FermixCore.Cues.RecentDrops
  alias FermixCore.Cues.Telemetry
  alias FermixCore.Jobs.CueRun
  alias FermixCore.Jobs.CueSurface
  alias FermixCore.Jobs.DeliveryDefaults
  alias FermixCore.Jobs.Registry, as: JobsRegistry
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesFollowUpAllowSql
  alias FermixCore.Memory.Repo.CuesSql
  alias FermixCore.Memory.Repo.CuesWatchersSql

  @name_pattern ~r/\A[a-z0-9][a-z0-9-]{0,63}\z/
  @purpose_max 200
  @instruction_max 300
  @instruction_cap 20
  @note_max 300
  @task_timeout_max_minutes 30
  @task_prompt_max 8_000

  @cap_reached "This watcher has 20 instructions; merge some first."
  @none_needs_cap "A watcher with no filter wakes its task for every cue; say how many runs a day " <>
                    "it may cause, or say none."
  @none_takes_nothing "A watcher with no filter takes no purpose, instructions or keywords " <>
                        "to listen for."
  @needs_words "A watcher that filters needs keywords to listen for: list the names, products, " <>
                 "abbreviations and phrases an item it should see would contain, as listen_for."
  @drop_gone "That drop is no longer kept: Fermix keeps a stream watcher's last 50 drops until " <>
               "it restarts."
  @none_has_no_list "A watcher with no filter has no purpose, instructions or examples; switch it " <>
                      "to a model filter first."
  @must_report "A watcher's task must reach you: pick where it reports."
  @stale "The watcher changed while this change was being made; look at it again and retry."
  @report_choices "Telegram, Slack, Discord, WhatsApp, the phone or the Mac app"
  @needs_one "A watcher needs a task or a follow-up; give it a task before stopping its " <>
               "follow-up."
  @follow_up_needed "Give the follow-up its instructions: what it does when an item passes."
  @names_tools "Name the tools the follow-up may use."
  @follow_up_must_report "A watcher's follow-up must reach you: pick where it reports."
  @no_approval %{follow_up_approved_at: nil, follow_up_approval_digest: nil}
  @only_the_card "Only your Always allow on one of its cards lets it run with no card."

  @channel_names %{
    "telegram" => "Telegram",
    "slack" => "Slack",
    "discord" => "Discord",
    "whatsapp" => "WhatsApp",
    "mobile" => "the phone",
    "imessage" => "iMessage",
    "signal" => "Signal",
    "companion" => "the Mac app",
    "cli" => "the command line"
  }

  # Origins whose conversation cannot take a report later (design §9.5).
  @unreachable_origins %{
    "acp" =>
      ~s(delivery_mode "origin" cannot be used from an ACP session — the session is owned ) <>
        "by the client and ends with it, so a later run has nowhere to report back. Pass an " <>
        "explicit delivery_target on a configured channel instead.",
    "voice" =>
      ~s(delivery_mode "origin" cannot be used from a private voice call: the call's ) <>
        "conversation ends with it, so a later run has nowhere to report back. Pass an " <>
        "explicit delivery_target on a configured channel instead.",
    "cli" =>
      ~s(delivery_mode "origin" cannot be used from the command line: its replies go to the ) <>
        "daemon's output, where nobody reads a later run's report. Pass an explicit " <>
        "delivery_target on a configured channel instead."
  }

  @type opts :: keyword()
  @type watcher :: map()
  @typedoc "The update a stored watcher needs to keep a rule: words, or a filter."
  @type update_needed :: :words | :filter | nil
  @type result ::
          {:ok, %{required(:echo) => String.t(), optional(atom()) => term()}}
          | {:error, String.t()}

  @doc "The most active instructions a watcher may hold."
  @spec instruction_cap() :: pos_integer()
  def instruction_cap, do: @instruction_cap

  @doc "Where a change came from, as `channel:chat`, from the tool context (nil when unknown)."
  @spec origin(map()) :: String.t() | nil
  def origin(%{conversation_key: {channel, chat_id, _thread}}), do: "#{channel}:#{chat_id}"
  def origin(context) when is_map(context), do: nil

  # --- create ------------------------------------------------------------------------

  @doc """
  Creates a watcher and links its task: an existing job that runs on cues
  (`task_job_id`), or a new one made from `task` (its prompt), with
  `task_timeout_minutes` (at most 30) and the delivery the context and
  `delivery_target` / `delivery_mode` give. Params are atom-keyed.

  `follow_up` (a map) gives it a follow-up, made through
  `Jobs.Registry.create_follow_up_job/2`: `prompt` (the owner's instructions),
  `allowed_tools` (its grant, at least one), `name`, `skill_name`, `model`,
  `provider`, `timeout_minutes` and `delivery_mode` / `delivery_target` (as
  the task's). It asks first. A watcher needs a task or a follow-up. The
  caller bounds the follow-up's tools by its own turn, as `schedule_job`
  bounds a job's.
  """
  @spec create(map(), map(), opts()) :: result()
  def create(params, context, opts \\ []) when is_map(params) and is_map(context) do
    with {:ok, name} <- check_name(Map.get(params, :name)),
         {:ok, settings} <- filter_settings(params),
         {:ok, sources} <- check_sources(Map.get(params, :sources)),
         :ok <- keeps_rules(Map.put(settings, :sources, sources), opts),
         {:ok, instructions} <- check_instructions(Map.get(params, :instructions) || []),
         {:ok, spec} <- follow_up_spec(Map.get(params, :follow_up)),
         :ok <- name_free(name, opts),
         {:ok, jobs} <- jobs_for(name, params, spec, context, opts) do
      attrs =
        Map.merge(settings, %{
          id: Cues.id("cwt"),
          name: name,
          task_job_id: jobs.task && jobs.task.id,
          follow_up_job_id: jobs.follow_up && jobs.follow_up.id,
          task_notes: Map.get(params, :task_notes, false) == true,
          created_from: origin(context)
        })

      insert_created(attrs, sources, instructions, jobs, chat(context), opts)
    end
  end

  defp insert_created(attrs, sources, instructions, jobs, chat, opts) do
    request = {:insert_watcher, attrs, sources, instructions, now(opts)}

    case call(request, opts) do
      {:ok, watcher} ->
        {:ok,
         %{
           watcher: watcher,
           job: jobs.task,
           follow_up_job: jobs.follow_up,
           echo: created_echo(watcher, jobs, chat, opts)
         }}

      {:error, reason} ->
        Enum.each(jobs.created, &drop_created_job(&1, opts))
        refusal(reason, attrs.name)
    end
  end

  # The task and the follow-up's job, each made or linked; a follow-up job
  # that cannot be made takes back a task job made for it.
  defp jobs_for(name, params, spec, context, opts) do
    with {:ok, task, task_created?} <- task_for(name, params, context, opts) do
      created = if task_created?, do: [task], else: []

      case follow_up_job_for(name, spec, context, opts) do
        {:ok, nil} ->
          {:ok, %{task: task, follow_up: nil, created: created}}

        {:ok, job} ->
          {:ok, %{task: task, follow_up: job, created: created ++ [job]}}

        {:error, sentence} ->
          Enum.each(created, &drop_created_job(&1, opts))
          {:error, sentence}
      end
    end
  end

  # A job made for a watcher that could not be written is removed again, so a
  # failed create leaves nothing behind.
  defp drop_created_job(job, opts) do
    case JobsRegistry.remove_job(job.id, registry_opts(opts)) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "Cues.Watchers: the task job #{job.id} made for a watcher that was not created " <>
            "could not be removed: #{inspect(reason)}"
        )
    end
  end

  defp check_name(name) when is_binary(name) do
    if Regex.match?(@name_pattern, name),
      do: {:ok, name},
      else:
        {:error,
         "A watcher's name is 1 to 64 lowercase letters, digits and dashes, starting with a " <>
           "letter or digit."}
  end

  defp check_name(_name), do: {:error, "Give the watcher a name."}

  defp name_free(name, opts) do
    case call({:get_watcher, {:name, name}}, opts) do
      {:error, :not_found} -> :ok
      {:ok, _watcher} -> {:error, "There is already a watcher named #{name}."}
      {:error, reason} -> refusal(reason, name)
    end
  end

  # --- filter settings -----------------------------------------------------------------

  defp filter_settings(%{filter: "none"} = params) do
    with :ok <- refuse_for_none(params),
         {:ok, daily_cap} <- none_daily_cap(Map.get(params, :daily_cap)) do
      {:ok,
       %{
         filter: "none",
         purpose: nil,
         listen_for: [],
         daily_cap: daily_cap,
         filter_budget: 0
       }}
    end
  end

  defp filter_settings(%{filter: "llm"} = params) do
    with {:ok, purpose} <- check_purpose(Map.get(params, :purpose)),
         {:ok, words} <- check_words(Map.get(params, :listen_for)),
         {:ok, daily_cap} <- count_setting(Map.get(params, :daily_cap), :daily_cap),
         {:ok, budget} <- count_setting(Map.get(params, :filter_budget), :filter_budget) do
      {:ok,
       %{
         filter: "llm",
         purpose: purpose,
         listen_for: words,
         daily_cap: daily_cap,
         filter_budget: budget
       }}
    end
  end

  defp filter_settings(_params),
    do: {:error, ~s(Pick the watcher's filter: "llm", where a model judges each item, or "none".)}

  defp refuse_for_none(params) do
    given =
      Enum.filter(
        [:purpose, :instructions, :listen_for],
        &present?(params, &1)
      )

    if given == [], do: :ok, else: {:error, @none_takes_nothing}
  end

  defp present?(params, key) do
    case Map.get(params, key) do
      nil -> false
      [] -> false
      "" -> false
      _value -> true
    end
  end

  defp none_daily_cap("none"), do: {:ok, 0}
  defp none_daily_cap(cap) when is_integer(cap) and cap >= 1, do: {:ok, cap}
  defp none_daily_cap(_cap), do: {:error, @none_needs_cap}

  defp count_setting(nil, _key), do: {:ok, 0}
  defp count_setting("none", _key), do: {:ok, 0}
  defp count_setting(n, _key) when is_integer(n) and n >= 0, do: {:ok, n}

  defp count_setting(_n, key),
    do: {:error, ~s(#{key} is a whole number of runs or calls in 24 hours, or "none".)}

  defp check_purpose(purpose) when is_binary(purpose) do
    purpose = String.trim(purpose)

    cond do
      purpose == "" ->
        {:error, "Give the watcher a purpose: one line on what it is for."}

      String.contains?(purpose, ["\n", "\r"]) ->
        {:error, "A watcher's purpose is one line."}

      String.length(purpose) > @purpose_max ->
        {:error, "A watcher's purpose is at most 200 characters."}

      true ->
        {:ok, purpose}
    end
  end

  defp check_purpose(_purpose),
    do: {:error, "Give the watcher a purpose: one line on what it is for."}

  defp check_words(nil), do: {:error, @needs_words}
  defp check_words(words), do: ListenFor.validate(words)

  # --- the rules (M60_CUE_INTAKE_AT_SCALE.md §3.1) ---------------------------------------

  @doc """
  The update a stored watcher needs to keep the rules, or nil: `:words` for one
  that filters with no words to listen for, `:filter` for one with no filter
  that listens to a stream (`stream_refs`, the stream sources in settings).
  """
  @spec update_needed(map(), [String.t()]) :: update_needed()
  def update_needed(%{filter: "llm", listen_for: []}, stream_refs) when is_list(stream_refs),
    do: :words

  def update_needed(%{filter: "none", sources: sources}, stream_refs)
      when is_list(sources) and is_list(stream_refs),
      do: if(Enum.any?(sources, &(&1 in stream_refs)), do: :filter)

  def update_needed(watcher, stream_refs) when is_map(watcher) and is_list(stream_refs), do: nil

  @doc "The refs of the stream sources in the cue settings (`:cues_config`)."
  @spec stream_refs(opts()) :: [String.t()]
  def stream_refs(opts \\ []) when is_list(opts),
    do: for(%{kind: :stream, ref: ref} <- Config.sources(cues_config(opts)), do: ref)

  # A save that leaves a rule broken is refused, naming the fix.
  defp keeps_rules(watcher, opts) do
    streams = stream_refs(opts)

    case update_needed(watcher, streams) do
      nil -> :ok
      :words -> {:error, @needs_words}
      :filter -> {:error, no_filter_on_stream(Enum.filter(watcher.sources, &(&1 in streams)))}
    end
  end

  defp no_filter_on_stream(refs) do
    "A watcher with no filter cannot listen to a stream (#{Enum.join(refs, ", ")}), where it " <>
      "would pass every item: give it a model filter and keywords to listen for, or pick " <>
      "sources that are not streams."
  end

  @doc """
  Tells the owner, once per watcher, about each stored watcher that breaks a
  rule (`Notices.watcher/4` `:needs_update`): it gets no items until a change
  in chat fixes it. Called once per start of the cue sweeper, at its first
  pass, so the boot that first finds such a watcher tells about it. `:timeout`
  and `:on_timeout` bound every Repo call it makes, the notices' claims
  included. Returns how many notices this call sent; a send that fails is
  logged by `Cues.Notices` and tried again at the sweeper's next start.
  """
  @spec needs_update_notices(opts()) :: {:ok, non_neg_integer()} | {:error, term()}
  def needs_update_notices(opts \\ []) when is_list(opts) do
    streams = stream_refs(opts)

    with {:ok, watchers} <- call({:list_watchers}, opts) do
      sent =
        watchers
        |> Enum.map(&{&1, update_needed(&1, streams)})
        |> Enum.reject(fn {_watcher, needed} -> is_nil(needed) end)
        |> Enum.map(fn {watcher, needed} -> notify_needed(watcher, needed, opts) end)
        |> Enum.count(&(&1 == :sent))

      {:ok, sent}
    end
  end

  defp notify_needed(watcher, needed, opts),
    do: Notices.watcher(watcher.id, :needs_update, %{needed: needed}, opts)

  # --- sources, instructions -------------------------------------------------------------

  defp check_sources(sources) when is_list(sources) and sources != [] do
    case Enum.reject(sources, &Config.valid_name?/1) do
      [] -> {:ok, Enum.uniq(sources)}
      [bad | _rest] -> {:error, "#{inspect(bad)} is not a source name."}
    end
  end

  defp check_sources(_sources), do: {:error, "Name at least one source the watcher listens to."}

  defp check_instructions(texts) when is_list(texts) do
    texts = Enum.map(texts, &trim_text/1)

    cond do
      Enum.any?(texts, &(not is_binary(&1) or &1 == "")) ->
        {:error, "An instruction is a non-empty sentence."}

      Enum.any?(texts, &(String.length(&1) > @instruction_max)) ->
        {:error, "An instruction is at most 300 characters; split it into two."}

      length(texts) > @instruction_cap ->
        {:error, @cap_reached}

      true ->
        {:ok, texts}
    end
  end

  defp check_instructions(_texts), do: {:error, "Instructions are a list of sentences."}

  defp trim_text(text) when is_binary(text), do: String.trim(text)
  defp trim_text(other), do: other

  # --- the task ---------------------------------------------------------------------------

  # A watcher needs a task or a follow-up: with a follow-up and no task given,
  # it has none; with neither, the task is asked for.
  defp task_for(name, params, context, opts) do
    case {Map.get(params, :task_job_id), present?(params, :task), present?(params, :follow_up)} do
      {job_id, _task?, _follow_up?} when is_binary(job_id) and job_id != "" ->
        linked_task(job_id, opts)

      {_none, false, true} ->
        {:ok, nil, false}

      _new ->
        new_task(name, params, context, opts)
    end
  end

  defp linked_task(job_id, opts) do
    with {:ok, job} <- fetch_job(job_id, opts),
         :ok <- cue_only(job),
         :ok <- reachable_target(job.delivery_mode, job.delivery_target) do
      {:ok, job, false}
    end
  end

  defp fetch_job(job_id, opts) do
    case JobsRegistry.get_job(job_id, registry_opts(opts)) do
      {:ok, job} -> {:ok, job}
      {:error, :not_found} -> {:error, "There is no job #{job_id}."}
      {:error, reason} -> refusal(reason, job_id)
    end
  end

  defp cue_only(job) do
    if JobsRegistry.cue_job?(job),
      do: :ok,
      else:
        {:error,
         "Job #{job.id} runs on a schedule; a watcher's task must be a job that runs on cues."}
  end

  defp new_task(name, params, context, opts) do
    with {:ok, prompt} <- task_prompt(Map.get(params, :task)),
         {:ok, timeout} <- task_timeout(Map.get(params, :task_timeout_minutes)),
         {:ok, {mode, target}} <- task_delivery(params, context),
         :ok <- reachable_target(mode, target),
         {:ok, trust} <- creator_trust(context) do
      attrs =
        %{
          name: blank_to_nil(Map.get(params, :task_name)) || "watcher #{name}",
          description: "The task of watcher #{name}.",
          task_prompt: prompt,
          delivery_mode: mode,
          delivery_target: target,
          created_by_agent_id: Map.get(context, :memory_agent_id, "main"),
          created_by_session_id: origin_session_id(context),
          created_by_channel: Map.get(context, :source_channel),
          created_by_trust: trust
        }
        |> put_timeout(timeout)

      create_job(attrs, opts)
    end
  end

  defp create_job(attrs, opts) do
    case JobsRegistry.create_cue_job(attrs, registry_opts(opts)) do
      {:ok, job} -> {:ok, job, true}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> refusal(reason, attrs.name)
    end
  end

  defp task_prompt(prompt) when is_binary(prompt) do
    prompt = String.trim(prompt)

    cond do
      prompt == "" ->
        {:error, task_needed()}

      String.length(prompt) > @task_prompt_max ->
        {:error, "A task's prompt is at most 8,000 characters."}

      true ->
        {:ok, prompt}
    end
  end

  defp task_prompt(_prompt), do: {:error, task_needed()}

  defp task_needed,
    do: "Give the watcher a task: an existing job that runs on cues, or the prompt for a new one."

  defp task_timeout(nil), do: {:ok, nil}

  defp task_timeout(minutes)
       when is_integer(minutes) and minutes >= 1 and minutes <= @task_timeout_max_minutes,
       do: {:ok, minutes * 60}

  defp task_timeout(_minutes),
    do: {:error, "A job that runs on cues may run for at most 30 minutes."}

  defp put_timeout(attrs, nil), do: attrs
  defp put_timeout(attrs, seconds), do: Map.put(attrs, :timeout_seconds, seconds)

  # A task created from chat reports to that chat unless a target is named
  # (design §9.5).
  defp task_delivery(params, context) do
    mode = Map.get(params, :delivery_mode)
    target = Map.get(params, :delivery_target)

    cond do
      mode in ["none", "local"] -> {:error, @must_report}
      is_map(target) -> resolve_delivery(%{"delivery_target" => target}, context)
      true -> origin_delivery(context)
    end
  end

  defp origin_delivery(context) do
    case Map.fetch(@unreachable_origins, origin_channel(context)) do
      {:ok, sentence} -> {:error, sentence}
      :error -> resolve_delivery(%{"delivery_mode" => "origin"}, context)
    end
  end

  defp resolve_delivery(args, context) do
    case DeliveryDefaults.resolve(args, context, jobs_config: []) do
      {:ok, {mode, target}} -> {:ok, {mode, target}}
      {:error, {:invalid_delivery_target, sentence}} -> {:error, sentence}
      {:error, reason} -> {:error, "That delivery cannot be used: #{inspect(reason)}"}
    end
  end

  defp reachable_target(mode, _target) when mode not in ["origin", "channel"],
    do: {:error, @must_report}

  defp reachable_target(_mode, target) when is_map(target) do
    if CueRun.delivery_target_allowed?(target),
      do: :ok,
      else:
        {:error,
         "Watcher reports cannot go to #{channel_name(target)} yet; pick #{@report_choices}."}
  end

  defp reachable_target(_mode, _target), do: {:error, @must_report}

  defp channel_name(target) do
    platform = Map.get(target, "platform") || Map.get(target, :platform)
    Map.get(@channel_names, platform, to_string(platform))
  end

  defp origin_channel(%{conversation_key: {channel, _chat, _thread}}), do: to_string(channel)
  defp origin_channel(_context), do: nil

  defp origin_session_id(%{conversation_key: {channel, chat_id, thread}}),
    do: Enum.map_join([channel, chat_id, thread], ":", &to_string/1)

  defp origin_session_id(context), do: Map.get(context, :session_id)

  defp creator_trust(context) do
    case Map.get(context, :source_trust) do
      trust when is_atom(trust) and not is_nil(trust) -> {:ok, Atom.to_string(trust)}
      _absent -> {:error, "This turn carries no trust, so it cannot create a task."}
    end
  end

  # --- the follow-up (M60_WATCHER_CODING_RUNS.md §4.1, §5) -------------------------------

  # The owner's follow-up as given, checked before any job is made. A new one
  # asks first, so it takes no Always allow.
  defp follow_up_spec(nil), do: {:ok, nil}

  defp follow_up_spec(params) when is_map(params) do
    with :ok <- never_granted(params),
         {:ok, prompt} <- follow_up_prompt(Map.get(params, :prompt)),
         {:ok, tools} <- follow_up_tools(Map.get(params, :allowed_tools)),
         {:ok, timeout} <- task_timeout(Map.get(params, :timeout_minutes)) do
      {:ok, %{params: params, prompt: prompt, tools: tools, timeout: timeout}}
    end
  end

  defp follow_up_spec(_params),
    do: {:error, "A follow-up is given as its instructions and its tools."}

  # Always allow is granted only by the owner's answer on a card, never here.
  defp never_granted(%{always_allow: true}), do: {:error, @only_the_card}
  defp never_granted(_params), do: :ok

  defp follow_up_prompt(prompt) when is_binary(prompt) do
    prompt = String.trim(prompt)

    cond do
      prompt == "" ->
        {:error, @follow_up_needed}

      String.length(prompt) > @task_prompt_max ->
        {:error, "A follow-up's instructions are at most 8,000 characters."}

      true ->
        {:ok, prompt}
    end
  end

  defp follow_up_prompt(_prompt), do: {:error, @follow_up_needed}

  defp follow_up_tools([_ | _] = tools) do
    if Enum.all?(tools, &(is_binary(&1) and &1 != "")),
      do: {:ok, Enum.uniq(tools)},
      else: {:error, @names_tools}
  end

  defp follow_up_tools(_tools), do: {:error, @names_tools}

  defp follow_up_job_for(_name, nil, _context, _opts), do: {:ok, nil}

  defp follow_up_job_for(name, spec, context, opts) do
    with {:ok, {mode, target}} <- follow_up_delivery(spec.params, context),
         {:ok, trust} <- creator_trust(context) do
      attrs =
        spec.params
        |> follow_up_routing()
        |> Map.merge(%{
          name: blank_to_nil(Map.get(spec.params, :name)) || "follow-up of #{name}",
          description: "The follow-up of watcher #{name}.",
          task_prompt: spec.prompt,
          allowed_tools: spec.tools,
          delivery_mode: mode,
          delivery_target: target,
          created_by_agent_id: Map.get(context, :memory_agent_id, "main"),
          created_by_session_id: origin_session_id(context),
          created_by_channel: Map.get(context, :source_channel),
          created_by_trust: trust
        })
        |> put_timeout(spec.timeout)

      registry_result(JobsRegistry.create_follow_up_job(attrs, registry_opts(opts)), attrs.name)
    end
  end

  # The skill, model and provider the owner named; absent ones stay unset.
  defp follow_up_routing(params) do
    for key <- [:skill_name, :model, :provider],
        value = blank_to_nil(Map.get(params, key)),
        into: %{},
        do: {key, value}
  end

  # A follow-up reports as a task does: to this chat unless a target is named.
  defp follow_up_delivery(params, context) do
    with {:ok, {mode, target}} <- task_delivery(params, context),
         :ok <- reachable_target(mode, target) do
      {:ok, {mode, target}}
    else
      {:error, @must_report} -> {:error, @follow_up_must_report}
      {:error, sentence} -> {:error, sentence}
    end
  end

  defp registry_result({:ok, job}, _name), do: {:ok, job}
  defp registry_result({:error, reason}, _name) when is_binary(reason), do: {:error, reason}
  defp registry_result({:error, reason}, name), do: refusal(reason, name)

  @doc """
  Gives the watcher a follow-up, or changes the one it has (§3.5), on the
  owner's consent turn (`context`, which the caller checked). A new follow-up
  takes `create/3`'s `follow_up` map; a change takes any of its keys, and its
  job changes through `Jobs.Registry.update_follow_up_job/3`, whose write
  clears an Always allow it no longer matches. `always_allow: false` takes
  the Always allow back (`ask_first/3`); `true` is refused, since only the
  owner's answer on a card grants it. The caller bounds the tools by its own
  turn.
  """
  @spec set_follow_up(String.t(), map(), map(), opts()) :: result()
  def set_follow_up(name, params, context, opts \\ [])
      when is_binary(name) and is_map(params) and is_map(context) do
    with {:ok, watcher} <- fetch(name, opts) do
      cond do
        watcher.follow_up_job_id -> change_follow_up(watcher, params, context, opts)
        Map.keys(params) == [:always_allow] -> {:error, "Watcher #{name} has no follow-up."}
        true -> add_follow_up(watcher, params, context, opts)
      end
    end
  end

  defp add_follow_up(watcher, params, context, opts) do
    with {:ok, spec} <- follow_up_spec(params),
         {:ok, job} <- follow_up_job_for(watcher.name, spec, context, opts) do
      patch = Map.merge(%{follow_up_job_id: job.id}, @no_approval)

      case write(watcher, patch, nil, opts) do
        {:ok, %{watcher: updated}} ->
          echo =
            "Watcher #{updated.name} now has a follow-up.\n" <>
              follow_up_echo(updated, job, chat(context), false)

          {:ok, %{watcher: updated, follow_up_job: job, echo: echo}}

        {:error, sentence} ->
          drop_created_job(job, opts)
          {:error, sentence}
      end
    end
  end

  # A change to its job, taking its Always allow back, or both: the job first,
  # whose write clears an Always allow it no longer matches.
  defp change_follow_up(watcher, params, context, opts) do
    with {:ok, ask_first?} <- asks_first_again(params),
         {:ok, job_attrs} <- follow_up_job_attrs(params, context) do
      case {map_size(job_attrs), ask_first?} do
        {0, false} -> {:error, "Say what to change on the follow-up."}
        {0, true} -> ask_first(watcher.name, "chat", opts)
        {_changes, _ask_first?} -> change_job(watcher, job_attrs, ask_first?, context, opts)
      end
    end
  end

  defp asks_first_again(params) do
    case Map.fetch(params, :always_allow) do
      :error -> {:ok, false}
      {:ok, false} -> {:ok, true}
      {:ok, true} -> {:error, @only_the_card}
      {:ok, _other} -> {:error, "always_allow takes false, which makes it ask first again."}
    end
  end

  defp change_job(watcher, job_attrs, ask_first?, context, opts) do
    with {:ok, job} <- update_follow_up_job(watcher.follow_up_job_id, job_attrs, opts),
         {:ok, _asked} <- maybe_ask_first(ask_first?, watcher.name, opts),
         {:ok, updated} <- fetch(watcher.name, opts),
         {:ok, allowed?} <- always_allowed(updated, opts) do
      echo =
        "Watcher #{updated.name}'s follow-up changed.\n" <>
          follow_up_echo(updated, job, chat(context), allowed?)

      {:ok, %{watcher: updated, follow_up_job: job, echo: echo}}
    end
  end

  defp maybe_ask_first(false, _name, _opts), do: {:ok, nil}
  defp maybe_ask_first(true, name, opts), do: ask_first(name, "chat", opts)

  # The follow-up's job fields a change names, each checked as at creation.
  defp follow_up_job_attrs(params, context) do
    with {:ok, prompt} <- optional_check(params, :prompt, &follow_up_prompt/1),
         {:ok, tools} <- optional_check(params, :allowed_tools, &follow_up_tools/1),
         {:ok, timeout} <- optional_check(params, :timeout_minutes, &task_timeout/1),
         {:ok, delivery} <- changed_delivery(params, context) do
      attrs =
        params
        |> follow_up_routing()
        |> put_given(:task_prompt, prompt)
        |> put_given(:allowed_tools, tools)
        |> put_given(:timeout_seconds, timeout)
        |> Map.merge(delivery)

      {:ok, attrs}
    end
  end

  defp optional_check(params, key, check) do
    if Map.has_key?(params, key), do: check.(Map.get(params, key)), else: {:ok, nil}
  end

  defp changed_delivery(params, context) do
    if present?(params, :delivery_mode) or present?(params, :delivery_target) do
      with {:ok, {mode, target}} <- follow_up_delivery(params, context),
           do: {:ok, %{delivery_mode: mode, delivery_target: target}}
    else
      {:ok, %{}}
    end
  end

  defp put_given(map, _key, nil), do: map
  defp put_given(map, key, value), do: Map.put(map, key, value)

  defp update_follow_up_job(job_id, attrs, opts),
    do:
      registry_result(
        JobsRegistry.update_follow_up_job(job_id, attrs, registry_opts(opts)),
        job_id
      )

  @doc """
  Stops the watcher's follow-up (§3.5): its waiting card and any trigger left
  to start are refused, and its job is removed. Refused while its run holds
  the job, and for a watcher with no task, which would have nothing left.
  """
  @spec remove_follow_up(String.t(), opts()) :: result()
  def remove_follow_up(name, opts \\ []) when is_binary(name) do
    with {:ok, watcher} <- fetch(name, opts),
         :ok <- has_follow_up(watcher),
         :ok <- keeps_task(watcher) do
      case call({:remove_follow_up, watcher.id, watcher.updated_at, now(opts)}, opts) do
        {:ok, removed} ->
          Enum.each(removed.refused_triggers, &FollowUps.emit_refused(&1, "follow_up_stopped"))
          remove_follow_up_job(watcher.follow_up_job_id, opts)

          {:ok,
           %{
             echo: "Watcher #{name}'s follow-up is stopped and its job removed.",
             removed: removed
           }}

        {:error, reason} ->
          refusal(reason, name)
      end
    end
  end

  defp has_follow_up(%{follow_up_job_id: nil, name: name}),
    do: {:error, "Watcher #{name} has no follow-up."}

  defp has_follow_up(_watcher), do: :ok

  defp keeps_task(%{task_job_id: nil}), do: {:error, @needs_one}
  defp keeps_task(_watcher), do: :ok

  defp remove_follow_up_job(job_id, opts) do
    case JobsRegistry.remove_job(job_id, registry_opts(opts)) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Cues.Watchers: follow-up job #{job_id} was not removed: #{inspect(reason)}")
    end
  end

  @doc """
  Takes back the Always allow of watcher `name`'s follow-up, so its next item
  asks first again: from chat (`kind` `"chat"`, on the owner's consent turn,
  which the caller checked), from an app (`"management"`) or from the setup
  page's Cues tab (`"setup_page"`). It only ever lowers what the follow-up may
  do, and a follow-up that already asks first is told so. Traced as
  `follow_up_always_allow_revoked`, with `kind` as its origin, when it took one
  back.
  """
  @spec ask_first(String.t(), String.t(), opts()) :: result()
  def ask_first(name, kind, opts \\ [])
      when is_binary(name) and kind in ["chat", "management", "setup_page"] do
    with {:ok, watcher} <- fetch(name, opts),
         :ok <- has_follow_up(watcher),
         {:ok, revoked?} <- revoke(watcher, opts),
         {:ok, updated} <- fetch(name, opts) do
      if revoked?, do: emit_revoked(watcher, kind)
      {:ok, %{watcher: updated, echo: asks_first_echo(name, revoked?)}}
    end
  end

  defp revoke(watcher, opts) do
    case allow_call({:revoke, watcher.id}, opts) do
      {:ok, revoked?} -> {:ok, revoked?}
      {:error, reason} -> follow_up_refusal(reason, watcher.name)
    end
  end

  defp emit_revoked(watcher, kind) do
    Telemetry.lifecycle(:follow_up_always_allow_revoked, %{}, %{
      watcher_id: watcher.id,
      job_id: watcher.follow_up_job_id,
      kind: kind
    })
  end

  defp asks_first_echo(name, true),
    do: "Watcher #{name}'s follow-up asks first again: each run waits for your tap on its card."

  defp asks_first_echo(name, false),
    do: "Watcher #{name}'s follow-up already asks first: each run waits for your tap on its card."

  @doc """
  The digest a follow-up's Always allow is bound to (§5): the job's prompt,
  tools, skill, model, provider and delivery target, and the watcher's sources
  and filter (its kind, purpose, words and active instructions). Pure;
  `CuesFollowUpAllowSql` computes it from the stored rows for a card, its
  Always allow and every pass.
  """
  @spec follow_up_digest(map(), map()) :: String.t()
  def follow_up_digest(job, watcher) when is_map(job) and is_map(watcher) do
    instructions = Enum.map(watcher.instructions, & &1.text)

    [
      ["prompt", job.task_prompt],
      ["tools", Enum.sort(job.allowed_tools || [])],
      ["skill", job.skill_name],
      ["model", job.model],
      ["provider", job.provider],
      ["delivery", [job.delivery_mode, pairs(job.delivery_target)]],
      ["sources", Enum.sort(watcher.sources)],
      ["filter", [watcher.filter, watcher.purpose, watcher.listen_for, instructions]]
    ]
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # A map as sorted key-value pairs, so its digest never depends on order.
  defp pairs(nil), do: nil

  defp pairs(map) when is_map(map),
    do: map |> Enum.map(fn {k, v} -> [to_string(k), v] end) |> Enum.sort()

  defp allow_call(request, opts) do
    repo_opts =
      [server: Keyword.get(opts, :repo, Repo)] ++ Keyword.take(opts, [:timeout, :on_timeout])

    Repo.cues_call(CuesFollowUpAllowSql, request, repo_opts)
  end

  defp follow_up_refusal(:no_follow_up, name), do: {:error, "Watcher #{name} has no follow-up."}
  defp follow_up_refusal(reason, name), do: refusal(reason, name)

  # The follow-up as design §3.1 sums it up, below the watcher it belongs to.
  defp follow_up_echo(watcher, job, chat, allowed?) do
    delivery = %{mode: job.delivery_mode, target: job.delivery_target}

    Enum.join(
      [
        ~s(Follow-up "#{job.name}", run when an item passes:),
        "  It will: #{job.task_prompt}",
        "  Uses: #{Enum.join(job.allowed_tools, ", ")}",
        "  Reports to: #{Card.reports_to(delivery, chat: chat)}",
        "  #{allow_words(allowed?)}",
        "  Limits: #{limits_words(watcher.daily_cap)}",
        "It is never handed the item: the item only decides when it runs."
      ],
      "\n"
    )
  end

  defp allow_words(true), do: "Always allowed: it runs on each passing item with no card."

  defp allow_words(false),
    do:
      "Asks first: each run waits for your tap on a short card, whose Always allow lets it " <>
        "run with no card from then on."

  defp limits_words(0),
    do: "items older than 15 minutes are ignored; one run at a time."

  defp limits_words(cap),
    do:
      "items older than 15 minutes are ignored; one run at a time; at most #{cap} a day " <>
        "(the watcher's daily cap)."

  # The chat a change came from, which a follow-up reporting there calls "this chat".
  defp chat(%{conversation_key: {channel, chat_id, _thread}}),
    do: %{platform: to_string(channel), chat_id: to_string(chat_id)}

  defp chat(_context), do: nil

  @doc """
  Whether watcher `watcher`'s follow-up is always allowed for what it runs and
  what sets it off now, so a passing item runs it with no card (§5); nil with
  no follow-up.
  """
  @spec always_allowed(watcher(), opts()) :: {:ok, boolean() | nil} | {:error, String.t()}
  def always_allowed(%{follow_up_job_id: nil}, _opts), do: {:ok, nil}

  def always_allowed(%{id: id, name: name}, opts) when is_binary(id) do
    case allow_call({:allowed, id}, opts) do
      {:ok, allowed?} -> {:ok, allowed?}
      {:error, reason} -> follow_up_refusal(reason, name)
    end
  end

  # --- reads -------------------------------------------------------------------------------

  @doc "One watcher with its sources, instructions and 20 most recent examples."
  @spec show(String.t(), opts()) :: {:ok, watcher()} | {:error, String.t()}
  def show(name, opts \\ []) when is_binary(name), do: fetch(name, opts)

  @doc "Every watcher, by name."
  @spec list(opts()) :: {:ok, [watcher()]} | {:error, String.t()}
  def list(opts \\ []) do
    case call({:list_watchers}, opts) do
      {:ok, watchers} -> {:ok, watchers}
      {:error, reason} -> refusal(reason, "")
    end
  end

  @doc """
  The watcher whose task or follow-up is `job_id`, or nil: `update_job` on
  either needs the owner's consent turn and `remove_job` refuses either while
  its watcher exists (M60_WATCHER_CODING_RUNS.md §4.1).
  """
  @spec watcher_for_job(String.t(), opts()) :: {:ok, watcher() | nil} | {:error, term()}
  def watcher_for_job(job_id, opts \\ []) when is_binary(job_id),
    do: call({:watcher_for_job, job_id}, opts)

  @doc "The name of the watcher whose task or follow-up is `job_id`, or nil."
  @spec name_for_job(String.t(), opts()) :: {:ok, String.t() | nil} | {:error, term()}
  def name_for_job(job_id, opts \\ []) when is_binary(job_id) do
    case watcher_for_job(job_id, opts) do
      {:ok, nil} -> {:ok, nil}
      {:ok, watcher} -> {:ok, watcher.name}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Which configured sources of `refs` are missing, as the owner's sentence per source."
  @spec missing_sources([String.t()], opts()) :: [String.t()]
  def missing_sources(refs, opts \\ []) when is_list(refs) do
    config = cues_config(opts)

    for ref <- refs, Config.source(ref, config) == :error do
      "#{ref} is not set up yet; add it in settings."
    end
  end

  defp fetch(name, opts) do
    case call({:get_watcher, {:name, name}}, opts) do
      {:ok, watcher} -> {:ok, watcher}
      {:error, reason} -> refusal(reason, name)
    end
  end

  # --- changes ---------------------------------------------------------------------------

  @doc """
  Pauses the watcher (design §8.8): new cues are not routed to it and its
  waiting items are not filtered; the items it already passed still wake its
  task.
  """
  @spec pause(String.t(), opts()) :: result()
  def pause(name, opts \\ []) when is_binary(name) do
    with {:ok, watcher} <- fetch(name, opts),
         {:ok, _written} <- write(watcher, %{enabled: false}, nil, opts) do
      {:ok,
       %{
         echo:
           "Watcher #{name} is paused. New items are not delivered to it and nothing " <>
             "waiting is filtered; items it already passed still go to its task."
       }}
    end
  end

  @doc "Routes new cues to the watcher again."
  @spec resume(String.t(), opts()) :: result()
  def resume(name, opts \\ []) when is_binary(name) do
    with {:ok, watcher} <- fetch(name, opts),
         {:ok, _written} <- write(watcher, %{enabled: true}, nil, opts) do
      {:ok, %{echo: "Watcher #{name} is listening again."}}
    end
  end

  @doc """
  Removes the watcher (design §8.8): refused while a filter call or a task run
  holds one of its deliveries, or its follow-up runs; otherwise its waiting
  deliveries expire with a gap per source, its follow-up's open triggers are
  refused, and the watcher, its instructions and examples go. Its task job
  stays; its follow-up's job is removed with it (M60_WATCHER_CODING_RUNS.md §5).
  """
  @spec remove(String.t(), opts()) :: result()
  def remove(name, opts \\ []) when is_binary(name) do
    with {:ok, watcher} <- fetch(name, opts) do
      case call({:remove_watcher, watcher.id, now(opts)}, opts) do
        {:ok, removed} -> removed(watcher, removed, opts)
        {:error, reason} -> refusal(reason, name)
      end
    end
  end

  # The watcher is gone: its follow-up's job goes with it (§5).
  defp removed(watcher, removed, opts) do
    emit_removed(removed, watcher)
    if watcher.follow_up_job_id, do: remove_follow_up_job(watcher.follow_up_job_id, opts)
    {:ok, %{echo: removed_echo(watcher, removed), removed: removed}}
  end

  defp emit_removed(removed, watcher) do
    Enum.each(removed.expired, fn delivery ->
      Telemetry.lifecycle(:expired, %{}, %{
        source_ref: delivery.source_ref,
        cue_id: delivery.cue_id,
        delivery_id: delivery.delivery_id,
        watcher_id: watcher.id,
        reason: "watcher_removed"
      })
    end)

    Enum.each(removed.refused_triggers, &FollowUps.emit_refused(&1, "watcher_removed"))

    Enum.each(removed.gaps, fn gap ->
      Telemetry.lifecycle(:gap, %{count: gap.count}, %{
        source_ref: gap.source_ref,
        gap_id: gap.gap_id,
        watcher_id: watcher.id,
        reason: "watcher_removed"
      })
    end)
  end

  @doc """
  Adds instructions and, in the same change, removes the active ones numbered
  in `remove` (design §8.4). Refused past 20 active.
  """
  @spec add_instructions(String.t(), [String.t()], [integer()], String.t() | nil, opts()) ::
          result()
  def add_instructions(name, texts, remove \\ [], from, opts \\ [])
      when is_binary(name) and is_list(texts) and is_list(remove) do
    with {:ok, texts} <- check_instructions(texts),
         :ok <- non_empty(texts, "Give at least one instruction to add."),
         :ok <- numbers(remove) do
      change_list(name, %{add: texts, remove: remove}, from, opts)
    end
  end

  @doc "Removes the active instructions numbered in `numbers`."
  @spec remove_instructions(String.t(), [integer()], String.t() | nil, opts()) :: result()
  def remove_instructions(name, numbers, from, opts \\ [])
      when is_binary(name) and is_list(numbers) do
    with :ok <- non_empty(numbers, "Name the instruction numbers to remove."),
         :ok <- numbers(numbers) do
      change_list(name, %{add: [], remove: numbers}, from, opts)
    end
  end

  defp change_list(name, change, from, opts) do
    with {:ok, watcher} <- fetch(name, opts),
         :ok <- has_list(watcher) do
      request = {:change_instructions, watcher.id, change, from, now(opts), @instruction_cap}

      case call(request, opts) do
        {:ok, changed} -> {:ok, Map.put(changed, :echo, list_echo(changed))}
        {:error, reason} -> refusal(reason, name)
      end
    end
  end

  @doc "Brings a removed instruction back with its number; refused at the cap."
  @spec restore_instruction(String.t(), integer(), String.t() | nil, opts()) :: result()
  def restore_instruction(name, number, from, opts \\ []) when is_binary(name) do
    with :ok <- numbers([number]),
         {:ok, watcher} <- fetch(name, opts),
         :ok <- has_list(watcher) do
      request = {:restore_instruction, watcher.id, number, from, now(opts), @instruction_cap}

      case call(request, opts) do
        {:ok, %{restored: row}} -> {:ok, %{restored: row, echo: "Restored #{line(row)}"}}
        {:error, reason} -> refusal(reason, name)
      end
    end
  end

  @doc """
  Replaces several active instructions with one (the only way past the cap);
  each removed row points at the new one. Echoed in full.
  """
  @spec merge_instructions(String.t(), [integer()], String.t(), String.t() | nil, opts()) ::
          result()
  def merge_instructions(name, numbers, text, from, opts \\ [])
      when is_binary(name) and is_list(numbers) do
    with :ok <- numbers(numbers),
         :ok <- at_least_two(numbers),
         {:ok, [text]} <- check_instructions([text]),
         {:ok, watcher} <- fetch(name, opts),
         :ok <- has_list(watcher) do
      case call({:merge_instructions, watcher.id, numbers, text, from, now(opts)}, opts) do
        {:ok, merged} -> {:ok, Map.put(merged, :echo, merge_echo(merged))}
        {:error, reason} -> refusal(reason, name)
      end
    end
  end

  @doc "Changes the watcher's one-line purpose."
  @spec set_purpose(String.t(), String.t(), opts()) :: result()
  def set_purpose(name, purpose, opts \\ []) when is_binary(name) do
    with {:ok, purpose} <- check_purpose(purpose),
         {:ok, watcher} <- fetch(name, opts),
         :ok <- has_list(watcher),
         {:ok, _written} <- write(watcher, %{purpose: purpose}, nil, opts) do
      {:ok, %{echo: "Watcher #{name}'s purpose is now: #{purpose}"}}
    end
  end

  @doc """
  Stores a cue this watcher received as a `pass` or `drop` example, with an
  optional note; the cue's snapshot is copied.
  """
  @spec add_example(String.t(), integer(), String.t(), String.t() | nil, opts()) :: result()
  def add_example(name, cue_id, label, note, opts \\ []) when is_binary(name) do
    with :ok <- example_args(cue_id, label),
         {:ok, note} <- check_note(note),
         {:ok, watcher} <- fetch(name, opts),
         :ok <- has_list(watcher) do
      case call({:add_example, watcher.id, cue_id, label, note, now(opts)}, opts) do
        {:ok, example} -> {:ok, %{example: example, echo: example_echo(name, example)}}
        {:error, reason} -> refusal(reason, name)
      end
    end
  end

  @doc """
  Stores one of a stream watcher's recent drops (`Cues.RecentDrops`, by its
  key from `list_cues`) as a `pass` or `drop` example: the item is kept first
  (`CuesSql` `{:store_item, …}`, the stored cue of its identity or a receipt),
  then the example copies its snapshot.
  """
  @spec add_drop_example(String.t(), pos_integer(), String.t(), String.t() | nil, opts()) ::
          result()
  def add_drop_example(name, key, label, note, opts \\ []) when is_binary(name) do
    with :ok <- drop_args(key, label),
         {:ok, note} <- check_note(note),
         {:ok, watcher} <- fetch(name, opts),
         :ok <- has_list(watcher),
         {:ok, drop} <- recent_drop(watcher.id, key),
         {:ok, cue_id} <- keep_item(drop, opts) do
      case call({:add_drop_example, watcher.id, cue_id, label, note, now(opts)}, opts) do
        {:ok, example} -> {:ok, %{example: example, echo: example_echo(name, example)}}
        {:error, reason} -> refusal(reason, name)
      end
    end
  end

  defp drop_args(key, label) do
    cond do
      not (is_integer(key) and key > 0) -> {:error, "Name the drop by its key from list_cues."}
      label not in ["pass", "drop"] -> {:error, ~s(An example is labelled "pass" or "drop".)}
      true -> :ok
    end
  end

  defp recent_drop(watcher_id, key) do
    case RecentDrops.fetch(watcher_id, key) do
      {:ok, drop} -> {:ok, drop}
      :error -> {:error, @drop_gone}
    end
  end

  defp keep_item(drop, opts) do
    request = {:store_item, drop.source_ref, drop.item, now(opts)}

    case Repo.cues_call(CuesSql, request, server: Keyword.get(opts, :repo, Repo)) do
      {:ok, cue_id} -> {:ok, cue_id}
      {:error, reason} -> refusal(reason, drop.source_ref)
    end
  end

  @doc "Removes one example by id."
  @spec remove_example(String.t(), String.t(), opts()) :: result()
  def remove_example(name, example_id, opts \\ []) when is_binary(name) do
    with :ok <- non_blank(example_id, "Name the example to remove."),
         {:ok, watcher} <- fetch(name, opts) do
      case call({:remove_example, watcher.id, example_id, now(opts)}, opts) do
        {:ok, example} ->
          {:ok,
           %{echo: "Removed the #{example.label} example #{example.id} (cue #{example.cue_id})."}}

        {:error, reason} ->
          refusal(reason, example_id)
      end
    end
  end

  defp example_args(cue_id, label) do
    cond do
      not (is_integer(cue_id) and cue_id > 0) ->
        {:error, "Name the cue by its id from list_cues."}

      label not in ["pass", "drop"] ->
        {:error, ~s(An example is labelled "pass" or "drop".)}

      true ->
        :ok
    end
  end

  defp check_note(nil), do: {:ok, nil}

  defp check_note(note) when is_binary(note) do
    note = String.trim(note)

    cond do
      note == "" -> {:ok, nil}
      String.length(note) > @note_max -> {:error, "An example's note is at most 300 characters."}
      true -> {:ok, note}
    end
  end

  defp check_note(_note), do: {:error, "An example's note is text."}

  defp has_list(%{filter: "none"}), do: {:error, @none_has_no_list}
  defp has_list(_watcher), do: :ok

  defp numbers(list) do
    if Enum.all?(list, &(is_integer(&1) and &1 > 0)),
      do: :ok,
      else: {:error, "Instructions are named by their numbers."}
  end

  defp at_least_two(numbers) do
    if length(Enum.uniq(numbers)) >= 2,
      do: :ok,
      else: {:error, "A merge replaces two or more instructions with one."}
  end

  defp non_empty([], sentence), do: {:error, sentence}
  defp non_empty(_list, _sentence), do: :ok

  defp non_blank(text, _sentence) when is_binary(text) and text != "", do: :ok
  defp non_blank(_text, sentence), do: {:error, sentence}

  # --- update -------------------------------------------------------------------------------

  @doc """
  Changes the watcher's sources, filter (to `llm` or `none`), words to listen
  for (`listen_for`, replacing the list), task, task notes, daily cap or filter
  budget, in one fenced write. Switching to `llm` needs a purpose; switching to
  `none` needs a daily cap and clears the purpose, keeping the instructions and
  words for a switch back; the items that waited for the filter pass in the
  same write and the scheduler is woken for them (opt `:wake_scheduler`,
  default `Cues.wake_scheduler/0`). Switching back to `llm` leaves passed items
  as they are. New sources expire what was waiting for the filter from a
  source the watcher no longer has, with no gap, and leave what it passed. The
  watcher the change leaves must keep the rules. Changes are atom-keyed.
  """
  @spec update(String.t(), map(), opts()) :: result()
  def update(name, changes, opts \\ []) when is_binary(name) and is_map(changes) do
    with {:ok, watcher} <- fetch(name, opts),
         {:ok, patch} <- update_patch(watcher, changes),
         {:ok, sources} <- update_sources(changes),
         :ok <- something_changed(patch, sources),
         :ok <- keeps_rules(changed(watcher, patch, sources), opts),
         {:ok, job} <- relinked_job(patch, opts),
         {:ok, %{watcher: updated, passed: passed, expired: expired}} <-
           write(watcher, patch, sources, opts) do
      Enum.each(expired, &emit_source_removed(updated.id, &1))
      Enum.each(passed, &emit_passed(updated.id, &1))
      wake_for_passed(passed, opts)

      echo =
        updated_echo(updated, patch, sources, job, opts) <>
          expired_line(length(expired)) <> passed_line(length(passed))

      {:ok, %{watcher: updated, echo: echo}}
    end
  end

  # An item that waited from a source taken off the watcher, traced as a
  # removal traces its expiries.
  defp emit_source_removed(watcher_id, expired) do
    Telemetry.lifecycle(:expired, %{}, %{
      source_ref: expired.source_ref,
      cue_id: expired.cue_id,
      delivery_id: expired.delivery_id,
      watcher_id: watcher_id,
      reason: "source_removed"
    })
  end

  # An item a switch to `none` passes has no filter call, as at acceptance
  # (`Cues.Ingest`): the same sessionless `passed` phase and reason.
  defp emit_passed(watcher_id, passed) do
    Telemetry.lifecycle(:passed, %{}, %{
      source_ref: passed.source_ref,
      cue_id: passed.cue_id,
      delivery_id: passed.delivery_id,
      watcher_id: watcher_id,
      reason: "no filter"
    })

    FollowUps.emit_triggered(passed.follow_up, passed.source_ref)
  end

  defp wake_for_passed([], _opts), do: :ok

  defp wake_for_passed(_passed, opts),
    do: Keyword.get(opts, :wake_scheduler, &Cues.wake_scheduler/0).()

  defp expired_line(0), do: ""

  defp expired_line(1),
    do: "\n1 item waiting from a source it no longer listens to was discarded."

  defp expired_line(n),
    do: "\n#{n} items waiting from sources it no longer listens to were discarded."

  defp passed_line(0), do: ""
  defp passed_line(1), do: "\n1 item that waited for the filter now goes to its task."
  defp passed_line(n), do: "\n#{n} items that waited for the filter now go to its task."

  defp update_patch(watcher, changes) do
    with {:ok, filter_patch} <- filter_patch(watcher, changes),
         {:ok, words} <- words_patch(changes),
         {:ok, counts} <- counts_patch(changes),
         {:ok, rest} <- simple_patch(changes) do
      {:ok, filter_patch |> Map.merge(words) |> Map.merge(counts) |> Map.merge(rest)}
    end
  end

  defp filter_patch(watcher, changes) do
    case Map.get(changes, :filter, watcher.filter) do
      "none" ->
        none_patch(watcher, changes, Enum.any?([:purpose, :listen_for], &present?(changes, &1)))

      "llm" ->
        llm_patch(watcher, changes)

      _other ->
        {:error, ~s(A watcher's filter is "llm" or "none".)}
    end
  end

  defp words_patch(changes) do
    case Map.fetch(changes, :listen_for) do
      :error ->
        {:ok, %{}}

      {:ok, words} ->
        with {:ok, words} <- ListenFor.validate(words), do: {:ok, %{listen_for: words}}
    end
  end

  # The watcher as the change would leave it, for the rules.
  defp changed(watcher, patch, sources),
    do: watcher |> Map.merge(patch) |> Map.put(:sources, sources || watcher.sources)

  defp none_patch(_watcher, _changes, true), do: {:error, @none_takes_nothing}
  defp none_patch(watcher, changes, false), do: to_none(watcher, changes)

  defp llm_patch(%{filter: "none"}, changes), do: to_llm(changes)

  defp llm_patch(_watcher, changes) do
    if present?(changes, :purpose),
      do: {:error, "Change the purpose with set_purpose."},
      else: {:ok, %{}}
  end

  defp to_none(%{filter: "none"}, _changes), do: {:ok, %{}}

  defp to_none(_watcher, changes) do
    with {:ok, cap} <- none_daily_cap(Map.get(changes, :daily_cap)) do
      {:ok, %{filter: "none", purpose: nil, daily_cap: cap}}
    end
  end

  defp to_llm(changes) do
    with {:ok, purpose} <- check_purpose(Map.get(changes, :purpose)) do
      {:ok, %{filter: "llm", purpose: purpose}}
    end
  end

  defp counts_patch(changes) do
    Enum.reduce_while([:daily_cap, :filter_budget], {:ok, %{}}, fn key, {:ok, acc} ->
      case Map.fetch(changes, key) do
        :error -> {:cont, {:ok, acc}}
        {:ok, value} -> count_patch(key, value, acc)
      end
    end)
  end

  defp count_patch(key, value, acc) do
    case count_setting(value, key) do
      {:ok, n} -> {:cont, {:ok, Map.put(acc, key, n)}}
      {:error, sentence} -> {:halt, {:error, sentence}}
    end
  end

  defp simple_patch(changes) do
    with {:ok, notes} <- notes_patch(changes) do
      case Map.get(changes, :task_job_id) do
        nil ->
          {:ok, notes}

        job_id when is_binary(job_id) and job_id != "" ->
          {:ok, Map.put(notes, :task_job_id, job_id)}

        _other ->
          {:error, "Name the job to link by its id."}
      end
    end
  end

  defp notes_patch(changes) do
    case Map.fetch(changes, :task_notes) do
      :error -> {:ok, %{}}
      {:ok, flag} when is_boolean(flag) -> {:ok, %{task_notes: flag}}
      {:ok, _other} -> {:error, "task_notes is on (true) or off (false)."}
    end
  end

  defp update_sources(changes) do
    case Map.fetch(changes, :sources) do
      :error -> {:ok, nil}
      {:ok, sources} -> check_sources(sources)
    end
  end

  defp something_changed(patch, nil) when map_size(patch) == 0,
    do: {:error, "Say what to change on the watcher."}

  defp something_changed(_patch, _sources), do: :ok

  defp relinked_job(%{task_job_id: job_id}, opts) do
    with {:ok, job, false} <- linked_task(job_id, opts), do: {:ok, job}
  end

  defp relinked_job(_patch, _opts), do: {:ok, nil}

  # Fenced on the `updated_at` read with the watcher, so a change computed from
  # an older state is refused rather than written over a newer one.
  defp write(watcher, patch, sources, opts) do
    request = {:update_watcher, watcher.id, watcher.updated_at, patch, sources, now(opts)}

    case call(request, opts) do
      {:ok, %{watcher: _updated, passed: _passed} = written} -> {:ok, written}
      {:error, reason} -> refusal(reason, watcher.name)
    end
  end

  # --- echoes (Fermix's words, design §8.4) --------------------------------------------------

  defp created_echo(watcher, jobs, chat, opts) do
    [
      set_up_line(watcher, jobs.task),
      purpose_line(watcher),
      words_line(watcher),
      instructions_lines(watcher.instructions),
      cap_line(watcher),
      missing_line(missing_sources(watcher.sources, opts)),
      jobs.task && lacking_line(jobs.task, watcher, opts),
      jobs.follow_up && follow_up_echo(watcher, jobs.follow_up, chat, false)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp set_up_line(watcher, nil) do
    "Watcher #{watcher.name} is set up: it listens to #{Enum.join(watcher.sources, ", ")} " <>
      "and #{filter_words(watcher)}."
  end

  defp set_up_line(watcher, job) do
    delivery = %{mode: job.delivery_mode, target: job.delivery_target}

    "Watcher #{watcher.name} is set up: it listens to #{Enum.join(watcher.sources, ", ")}, " <>
      "#{filter_words(watcher)}, and wakes job #{job.id} (#{job.name}), which reports to " <>
      "#{Card.reports_to(delivery, [])}."
  end

  defp updated_echo(watcher, patch, sources, job, opts) do
    [
      "Watcher #{watcher.name} changed: #{changed_words(patch, sources)}.",
      words_line(watcher),
      if(sources, do: missing_line(missing_sources(sources, opts))),
      if(job, do: lacking_line(job, watcher, opts))
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp changed_words(patch, sources) do
    patch
    |> Enum.sort()
    |> Enum.map(&change_words/1)
    |> Enum.reject(&is_nil/1)
    |> then(&if(sources, do: &1 ++ ["sources #{Enum.join(sources, ", ")}"], else: &1))
    |> Enum.join("; ")
  end

  defp change_words({:filter, "none"}), do: "it passes every item without a filter"
  defp change_words({:filter, "llm"}), do: "it filters with a model"
  defp change_words({:listen_for, _words}), do: "new keywords to listen for"
  defp change_words({:purpose, nil}), do: "purpose cleared"
  defp change_words({:purpose, purpose}), do: "purpose #{purpose}"
  defp change_words({:daily_cap, 0}), do: "no daily cap"
  defp change_words({:daily_cap, n}), do: "daily cap #{n} runs"
  defp change_words({:filter_budget, 0}), do: "no filter budget"
  defp change_words({:filter_budget, n}), do: "filter budget #{n} calls"
  defp change_words({:task_notes, true}), do: "task notes on"
  defp change_words({:task_notes, false}), do: "task notes off"
  defp change_words({:task_job_id, job_id}), do: "task job #{job_id}"

  defp filter_words(%{filter: "none"}), do: "passes every item without a filter"

  defp filter_words(_watcher),
    do: "filters with the Cues filter model (the main model unless settings name another)"

  defp purpose_line(%{purpose: nil}), do: nil
  defp purpose_line(%{purpose: purpose}), do: "Purpose: #{purpose}"

  @doc """
  The line listing a filtering watcher's words to listen for, or nil for one
  with none. Every echo and view of a watcher shows it, so the owner always
  sees what was stored.
  """
  @spec words_line(map()) :: String.t() | nil
  def words_line(%{filter: "llm", listen_for: [_word | _more] = words}),
    do: "Listens for: " <> Enum.join(words, ", ")

  def words_line(watcher) when is_map(watcher), do: nil

  defp instructions_lines([]), do: nil

  defp instructions_lines(rows),
    do: "Instructions:\n" <> Enum.map_join(rows, "\n", &"#{&1.number}. #{&1.text}")

  defp cap_line(%{filter: "none", daily_cap: 0}),
    do: "It wakes its task for every item, with no daily cap."

  defp cap_line(%{filter: "none", daily_cap: cap}),
    do: "It wakes its task for every item, at most #{cap} runs a day."

  defp cap_line(_watcher), do: nil

  defp missing_line([]), do: nil
  defp missing_line(lines), do: "Missing: " <> Enum.join(lines, " ")

  defp lacking_line(job, watcher, opts) do
    case job_skill(job, opts) do
      {:ok, skill} -> lacking_words(CueSurface.lacking(job, skill, watcher, nil))
      {:error, sentence} -> sentence
    end
  end

  defp lacking_words([]), do: nil

  defp lacking_words(tools) do
    "A cue run will not have #{Enum.join(tools, ", ")}: it reads and reports; a mandate in " <>
      "settings can grant a tool."
  end

  defp job_skill(%{skill_name: name}, opts) when is_binary(name) do
    registry = Keyword.get(opts, :skill_registry, SkillRegistry)

    case SkillRegistry.load(registry, name) do
      {:ok, definition} ->
        {:ok, definition}

      {:error, reason} ->
        {:error,
         "What a cue run will lack is not known: the task's skill #{name} cannot be read " <>
           "(#{inspect(reason)})."}
    end
  end

  defp job_skill(_job, _opts), do: {:ok, nil}

  defp list_echo(%{added: added, removed: removed}) do
    (Enum.map(added, &"Added #{line(&1)}") ++ Enum.map(removed, &"Removed #{line(&1)}"))
    |> Enum.join(" ")
  end

  defp merge_echo(%{added: [added], removed: removed}) do
    numbers = removed |> Enum.map(& &1.number) |> join_numbers()

    "Merged #{numbers} into #{line(added)} " <>
      Enum.map_join(removed, " ", &"Removed #{line(&1)}")
  end

  defp join_numbers([one]), do: "#{one}"
  defp join_numbers(list), do: Enum.join(Enum.drop(list, -1), ", ") <> " and #{List.last(list)}"

  defp line(%{number: number, text: text}), do: "#{number}: #{sentence(text)}"

  defp sentence(text) do
    if String.ends_with?(text, [".", "!", "?"]), do: text, else: text <> "."
  end

  defp example_echo(name, example) do
    "Stored cue #{example.cue_id} as a #{example.label} example for watcher #{name} " <>
      "(#{example.id}); the filter sees it from its next call."
  end

  defp removed_echo(watcher, removed) do
    count = length(removed.expired)

    waiting =
      if count == 0,
        do: "nothing was waiting",
        else: "#{count} waiting #{plural(count, "item", "items")} expired"

    [
      "Watcher #{watcher.name} is removed: #{waiting}.",
      task_kept(watcher),
      follow_up_gone(watcher)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp task_kept(%{task_job_id: nil}), do: nil

  defp task_kept(watcher),
    do:
      "Its task job #{watcher.task_job_id} stays and runs on no cues until another watcher " <>
        "links it."

  defp follow_up_gone(%{follow_up_job_id: nil}), do: nil
  defp follow_up_gone(watcher), do: "Its follow-up job #{watcher.follow_up_job_id} is removed."

  defp plural(1, one, _many), do: one
  defp plural(_n, _one, many), do: many

  # --- refusals ----------------------------------------------------------------------------

  defp refusal(:not_found, name), do: {:error, "There is no watcher named #{name}."}
  defp refusal(:name_taken, name), do: {:error, "There is already a watcher named #{name}."}
  defp refusal(:stale, _name), do: {:error, @stale}
  defp refusal(:instruction_cap, _name), do: {:error, @cap_reached}

  defp refusal(:busy, name),
    do:
      {:error,
       "Watcher #{name} is filtering an item or running its task right now; remove it when " <>
         "that finishes."}

  defp refusal(:follow_up_running, name),
    do: {:error, "Watcher #{name}'s follow-up is running right now; try again when it finishes."}

  defp refusal(:job_not_found, _name), do: {:error, "There is no such job."}

  defp refusal(:not_cue_job, _name),
    do: {:error, "That job runs on a schedule; a watcher's task must be a job that runs on cues."}

  defp refusal({:task_taken, other}, _name),
    do: {:error, "That job is already the task of watcher #{other}."}

  defp refusal({:follow_up_taken, other}, _name),
    do: {:error, "That job is already a job of watcher #{other}."}

  defp refusal(:not_follow_up_job, _name),
    do: {:error, "That job is not a watcher's follow-up."}

  defp refusal({:not_active, numbers}, _name),
    do: {:error, "Not an active instruction of this watcher: #{Enum.join(numbers, ", ")}."}

  defp refusal({:no_instruction, number}, _name),
    do: {:error, "This watcher has no instruction #{number}."}

  defp refusal({:already_active, number}, _name),
    do: {:error, "Instruction #{number} is already active."}

  defp refusal(:not_delivered, _name),
    do:
      {:error,
       "That cue was never delivered to this watcher; an example must be one it received."}

  defp refusal(:snapshot_gone, _name),
    do: {:error, "That cue's text is no longer kept, so it cannot be an example."}

  defp refusal(:example_not_found, id), do: {:error, "This watcher has no example #{id}."}

  defp refusal(reason, name) do
    Logger.warning("Cues.Watchers: a change to #{inspect(name)} failed: #{inspect(reason)}")
    {:error, "The watcher could not be changed: #{inspect(reason)}"}
  end

  # --- plumbing ----------------------------------------------------------------------------

  defp call(request, opts) do
    repo_opts =
      [server: Keyword.get(opts, :repo, Repo)] ++ Keyword.take(opts, [:timeout, :on_timeout])

    Repo.cues_call(CuesWatchersSql, request, repo_opts)
  end

  defp registry_opts(opts),
    do: [repo: Keyword.get(opts, :repo, Repo)] ++ Keyword.take(opts, [:scheduler])

  defp now(opts), do: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

  defp cues_config(opts),
    do:
      Keyword.get_lazy(opts, :cues_config, fn -> Application.get_env(:fermix_core, :cues, []) end)

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil
end
