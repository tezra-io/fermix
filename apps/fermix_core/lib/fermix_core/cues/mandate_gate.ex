defmodule FermixCore.Cues.MandateGate do
  @moduledoc """
  The first clause of `Capabilities.AccessGate.admit/3` (M60 §10.5): what a run
  a cue woke may call, and how a mandate call is checked, recorded and run.

  It applies only when `context.trigger == "cue"`. Every other run (the owner's
  chat, another job's run, a later scheduled run of the same job) gets
  `:not_mandated` and the gate's other clauses, so the same tools behave there
  exactly as before (B42, C46) and no row is written.

  In a cue run:

    * a call to a tool in the run's mandate `tools` is a **mandate call**;
    * a call to one of its `read_tools` runs unrecorded, without the mode,
      freshness, loop breaker, `pin_args` or validator, only while the
      capability is still marked read-only (else `refused_reader_writes`) and
      the mandate passes the steps a mandate call takes first: the run's
      load-check verdict and the switches (`Cues.Mandates.in_force/2`), with
      the approval before the run began (`mandate_disabled`), and the pin
      check (`mandate_unpinned`, which disables the mandate, or
      `mandate_refused`);
    * a call to a tool outside the run's tool set (`Jobs.CueSurface.allowed?/1`
      plus the mandate's `tools` and `read_tools`) is refused here, except an
      access-sensitive command, which `AccessGate.decide/2` refuses as a cue
      run's (`refused_cue_run`);
    * in a run of a mandated job, a file tool reads only inside the job's own
      skill folder, and nowhere when the job names none (design §10.4);
      `git_read` is refused there, since git reads the repository around the
      folder it starts in;
    * anything else goes on to the other clauses.

  A mandate call is written in three Repo calls (design §10.3): the
  `cue_mandate_calls` row first, before any check, with the arguments as the
  tool will send them (the tool's own `ParamSchema` normalisation, and the
  mandate's `idempotency_arg` set by Fermix to `fx-<mandate>-<key>`); then the
  checks in order: the switches (`enabled`, `[fermix_core.cues]
  mandates_enabled` and the approval, read at every call, which must predate
  the run's claim (`cue_run_claimed_at`), and the mandate's
  load checks, taken at the run's first mandate call and kept for the run),
  freshness (`max_cue_age`, from the earlier of the cue's time and its
  receipt), the loop breaker (10 calls allowed or proposed per task per
  rolling hour), the pin check (at every call, over the section as it reads
  then), `pin_args`, and the validator when one is set (only it can allow
  then). The decision is written before anything runs: an `allow` runs the
  executor, here, on the normalised map (so the executor does not normalise
  again and the result can be written as Repo call 3); a `propose` stores and
  sends a proposal (`Cues.Proposals`); a refusal ends the row with its reason.
  A section removed during the run refuses each call to its tools, recorded.
  An allowed call that never reported is finished `unknown` by
  `finish_unreported/3`, a `Cues.Sweeper` step, once its run has ended.

  A refused or proposed call is still one model tool call: the gate emits its
  one `[:fermix, :tool, :exec]` event, with an `access_gate` label
  (`mandate_proposed`, `mandate_refused`, `mandate_disabled`, `mandate_stale`,
  `mandate_unpinned`, `refused_cue_surface`, `refused_reader_writes`,
  `refused_mandate_files`), the typed
  `pre_execution` marker, `validator: program | none` and the call's id. An
  allowed call's own event comes from its executor, labelled
  `mandate_allowed` through the context.

  Test seams ride in `context.cue_mandate_opts` (the `Cues.Mandates`,
  `Cues.Pins`, `Cues.Validator` and `Cues.Proposals` seams, `:now`, `:config`).
  """

  require Logger

  alias FermixCore.Capabilities.AccessGate
  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.UntrustedContent
  alias FermixCore.Cues.Mandates
  alias FermixCore.Cues.Pins
  alias FermixCore.Cues.Proposals
  alias FermixCore.Cues.Validator
  alias FermixCore.Jobs.CueSurface
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesMandateSql
  alias FermixCore.Plugins.CanonicalJson
  alias FermixCore.Plugins.Http.Interpreter
  alias FermixCore.Sandbox.Config, as: SandboxConfig
  alias FermixCore.Tools.Telemetry, as: ToolTelemetry

  @hourly_limit 10
  @loop_window_s 3_600
  @file_tools ~w(file_read view_image glob_search content_search git_read)
  @max_summary_chars 2_000
  @key_chars 32
  @key_placeholder String.duplicate("0", @key_chars)

  @unpinned "the task changed since the mandate was granted"
  @unverified "Fermix could not verify the mandate's pins; try again"
  @gone "the mandate no longer exists"
  @approved_during_run "the mandate was approved after this run began; the task's next run uses that approval"
  @unreported "the run ended before it reported, so whether it ran is unknown"
  @loop_limit "This task reached its hourly action limit."
  @proposed "Proposed to the owner; it runs only if they confirm it."

  @type outcome :: {:dispatch, map()} | {:held, Tool.tool_result()} | :not_mandated

  @doc "Decides a call in a cue run; `:not_mandated` hands it to the gate's other clauses."
  @spec admit(Capability.t(), map(), map()) :: outcome()
  def admit(%Capability{} = capability, args, %{trigger: "cue"} = context) when is_map(args) do
    opts = gate_opts(context)

    case run_mandate(context, opts) do
      {:gone, name} -> under_gone_mandate(capability, args, context, name, opts)
      mandate -> under_mandate(capability, args, context, mandate, opts)
    end
  end

  def admit(%Capability{}, args, context) when is_map(args) and is_map(context), do: :not_mandated

  @doc "The most mandate calls a task may have allowed or proposed in a rolling hour."
  @spec hourly_limit() :: pos_integer()
  def hourly_limit, do: @hourly_limit

  @doc """
  The `Cues.Sweeper` step for an allowed call that never reported: a crash or
  a stop between its decision and its result leaves `finished_at` empty. Once
  its run has ended, the row is finished `unknown`, once, and never run again.
  The owner was told by the run's own report (`Jobs.CueRun.report/1` reads such
  a row as "whether it ran is unknown"), so this step sends nothing.
  """
  @spec finish_unreported(keyword(), DateTime.t(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def finish_unreported(repo_opts, %DateTime{} = now, limit)
      when is_list(repo_opts) and is_integer(limit) and limit > 0 do
    request = {:finish_unreported_allows, @unreported, now, limit}

    with {:ok, ids} <- Repo.cues_call(CuesMandateSql, request, repo_opts) do
      Enum.each(ids, &Logger.warning("Mandate call #{&1}: #{@unreported}; finished as unknown"))
      {:ok, length(ids)}
    end
  end

  # --- the run's tool set --------------------------------------------------------------

  defp under_mandate(capability, args, context, mandate, opts) do
    cond do
      mandate_tool?(capability, mandate) ->
        mandated_call(capability, args, context, mandate, opts)

      CueSurface.allowed?(capability) ->
        files_or_pass(capability, args, context, mandate, opts)

      read_tool?(capability, mandate) ->
        reader_call(capability, args, context, mandate, opts)

      Map.get(capability.metadata, :access_sensitive?) == true ->
        :not_mandated

      true ->
        refuse_outside(capability, args, context)
    end
  end

  # The run's mandate section was removed while the run went on. Its tools are
  # still offered, so a call outside the cue surface is one of them: it is
  # recorded and refused, and the run's report lists it (design §10.3). File
  # tools still read only the skill folder.
  defp under_gone_mandate(capability, args, context, name, opts) do
    if CueSurface.allowed?(capability),
      do: files_or_pass(capability, args, context, :gone, opts),
      else: gone_call(capability, args, context, name, opts)
  end

  # The mandate as its section reads now, so the switch and everything the pin
  # covers are read at every call; the load checks' verdict comes from the run's
  # first mandate call (`with_load_checks/3`). `{:gone, name}` when the section
  # was removed during the run.
  defp run_mandate(context, opts) do
    case Map.get(context, :cue_mandate) do
      name when is_binary(name) -> live_mandate(name, opts)
      nil -> nil
    end
  end

  defp live_mandate(name, opts) do
    case Mandates.unchecked(name, opts) do
      {:ok, mandate} -> mandate
      :error -> {:gone, name}
    end
  end

  # The load checks (the plugin catalog, the job's row, the validator's
  # ownership: a dozen stats and a Repo read) are taken at the run's first
  # mandate call and kept for the run in the calling process: the run's agent
  # loop, which makes every tool call of the run, one at a time. A failed
  # verdict (a busy Repo, a file mid-install) is not kept, so the next call
  # takes it again.
  defp with_load_checks(%Mandates{name: name} = live, context, opts) do
    key = {__MODULE__, :load_checks, Map.fetch!(context, :run_id), name}

    case Process.get(key) do
      %Mandates{} = checked -> keep_verdict(live, checked)
      nil -> take_load_checks(key, live, opts)
    end
  end

  defp take_load_checks(key, live, opts) do
    case Mandates.get(live.name, opts) do
      {:ok, %Mandates{status: :active} = checked} ->
        _previous = Process.put(key, checked)
        keep_verdict(live, checked)

      {:ok, checked} ->
        keep_verdict(live, checked)

      :error ->
        %{live | status: {:inactive, @gone}}
    end
  end

  defp keep_verdict(live, checked),
    do: %{live | status: checked.status, job_name: checked.job_name}

  defp mandate_tool?(_capability, nil), do: false
  defp mandate_tool?(%Capability{name: name}, %Mandates{tools: tools}), do: name in tools

  defp read_tool?(_capability, nil), do: false
  defp read_tool?(%Capability{name: name}, %Mandates{read_tools: tools}), do: name in tools

  # A reader runs with none of a mandate call's other checks (mode, freshness,
  # limit, pin_args, validator) and is not recorded. What gates it: the
  # capability the call reaches is still marked read-only (the load check read
  # the manifest once, and a plugin update or a stale registration can change
  # what runs); the run's load-check verdict; the mandate in force, approved
  # before the run began; and the pins, since `read_tools` and the task are
  # pinned and a run that only reads would never reach a mandate call's pin
  # check. All but the first are the mandate call's own steps, with their
  # labels, and a changed pin disables the mandate and tells the owner once.
  defp reader_call(capability, args, context, mandate, opts) do
    if Map.get(capability.metadata, :read_only?) == true,
      do:
        reader_in_force(capability, args, context, with_load_checks(mandate, context, opts), opts),
      else: reader_writes(capability, args, context, mandate)
  end

  defp reader_in_force(capability, args, context, mandate, opts) do
    with {:ok, approval} <- switches(mandate, opts),
         :ok <- approved_before_run(approval, context),
         :ok <- pinned(mandate, approval, opts, now(opts)) do
      :not_mandated
    else
      {:refuse, label, reason, validator} ->
        refuse_reader(capability, args, context, label, reason, validator)
    end
  end

  # It was offered as a reader, so the refusal says what changed, and the
  # owner's log names where to look.
  defp reader_writes(capability, args, context, mandate) do
    Logger.warning(
      "Mandate #{mandate.name}: read tool #{capability.name} of plugin " <>
        "#{inspect(Map.get(capability.metadata, :plugin))} is not marked read-only now; " <>
        "its call was refused"
    )

    reason =
      "it is one of the mandate's read tools, but it is not marked read-only now, so it " <>
        "could change something"

    refuse_reader(capability, args, context, "refused_reader_writes", reason, "none")
  end

  # A reader writes no row, so its event carries no `mandate_call_id`; every
  # reader refusal carries `validator` (always "none": no validator judges a
  # reader) and `mandate_reason`, Fermix's own sentence.
  defp refuse_reader(capability, args, context, label, reason, validator) do
    text =
      "#{capability.name} was not run: #{reason}. Report what you found with the tools you have."

    metadata = %{validator: validator, mandate_reason: reason}
    hold(capability, args, context, text, label, :deny, metadata)
  end

  defp files_or_pass(
         %Capability{kind: :builtin, name: name} = capability,
         args,
         context,
         mandate,
         opts
       )
       when name in @file_tools and not is_nil(mandate) do
    if Map.get(capability.metadata, :plugin_owned?) == true,
      do: :not_mandated,
      else: skill_files_only(capability, args, context, opts)
  end

  defp files_or_pass(_capability, _args, _context, _mandate, _opts), do: :not_mandated

  # git finds the repository above the folder it starts in, so the strict root
  # cannot hold `git_read` to the skill folder: in a mandated run it is refused.
  defp skill_files_only(%Capability{name: "git_read"} = capability, args, context, _opts) do
    refuse_files(
      capability,
      args,
      context,
      "git_read can read the repository around that folder, so it is not offered"
    )
  end

  defp skill_files_only(capability, args, context, opts) do
    with name when is_binary(name) <- Map.get(context, :skill_name),
         {:ok, dir} <- Pins.skill_dir(name, opts) do
      {:dispatch, Map.put(context, :sandbox_config, skill_folder_config(context, dir))}
    else
      nil ->
        refuse_files(capability, args, context, "this task names no skill")

      {:error, reason} ->
        refuse_files(
          capability,
          args,
          context,
          "its skill folder cannot be read (#{inspect(reason)})"
        )
    end
  end

  # Strict mode on the skill folder alone: the folder is the only root.
  defp skill_folder_config(context, dir) do
    base =
      case Map.get(context, :sandbox_config) do
        nil -> SandboxConfig.current()
        config -> SandboxConfig.normalize(config)
      end

    %{base | mode: :strict, workspace_root: dir, allowed_roots: []}
  end

  defp refuse_files(capability, args, context, why) do
    text =
      "#{capability.name} was not run: in a task with a mandate, file tools read only inside " <>
        "the task's own skill folder, and #{why}."

    hold(capability, args, context, text, "refused_mandate_files", :deny, %{})
  end

  defp refuse_outside(capability, args, context) do
    text =
      "#{capability.name} was not run: it is not one of this cue run's tools. Report what " <>
        "you found with the tools you have."

    hold(capability, args, context, text, "refused_cue_surface", :deny, %{})
  end

  # A call to a tool of a mandate whose section is gone: recorded, then refused.
  defp gone_call(capability, args, context, name, opts) do
    now = now(opts)
    gone = %{name: name, idempotency_arg: nil}
    prepared = prepare_args(capability, args, gone, context)

    case open_call(prepared, capability, context, gone, now, opts) do
      {:ok, call} ->
        refuse_call(call, context, "mandate_disabled", @gone, "none", opts, now)

      {:error, reason} ->
        not_recorded(capability, args, context, name, reason)
    end
  end

  defp not_recorded(capability, args, context, name, reason) do
    Logger.error("Mandate #{name}: #{capability.name} not recorded: #{inspect(reason)}")
    text = "#{capability.name} was not run: Fermix could not record the call."
    hold(capability, args, context, text, "mandate_refused", :deny, %{validator: "none"})
  end

  # --- a mandate call ------------------------------------------------------------------

  defp mandated_call(capability, args, context, mandate, opts) do
    now = now(opts)
    prepared = prepare_args(capability, args, mandate, context)

    case open_call(prepared, capability, context, mandate, now, opts) do
      {:ok, call} ->
        decide(call, context, with_load_checks(mandate, context, opts), opts, now)

      {:error, reason} ->
        not_recorded(capability, args, context, mandate.name, reason)
    end
  end

  # The arguments as the tool will send them, the idempotency key over the
  # call and the cue (PLAN §1: no run id), and the first problem that refuses
  # the call before any switch is read. The model never sees the
  # `idempotency_arg`, so a placeholder of the final value's shape holds it
  # while the tool's own schema checks the call (a manifest may require it);
  # the key leaves it out, and the real value replaces the placeholder.
  defp prepare_args(capability, args, mandate, context) do
    held = put_idempotency_arg(args, capability, mandate, @key_placeholder)

    {base, problem} =
      case normalise(capability, held) do
        {:ok, normalised} -> {normalised, nil}
        {:error, problem} -> {held, problem}
      end

    case idempotency_key(mandate, capability.name, base, context) do
      {:ok, key} ->
        final = put_idempotency_arg(base, capability, mandate, key)
        %{args: final, args_json: Jason.encode!(final), key: key, problem: problem}

      {:error, key_problem} ->
        %{
          args: base,
          args_json: Jason.encode!(base),
          key: "none",
          problem: problem || key_problem
        }
    end
  end

  defp normalise(%Capability{executor: {_mod, _fun, [_plugin, %{"request" => _} = tool]}}, args) do
    case Interpreter.normalize(tool, args) do
      {:ok, normalised} -> {:ok, normalised}
      {:error, {:missing_param, key}} -> {:error, "the argument #{key} is missing"}
      {:error, {:invalid_param, key, _detail}} -> {:error, "the argument #{key} is not valid"}
      {:error, reason} -> {:error, "the arguments are not valid (#{inspect(reason)})"}
    end
  end

  defp normalise(%Capability{name: name}, _args),
    do: {:error, "#{name} is not an http plugin tool, so a mandate cannot check it"}

  defp idempotency_key(mandate, tool, args, context) do
    cue = Map.get(context, :cue, %{})
    canonical = Map.drop(args, List.wrap(mandate.idempotency_arg))

    [
      mandate.name,
      tool,
      canonical,
      Map.get(cue, :source_ref),
      Map.get(cue, :item_id),
      Map.get(cue, :revision)
    ]
    |> CanonicalJson.digest()
    |> case do
      {:ok, digest} ->
        {:ok, binary_part(digest, 0, @key_chars)}

      {:error, _reason} ->
        {:error,
         "an argument holds a value Fermix cannot record exactly (pass large numbers as text)"}
    end
  end

  defp put_idempotency_arg(args, _capability, %{idempotency_arg: nil}, _key), do: args

  defp put_idempotency_arg(args, capability, %{idempotency_arg: arg} = mandate, key) do
    if takes_argument?(capability, arg),
      do: Map.put(args, arg, "fx-#{mandate.name}-#{key}"),
      else: args
  end

  defp takes_argument?(%Capability{executor: {_mod, _fun, [_plugin, %{} = tool]}}, arg),
    do: tool |> Mandates.properties() |> Map.has_key?(arg)

  defp takes_argument?(_capability, _arg), do: false

  # Repo call (1).
  defp open_call(prepared, capability, context, mandate, now, opts) do
    cue = Map.get(context, :cue, %{})
    id = FermixCore.Cues.id("cmc")

    attrs = %{
      id: id,
      run_id: Map.fetch!(context, :run_id),
      job_id: Map.fetch!(context, :job_id),
      mandate: mandate.name,
      tool: capability.name,
      args_json: prepared.args_json,
      idempotency_key: prepared.key,
      delivery_id: Map.get(cue, :delivery_id),
      cue_id: Map.get(cue, :cue_id),
      created_at: now,
      hour_ago: DateTime.add(now, -@loop_window_s, :second)
    }

    case repo_call({:open_call, attrs}, opts) do
      {:ok, opened} ->
        {:ok,
         %{
           id: id,
           capability: capability,
           prepared: prepared,
           opened: opened,
           mandate_name: mandate.name
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decide(call, context, mandate, opts, now) do
    case checks(call, context, mandate, opts, now) do
      {:refuse, label, reason, validator} ->
        refuse_call(call, context, label, reason, validator, opts, now)

      {:allow, validator} when mandate.mode == :auto ->
        run_allowed(call, context, validator, opts, now)

      {:allow, validator} ->
        propose(call, context, mandate, validator, opts, now)
    end
  end

  defp checks(call, context, mandate, opts, now) do
    with :ok <- problem(call.prepared),
         {:ok, approval} <- switches(mandate, opts),
         :ok <- approved_before_run(approval, context),
         :ok <- fresh(mandate, context, now),
         :ok <- loop_breaker(call.opened),
         :ok <- pinned(mandate, approval, opts, now),
         :ok <- pin_args(mandate, call) do
      validate(call, context, mandate, opts)
    end
  end

  defp problem(%{problem: nil}), do: :ok
  defp problem(%{problem: problem}), do: {:refuse, "mandate_refused", problem, "none"}

  defp switches(mandate, opts) do
    case Mandates.in_force(mandate, opts) do
      {:ok, approval} -> {:ok, approval}
      {:error, why} -> {:refuse, "mandate_disabled", not_in_force(why), "none"}
    end
  end

  # Fermix's words to the model for `Mandates.in_force/2`'s reasons.
  defp not_in_force(:switched_off), do: "the mandate is switched off (enabled = false)"
  defp not_in_force(:mandates_off), do: "unattended mandate calls are switched off in settings"
  defp not_in_force({:inactive, why}), do: "the mandate is inactive: #{why}"

  defp not_in_force(:unapproved),
    do: "the mandate is not approved yet; the owner approves it in settings"

  defp not_in_force({:disabled, why}),
    do: "the mandate is disabled until the owner approves it again (#{why})"

  defp not_in_force({:approval_unreadable, reason}),
    do: "the mandate's approval could not be read (#{inspect(reason)})"

  # The run follows its task as the claim read it (`Repo.claim_cue_run/4`
  # reads the job in the claim's transaction), so an approval given after the
  # claim covers the task's next run, not this one: it may be of a task this
  # run is not following.
  defp approved_before_run(%{approved_at: %DateTime{} = approved_at}, context) do
    if DateTime.compare(approved_at, Map.fetch!(context, :cue_run_claimed_at)) == :gt,
      do: {:refuse, "mandate_disabled", @approved_during_run, "none"},
      else: :ok
  end

  defp fresh(%Mandates{max_cue_age_s: 0}, _context, _now), do: :ok

  defp fresh(mandate, context, now) do
    cue = Map.get(context, :cue, %{})

    case aged_from(Map.get(cue, :occurred_at), Map.get(cue, :received_at)) do
      %DateTime{} = from ->
        if DateTime.diff(now, from, :second) > mandate.max_cue_age_s,
          do: stale(mandate),
          else: :ok

      nil ->
        {:refuse, "mandate_stale", "the cue's time is unknown", "none"}
    end
  end

  # The earlier of the item's own time and its receipt, so an item that claims
  # a future time is aged from when Fermix received it (C44).
  defp aged_from(_occurred, nil), do: nil
  defp aged_from(nil, %DateTime{} = received), do: received

  defp aged_from(%DateTime{} = occurred, %DateTime{} = received),
    do: if(DateTime.compare(occurred, received) == :lt, do: occurred, else: received)

  defp stale(mandate) do
    {:refuse, "mandate_stale",
     "the cue is older than #{duration_text(mandate.max_cue_age_s)}, the mandate's max_cue_age",
     "none"}
  end

  defp loop_breaker(%{hourly_actions: count}) when count >= @hourly_limit,
    do: {:refuse, "mandate_refused", @loop_limit, "none"}

  defp loop_breaker(_opened), do: :ok

  # Only a real change (or a pinned file that cannot be read, which is one)
  # disables the mandate. A job row the Repo could not read says nothing about
  # the pins: that one call is refused, with no disable and no notice.
  defp pinned(mandate, approval, opts, now) do
    case Pins.check(mandate, approval, opts) do
      :ok ->
        :ok

      {:error, {:unverified, sentence}} ->
        Logger.warning("Mandate #{mandate.name} pins not verified: #{sentence}")
        {:refuse, "mandate_refused", @unverified, "none"}

      {:error, why} ->
        Logger.warning("Mandate #{mandate.name} pin check failed: #{inspect(why)}")
        disabled = Pins.disable(mandate.name, @unpinned, now, opts)
        Logger.info("Mandate #{mandate.name} disable: #{inspect(disabled)}")
        {:refuse, "mandate_unpinned", @unpinned, "none"}
    end
  end

  defp pin_args(mandate, call) do
    case Mandates.outside_grant(mandate, call.capability.name, call.prepared.args) do
      nil -> :ok
      reason -> {:refuse, "mandate_refused", reason, "none"}
    end
  end

  defp validate(_call, _context, %Mandates{validator: nil}, _opts), do: {:allow, "none"}

  defp validate(call, context, mandate, opts) do
    case Validator.run(mandate, validator_request(call, context, mandate), opts) do
      :allow -> {:allow, "program"}
      {:refuse, reason} -> {:refuse, "mandate_refused", reason, "program"}
    end
  end

  defp validator_request(call, context, mandate) do
    cue = Map.get(context, :cue, %{})

    %{
      "mandate" => mandate.name,
      "tool" => call.capability.name,
      "args" => call.prepared.args,
      "job" => Map.fetch!(context, :job_id),
      "run_id" => Map.fetch!(context, :run_id),
      "idempotency_key" => call.prepared.key,
      "calls_this_run" => call.opened.calls_this_run,
      "cue" => %{
        "source" => Map.get(cue, :source_ref),
        "item_id" => Map.get(cue, :item_id),
        "subject" => Map.get(cue, :subject),
        "occurred_at" => iso(Map.get(cue, :occurred_at)),
        "received_at" => iso(Map.get(cue, :received_at))
      }
    }
  end

  # --- the decision's effect -------------------------------------------------------------

  defp refuse_call(call, context, label, reason, validator, opts, now) do
    case repo_call({:decide_refuse, call.id, reason, validator, now}, opts) do
      {:ok, :ok} ->
        :ok

      {:error, error} ->
        Logger.error("Mandate call #{call.id} refusal not recorded: #{inspect(error)}")
    end

    text = refused_text(call.capability.name, validator, call.mandate_name, reason)

    hold(call.capability, call.prepared.args, context, text, label, :deny, %{
      validator: validator,
      mandate_call_id: call.id,
      mandate_reason: metadata_reason(validator, reason)
    })
  end

  # Repo call (2), then the executor on the normalised map, then Repo call (3).
  # The call never runs unless its decision (and the run's marker) is written.
  defp run_allowed(call, context, validator, opts, now) do
    case repo_call({:decide_allow, call.id, Map.fetch!(context, :run_id), validator, now}, opts) do
      {:ok, :ok} ->
        execute(call, context, validator, opts)

      {:error, reason} ->
        Logger.error("Mandate call #{call.id} decision not recorded: #{inspect(reason)}")
        text = "#{call.capability.name} was not run: Fermix could not record the call."

        hold(call.capability, call.prepared.args, context, text, "mandate_refused", :deny, %{
          validator: validator,
          mandate_call_id: call.id
        })
    end
  end

  defp execute(
         %{capability: %Capability{executor: {mod, fun, extra}}} = call,
         context,
         validator,
         opts
       ) do
    labelled =
      Map.merge(context, %{
        access_gate: "mandate_allowed",
        validator: validator,
        mandate_call_id: call.id,
        mandate_args_normalized?: true
      })

    result = apply(mod, fun, [call.prepared.args, labelled | extra])
    {status, summary} = result_of(result)

    case repo_call({:finish_call, call.id, status, summary, now(opts)}, opts) do
      {:ok, :ok} ->
        :ok

      {:error, reason} ->
        Logger.error("Mandate call #{call.id} result not recorded: #{inspect(reason)}")
    end

    {:held, tool_result(result)}
  end

  defp result_of({:ok, %{success: true} = result}),
    do: {"ok", bounded(to_string(Map.get(result, :output) || ""))}

  defp result_of({:ok, %{} = result}),
    do: {"error", bounded(to_string(Map.get(result, :error) || "failed"))}

  defp result_of(other), do: {"error", bounded(inspect(other))}

  defp tool_result({:ok, %{} = result}), do: result
  defp tool_result(other), do: Tool.error("the call failed: #{bounded(inspect(other))}")

  defp propose(call, context, mandate, validator, opts, now) do
    proposal_call = %{
      mandate: mandate,
      tool: call.capability.name,
      args: call.prepared.args,
      args_json: call.prepared.args_json,
      idempotency_key: call.prepared.key,
      validator: validator,
      run_id: Map.fetch!(context, :run_id),
      job_id: Map.fetch!(context, :job_id),
      session_id: Map.fetch!(context, :session_id),
      cue: Map.get(context, :cue, %{}),
      snapshot: call.opened.snapshot
    }

    case Proposals.prepare(proposal_call, now, opts) do
      {:ok, prepared} ->
        store_proposal(call, context, prepared, validator, opts, now)

      {:refuse, reason} ->
        refuse_call(call, context, "mandate_refused", reason, validator, opts, now)
    end
  end

  defp store_proposal(call, context, prepared, validator, opts, now) do
    meta = %{validator: validator, mandate_call_id: call.id}

    case Proposals.store_and_send(call.id, prepared, now, opts) do
      {:proposed, _id} ->
        proposal_hold(call, context, @proposed, meta)

      {:existing, existing} ->
        proposal_hold(call, context, existing_text(call.capability.name, existing.state), meta)

      {:unreachable, _id} ->
        text =
          "#{call.capability.name} was not proposed: Fermix could not reach the owner, so " <>
            "nothing ran. Fermix lists it in its report."

        proposal_hold(call, context, text, Map.put(meta, :mandate_reason, "owner unreachable"))

      {:error, reason} ->
        Logger.error("Mandate call #{call.id} proposal not stored: #{inspect(reason)}")
        text = "#{call.capability.name} was not proposed: Fermix could not record the proposal."
        hold(call.capability, call.prepared.args, context, text, "mandate_refused", :deny, meta)
    end
  end

  defp proposal_hold(call, context, text, meta),
    do:
      hold(call.capability, call.prepared.args, context, text, "mandate_proposed", :confirm, meta)

  defp existing_text(tool, "waiting"),
    do:
      "#{tool}: this exact call is already proposed to the owner and waits for their answer. " <>
        "Do not call it again."

  defp existing_text(tool, state),
    do:
      "#{tool}: this exact call was already proposed to the owner and is #{state}. Do not " <>
        "call it again."

  # --- the one exec event of a call the executor never ran -------------------------------

  defp hold(capability, args, context, text, label, decision, extra) do
    metadata =
      extra
      |> Map.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.merge(%{
        access_gate: label,
        policy_enforcement: AccessGate.pre_execution_marker(decision)
      })

    ToolTelemetry.exec(capability.name, context, false, 0, metadata: metadata, input: args)
    {:held, Tool.error(text)}
  end

  # Telemetry carries Fermix's own reasons only; a validator's words (which
  # may echo arguments written from outside text) stay in the row and the
  # model's result.
  defp metadata_reason("program", _reason), do: "validator refused"
  defp metadata_reason(_validator, reason), do: reason

  # The same words reach the model framed, labelled with the mandate (S12).
  defp refused_text(tool, "program", mandate_name, reason) do
    "#{tool} was not run: the validator refused it.\n" <>
      UntrustedContent.frame("validator:" <> mandate_name, reason) <>
      "\nFermix lists this refusal in its report to the owner."
  end

  defp refused_text(tool, _validator, _mandate_name, reason),
    do: "#{tool} was not run: #{reason}. Fermix lists this refusal in its report to the owner."

  # --- helpers -------------------------------------------------------------------------

  defp gate_opts(context) do
    context
    |> Map.get(:cue_mandate_opts, [])
    |> Keyword.put_new(:repo, Map.get(context, :memory_repo) || Repo)
  end

  defp now(opts), do: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

  defp repo_call(request, opts),
    do: Repo.cues_call(CuesMandateSql, request, server: Keyword.fetch!(opts, :repo))

  defp iso(nil), do: nil
  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)

  defp bounded(text) do
    if String.length(text) > @max_summary_chars,
      do: String.slice(text, 0, @max_summary_chars) <> "…",
      else: text
  end

  defp duration_text(seconds) when rem(seconds, 3_600) == 0,
    do: plural(div(seconds, 3_600), "hour")

  defp duration_text(seconds) when rem(seconds, 60) == 0, do: plural(div(seconds, 60), "minute")
  defp duration_text(seconds), do: plural(seconds, "second")

  defp plural(1, unit), do: "1 #{unit}"
  defp plural(n, unit), do: "#{n} #{unit}s"
end
