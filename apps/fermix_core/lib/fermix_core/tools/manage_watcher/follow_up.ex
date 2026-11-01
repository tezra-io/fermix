defmodule FermixCore.Tools.ManageWatcher.FollowUp do
  @moduledoc """
  `manage_watcher`'s side of a watcher's follow-up (M60_WATCHER_CODING_RUNS.md
  §3, §5): the `follow_up` argument read into `Cues.Watchers`' follow-up map,
  what the summary adds to `Cues.Watchers`' echo, and the owner's run by hand.

  - **Tools** are bounded by the calling turn exactly as `schedule_job` bounds a
    job's (`JobRegistrySupport.within_run_tools/2`,
    `AccessGate.check_job_tools/2`), and each must be one the turn sees, so
    every tool written passed the access gate in the owner's turn. A tool this
    computer does not offer (a program not found, a plugin not installed) is
    never written: the follow-up is left out with the readiness check's
    sentence (`Cues.FollowUpReadiness.unoffered/2`) and the owner asks again
    once it is installed; the watcher is still made when it has a task. A
    tool it offers that is not ready yet is written, held.
  - **Folders** its instructions name: one no grant opens (a protected path)
    or more than Fermix checks refuses the change with the sandbox's sentence
    (`Cues.FollowUpReadiness.unopenable/2`); one outside the sandbox's roots
    is written, held, its sentence naming the grant.
  - **The coding agent**: `coding_agent` in place of a tool, when the owner
    names no coding agent, is the configured default, else the one that is
    ready, else Fermix asks which (`Cues.FollowUpReadiness.coding_agent/1`).
  - **The summary** adds the readiness check's sentence while the follow-up is
    held (`Cues.FollowUps.held/2`) and a plugin skill's lower trust.
  - **Always allow** is granted only by the owner's answer on one of its cards
    (`Cues.FollowUps`), never here; `always_allow: false` takes it back
    (`Cues.Watchers.ask_first/3`).

  The caller has checked consent (the owner's consent turn) before any of this.
  """

  alias FermixCore.Agents.SkillRegistry
  alias FermixCore.Capabilities.AccessGate
  alias FermixCore.Cues.Card
  alias FermixCore.Cues.FollowUpReadiness
  alias FermixCore.Cues.FollowUps
  alias FermixCore.Cues.Watchers
  alias FermixCore.Jobs.Scheduler
  alias FermixCore.Tools.JobRegistrySupport

  @coding_agent "coding_agent"
  @not_an_object "follow_up is an object: its instructions and its tools."

  # The argument's keys and the `Cues.Watchers` follow-up keys they become.
  @plain_keys %{
    "name" => :name,
    "instructions" => :prompt,
    "always_allow" => :always_allow,
    "timeout_minutes" => :timeout_minutes,
    "delivery_target" => :delivery_target,
    "delivery_mode" => :delivery_mode
  }

  @doc "The `follow_up` argument's schema."
  @spec schema() :: map()
  def schema do
    %{
      type: "object",
      description:
        "A follow-up (create, or update to add or change one): a job in the owner's own " <>
          "words that each passing item sets off, run as a scheduled job with fixed " <>
          "instructions and the tools named, so it can do anything a scheduled job can. " <>
          "Fermix hands it nothing from the item: the item only decides when it runs, so " <>
          "work on the item's content is the watcher's task (it reads the item and reports) " <>
          "or a mandate's (a plugin action from the item, set up in settings).",
      properties: %{
        name: %{type: "string", description: "A short name from the owner's words."},
        instructions: %{
          type: "string",
          description:
            "What it does, in the owner's words, with every value it needs (a folder, a " <>
              "branch, a channel): its run sees nothing else."
        },
        tools: %{
          type: "array",
          items: %{type: "string"},
          description:
            "The tools it may use, from this turn's (#{@coding_agent} when the owner asks " <>
              "for a coding agent without naming Codex or Claude Code). A tool this computer " <>
              "does not have leaves the follow-up out, and Fermix says what to install."
        },
        skill: %{type: "string", description: "A skill to run it in."},
        provider: %{type: "string", description: "With model: the route its runs use."},
        model: %{type: "string", description: "With provider: the model its runs use."},
        always_allow: %{
          type: "boolean",
          enum: [false],
          description:
            "update only: false takes back the owner's Always allow, so each run asks first " <>
              "again. Only the owner's tap on one of its cards grants it."
        },
        timeout_minutes: %{type: "integer", description: "Its run limit, 1 to 30."},
        delivery_target: %{
          type: "object",
          description:
            ~s(Where it reports: "platform" plus "chat_id" or "channel_id". ) <>
              "Without it, it reports to this chat."
        },
        delivery_mode: %{type: "string", enum: ["origin", "channel"]}
      }
    }
  end

  # --- the argument -----------------------------------------------------------------

  @doc """
  `Cues.Watchers`' follow-up map from the `follow_up` argument, with only the
  keys given (an update changes those alone): the instructions as `prompt`, the
  tools resolved and bounded by `context`, a known skill, a paired route.
  `{:unoffered, sentence}` when a tool it names is not on this computer at
  all: the follow-up is not written, and `sentence` says what is missing.
  """
  @spec params(term(), map(), keyword()) ::
          {:ok, map() | nil} | {:unoffered, String.t()} | {:error, String.t()}
  def params(nil, _context, _opts), do: {:ok, nil}

  def params(args, context, opts) when is_map(args) and is_map(context) and is_list(opts) do
    with {:ok, tools} <- tools(args, context, opts),
         :ok <- openable(args, opts),
         {:ok, skill} <- skill(args, context),
         {:ok, route} <- route(args) do
      plain =
        for {key, field} <- @plain_keys,
            Map.has_key?(args, key),
            into: %{},
            do: {field, Map.fetch!(args, key)}

      {:ok, plain |> Map.merge(tools) |> Map.merge(skill) |> Map.merge(route)}
    end
  end

  def params(_args, _context, _opts), do: {:error, @not_an_object}

  defp tools(%{"tools" => tools}, context, opts) when is_list(tools) do
    with {:ok, resolved} <- resolve_coding_agent(tools, opts),
         :ok <- offered(resolved, opts),
         {:ok, bounded} <- bound(resolved, context),
         do: {:ok, %{allowed_tools: bounded}}
  end

  defp tools(%{"tools" => _other}, _context, _opts),
    do: {:error, "Name the follow-up's tools as a list."}

  defp tools(_args, _context, _opts), do: {:ok, %{}}

  defp resolve_coding_agent(tools, opts) do
    if @coding_agent in tools do
      with {:ok, tool} <- FollowUpReadiness.coding_agent(opts),
           do:
             {:ok, tools |> Enum.map(&if(&1 == @coding_agent, do: tool, else: &1)) |> Enum.uniq()}
    else
      {:ok, tools}
    end
  end

  # A tool no capability carries was never checked against this turn, and one
  # loaded later would run unchecked, so it is never written (§3.2).
  defp offered(tools, opts) do
    case FollowUpReadiness.unoffered(tools, opts) do
      nil -> :ok
      sentence -> {:unoffered, sentence}
    end
  end

  # A path no grant opens (one the sandbox protects) or more paths than Fermix
  # checks would hold the follow-up for good, so it is not written (§3.2). A
  # folder a grant would open is written, held.
  defp openable(%{"instructions" => instructions}, opts) when is_binary(instructions) do
    case FollowUpReadiness.unopenable(instructions, opts) do
      nil -> :ok
      sentence -> {:error, sentence}
    end
  end

  defp openable(_args, _opts), do: :ok

  # `schedule_job`'s bounds (audit F-08 and the run's own tools), on tools this
  # computer offers. An empty list is left for `Cues.Watchers`, which asks for
  # the tools.
  defp bound([], _context), do: {:ok, []}

  defp bound(tools, context) do
    with :ok <- visible(tools, context),
         {:ok, bounded} <- JobRegistrySupport.within_run_tools(tools, context),
         :ok <- AccessGate.check_job_tools(bounded, context),
         do: {:ok, bounded}
  end

  defp visible(tools, context) do
    seen = JobRegistrySupport.tool_names(context, trust: Map.get(context, :source_trust))

    case Enum.reject(tools, &(&1 in seen)) do
      [] -> :ok
      hidden -> {:error, "tools not available to the caller: #{Enum.join(hidden, ", ")}"}
    end
  end

  @doc """
  The summary's line for a follow-up left out of a create because a tool it
  names is not on this computer (`params/3`'s `{:unoffered, sentence}`).
  """
  @spec not_set_up(String.t()) :: String.t()
  def not_set_up(sentence) when is_binary(sentence),
    do: "No follow-up was set up: #{sentence} Ask for it again once that is done."

  @doc "The same, for a change to a follow-up that was left out."
  @spec not_changed(String.t()) :: String.t()
  def not_changed(sentence) when is_binary(sentence),
    do: "The follow-up did not change: #{sentence} Ask for it again once that is done."

  defp skill(%{"skill" => name}, context) when is_binary(name) and name != "" do
    case SkillRegistry.load(Map.get(context, :skill_registry, SkillRegistry), name) do
      {:ok, _definition} -> {:ok, %{skill_name: name}}
      {:error, {:unknown_skill, _name}} -> {:error, "There is no skill named #{name}."}
    end
  catch
    :exit, reason -> {:error, "The skills could not be read: #{inspect(reason)}"}
  end

  defp skill(_args, _context), do: {:ok, %{}}

  defp route(args) do
    if Map.has_key?(args, "provider") or Map.has_key?(args, "model") do
      case JobRegistrySupport.validate_route_pin(args) do
        {:ok, {provider, model}} -> {:ok, %{provider: provider, model: model}}
        {:error, sentence} -> {:error, sentence}
      end
    else
      {:ok, %{}}
    end
  end

  # --- the summary ------------------------------------------------------------------

  @doc """
  The summary of a change to a watcher: `result`'s echo, then, for a
  follow-up set or changed (`result.follow_up_job`), the readiness check's
  sentence while it is held and a plugin skill's lower trust.
  """
  @spec summarize({:ok, map()} | {:error, String.t()}, map(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def summarize({:error, sentence}, _context, _opts), do: {:error, sentence}

  def summarize({:ok, %{echo: echo} = result}, context, opts) do
    job = Map.get(result, :follow_up_job)
    lines = [echo] ++ held_lines(job, opts) ++ skill_lines(job, context)
    {:ok, Enum.join(lines, "\n")}
  end

  defp held_lines(nil, _opts), do: []

  defp held_lines(job, opts) do
    case FollowUps.held(job, opts) do
      nil ->
        []

      {_label, sentence} ->
        [
          "Held until it is ready: #{sentence} The watcher is set up, and the follow-up " <>
            "starts working once that is fixed, with no new request."
        ]
    end
  end

  # A plugin skill loads at guest trust whoever runs it, so a follow-up bound to
  # one is refused what needs the owner's trust, as the same scheduled job is.
  defp skill_lines(%{skill_name: name}, context) when is_binary(name) do
    case SkillRegistry.load(Map.get(context, :skill_registry, SkillRegistry), name) do
      {:ok, %{trust: :operator}} ->
        []

      {:ok, _guest} ->
        [
          "It runs inside the #{name} skill, which runs at guest trust, so a tool that needs " <>
            "your trust is refused in its runs."
        ]

      {:error, {:unknown_skill, _name}} ->
        ["The #{name} skill is gone, so its runs fail until it is back or another is named."]
    end
  catch
    :exit, reason -> ["The skills could not be read: #{inspect(reason)}"]
  end

  defp skill_lines(_job, _context), do: []

  # --- run by hand ------------------------------------------------------------------

  @doc """
  The owner's run of watcher `name`'s follow-up by hand (§3.5): the same run
  `run_job_now` starts for any job, after its access check, refused with the
  readiness sentence when a tool it names is not set up.
  """
  @spec run_now(String.t(), map(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def run_now(name, context, opts) when is_binary(name) and is_map(context) and is_list(opts) do
    with {:ok, watcher} <- Watchers.show(name, opts),
         {:ok, job_id} <- follow_up_job_id(watcher),
         {:ok, job} <- access(job_id, context),
         :ok <- ready(job, opts),
         {:ok, run} <- start(job_id, context) do
      delivery = %{mode: job.delivery_mode, target: job.delivery_target}

      {:ok,
       %{
         echo:
           ~s|Watcher #{name}'s follow-up "#{job.name}" is running now (run #{run.id}); it | <>
             "reports to #{Card.reports_to(delivery, chat: chat(context))}."
       }}
    end
  end

  defp follow_up_job_id(%{follow_up_job_id: nil, name: name}),
    do: {:error, "Watcher #{name} has no follow-up."}

  defp follow_up_job_id(%{follow_up_job_id: job_id}), do: {:ok, job_id}

  defp access(job_id, context) do
    case JobRegistrySupport.check_job_access(job_id, context) do
      {:ok, job} ->
        {:ok, job}

      {:error, sentence} when is_binary(sentence) ->
        {:error, sentence}

      {:error, reason} ->
        {:error, "Fermix could not read the follow-up's job: #{inspect(reason)}"}
    end
  end

  defp ready(job, opts) do
    case FollowUps.readiness(job, opts) do
      :ready -> :ok
      {:not_ready, sentence} -> {:error, "Not started: " <> sentence}
    end
  end

  defp start(job_id, context) do
    case Scheduler.run_now(Map.get(context, :scheduler) || Scheduler, job_id) do
      {:ok, run} -> {:ok, run}
      {:error, :already_running} -> {:error, "Not started: it is already running."}
      {:error, reason} -> {:error, "Not started: #{inspect(reason)}"}
    end
  catch
    :exit, reason -> {:error, "Not started: the scheduler is unavailable (#{inspect(reason)})."}
  end

  defp chat(%{conversation_key: {channel, chat_id, _thread}}),
    do: %{platform: to_string(channel), chat_id: to_string(chat_id)}

  defp chat(_context), do: nil
end
