defmodule FermixCore.Capabilities.AccessGate do
  @moduledoc """
  The one decision about whether a command that needs the owner's consent may
  run now.

  Two kinds of capability are decided here. A plugin manifest marks a changing
  tool `"access_sensitive": true` (a car unlock); the flag reaches the capability
  as `metadata.access_sensitive?` on both plugin rails, and every call of it is
  decided.

  A built-in that starts a host process the model steers
  (`metadata.host_command?`: `shell`, `git_write`, a command the owner
  declared, and the local coding runs `codex_run` and `claude_code_run`) is
  decided only when the turn read outside content and Fermix cannot sandbox the
  call. The taint is rule 5's `:outside_sources` half alone: a shared Buzz
  channel does not hold one by itself, since a Buzz session answers through
  `shell`. Fermix cannot sandbox the call when the host's kernel does not hold
  commands (`Sandbox.OsSandbox.enforced?/1` false: a system other than macOS
  and Linux, or a Linux host without Landlock ABI 2, where every confined
  command refuses anyway; read through the context's `:os_sandbox` seam), or
  when the command runs unconfined even where it does
  (`metadata.host_command_confined?` false: the `codex` and `claude_code`
  presets, and the coding runs, whose vendor CLI acts with the owner's account
  authority outside the sandbox), so those are decided on every platform.
  Without the kernel, nothing but the starting folder and the hardline patterns
  stands between a hostile page's instruction and the owner's files. A
  confined call on a host where `enforced?/1` holds is not decided here, as
  `shell` is not on macOS (Seatbelt) or on Linux with Landlock.

  `Capability.execute/3` — the single invoke boundary for the agent loop and the
  realtime voice bridge — asks `admit/3` first, and every other capability
  returns on its metadata.

  For a call decided here, in order:

    1. a delegated worker (`Temporal.Access.worker?/1`: `subagent_depth` or
       `skill_depth` above zero) is refused: no owner is in that loop;
    2. a run a cue woke (`trigger: "cue"`) is refused: it read content an
       outsider wrote, and no owner is in that loop (M60 S3);
    3. an operator scheduled run dispatches only when its job row names the tool
       (`Harness.Authorization`'s job-row allowlist, the owner's consent given
       when they set the job up);
    4. the next run of a coding-run chain dispatches, labelled `chained` (owner
       decision, "same folder only"): a finished run's follow-up turn starting
       the same coding agent in that run's own starting folder (both read from
       its ledger row), once per finished run, while the run's report is all
       the turn has read, with nothing but its task, folder, model, effort and limits
       (`chained_run?/3`). The chain stays bounded by `Harness.Continuation`'s
       depth cap;
    5. anything that is not an attended owner turn
       (`Temporal.Access.attended_operator_turn?/1`) is refused;
    6. a turn that read content someone else could have written
       (`:outside_sources`, folded by the agent loop from
       `UntrustedContent.outside_source/3`, minus the target plugin's own reads),
       or any turn from a shared Buzz channel (`Acp.Identity.multi_principal?/1`:
       other people can post there, so the request is not proof the owner asked),
       parks the exact call and asks the owner once, on the surface the turn has
       (for ACP, the owner's own chat, never the channel itself);
    7. otherwise the owner's direct request is the consent, and it runs (a
       host command reaches these rules only after outside content, so it
       parks at 6, and its prompt names what was read, never the channel).

  A third kind only refuses (M84): a `browser` call of `act` kind `sign_in`
  (`gate_kind/2`). It runs only on the owner's own attended turn, never from a
  delegated worker, a cue or scheduled run (a job row naming `browser` does not
  admit it), or a shared Buzz channel (`sign_in_not_allowed`), and never on a
  voice turn (`sign_in_not_on_voice`): the model that read the page would
  phrase the question, and a page can play a spoken yes. An admitted sign-in is
  never parked. Its own call asks the owner with `ask_in_call/3` and waits for
  the answer in the turn's process, since the pane task, its refs and its tab
  end with the turn. Every confirm and deny path answers such a record by
  message (`confirm_in_call/2`, `deny/2`) instead of running a recorded call.

  Two related questions live here too: `owner_consent_turn?/1`, whether a turn
  may change what a watcher reads or what a task may do (with
  `owner_private_turn?/1`, the same less its taint condition), and
  `check_attended/2`, the execution check of a tool offered only on an
  attended owner turn.

  A parked call is confirmed only by the owner — `/confirm` (a tap or an app
  card) on their chat, the gateway's owner-inbox delivery, or a spoken yes the
  voice session binds to the daemon's record — and `confirm/2` then runs exactly
  the recorded call. The model never sees the token and never supplies the
  confirmation. Whether a prompt is still live is the channel confirmations
  store's answer (it dedupes per origin), so a call parked again after a `/deny`
  or an expired token prompts afresh against the same record.

  Once a turn's call is parked, that turn may run nothing else while the owner
  decides: the held result carries `access_waiting: true`, the agent loop stamps
  `:access_waiting` on its context from it (the rest of the same step included),
  the Realtime session stamps it while its call's record waits (`waiting?/1`),
  and every capability is then refused here. The content that made the gate ask
  must not be able to answer the owner's prompt itself — click the app card or
  the Telegram button, drive a signed-in chat tab, or play a spoken "yes".

  Every held or refused call is still one model tool call, so it emits exactly
  one `[:fermix, :tool, :exec]` event under the capability's name, with
  `access_gate` naming the outcome and a typed `policy_enforcement` marker that
  proves the executor never ran. A dispatched call is labelled through the
  context (`access_gate`: `direct`, `scheduled` or `confirmed`), which the single
  emitter copies into the executor's own event.
  """

  require Logger

  alias FermixCore.Acp.Identity
  alias FermixCore.Capabilities.AccessGate.Pending
  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Capabilities.UntrustedContent
  alias FermixCore.Cues.MandateGate
  alias FermixCore.Harness.Authorization
  alias FermixCore.Harness.Ledger
  alias FermixCore.Memory.Repo
  alias FermixCore.Sandbox.CommandTool
  alias FermixCore.Sandbox.OsSandbox
  alias FermixCore.Sandbox.PathPolicy
  alias FermixCore.Temporal.Access
  alias FermixCore.Timeouts
  alias FermixCore.Tools.Browser
  alias FermixCore.Tools.RequestDirectoryAccess
  alias FermixCore.Tools.Telemetry, as: ToolTelemetry

  @max_args_chars 300
  # What the owner is shown of a host command (`shown_command/1`: the command or
  # a coding run's task, every other argument a coding run hands its vendor CLI,
  # the folder) past this is not shown; the call is refused rather than parked on
  # a command the owner cannot read in full.
  @max_command_chars 2_000
  @max_outcome_chars 400
  @max_source_labels 5
  @after_confirm "Once you confirm, Fermix runs exactly this command."
  @after_confirm_in_call "Fermix goes ahead only once you confirm."

  @affirmatives MapSet.new(
                  ~w(yes yeah yep yup confirm confirmed) ++
                    ["yes please", "go ahead", "do it", "yes do it", "yes go ahead"]
                )

  # What a confirmed call runs with. The last four are what a host command reads
  # to run where the turn's call would have: its folder (`:cwd`), the sandbox
  # the context named (`:sandbox_config`; a chat turn names none and reads the
  # live one), an ACP session's env and the platform seam (`:os_sandbox`). They
  # are frozen at park time, so a sandbox mode or cwd changed after parking does
  # not reach the confirmed run — acceptable for a one-shot owner confirmation
  # that must come within 60 s. `Pending` holds the snapshot while the record
  # waits, while it runs, and in its done tombstone for another 60 s; it drops
  # an expired record only when it next handles a call, so an idle store keeps
  # the last snapshot in memory until then (`Pending.format_status/1` redacts
  # it from crash reports and `:sys.get_status/1`).
  @snapshot_keys [
    :session_id,
    :parent_session,
    :agent_name,
    :redact_values,
    :conversation_key,
    :capability_registry,
    :computer_use_origin,
    :cwd,
    :sandbox_config,
    :session_env,
    :os_sandbox
  ]

  # What a confirmed coding run (`codex_run`, `claude_code_run`) reads beyond
  # those to start as the turn's would have (`Harness.Authorization`,
  # `Tools.HarnessRun`, `Harness.Delivery`): the attended-turn proof and the
  # vendor-config acknowledgment's surface (`:reply_fn`, `:approval_fn`,
  # `:chat_type`, `:private_approval_button?`), where the outcome reports back
  # (`:conversation_store`, `:memory_repo`), the chain depth and finished run
  # (`:harness_continuation_depth`, `:harness_run_id`), what the turn had read
  # (`:outside_sources`, which an acknowledgment hands on so the request it
  # re-runs is the same request), and the manager and executable seams
  # (`:harness_manager`, `:find_executable`). `Pending.format_status/1` redacts
  # the whole snapshot.
  @harness_snapshot_keys [
    :reply_fn,
    :approval_fn,
    :chat_type,
    :private_approval_button?,
    :conversation_store,
    :memory_repo,
    :harness_continuation_depth,
    :harness_run_id,
    :outside_sources,
    :harness_manager,
    :find_executable
  ]

  @type surface :: :voice | :this_chat | :owner_inbox
  @type refusal ::
          :worker
          | :cue_run
          | :unattended
          | :not_allowlisted
          | :no_surface
          | :voice_surface
          | :sign_in_not_allowed
          | :sign_in_not_on_voice
  @type decision :: :dispatch | :chained | {:confirm, surface()} | {:refuse, refusal()}
  @type gate_kind :: :access_sensitive | :host_command | :sign_in | nil
  @type in_call_result ::
          {:ok, :confirmed} | {:error, :denied | :unanswered | {:not_delivered, term()}}

  @doc """
  Called by `Capability.execute/3` before the executor. `{:dispatch, context}`
  runs the executor with a labelled context; `{:held, result}` is the tool result
  the caller returns instead, and the executor is never called. A result that
  parked the call for the owner carries `access_waiting: true`. Under
  `:access_waiting` every capability is held, flagged or not.

  A run a cue woke (`trigger: "cue"`) meets `Cues.MandateGate` first (M60
  §10.5): it decides the run's mandate calls (checked, recorded and, when
  allowed in `auto` mode, run there on the normalised arguments, so its
  `{:held, result}` then carries the executor's own result), refuses a call
  outside the run's tool set, and keeps a mandated run's file tools inside the
  job's skill folder. Everything else, and every other run, goes on to the
  clauses below unchanged.
  """
  @spec admit(Capability.t(), map(), map()) :: {:dispatch, map()} | {:held, Tool.tool_result()}
  def admit(%Capability{} = capability, args, %{trigger: "cue"} = context) when is_map(args) do
    case MandateGate.admit(capability, args, context) do
      :not_mandated -> admit_standard(capability, args, context)
      decided -> decided
    end
  end

  def admit(%Capability{} = capability, args, context) when is_map(args) and is_map(context),
    do: admit_standard(capability, args, context)

  defp admit_standard(%Capability{} = capability, args, %{access_waiting: true} = context) do
    Logger.info("access_gate: #{capability.name} refused, a parked call is waiting")

    hold(
      %{capability: capability, args: args, context: context},
      waiting_text(),
      "refused_waiting"
    )
  end

  defp admit_standard(%Capability{} = capability, args, context) do
    if gated?(capability, args, context) do
      call = %{capability: capability, args: args, context: context}

      case Map.fetch(context, :access_confirmed) do
        {:ok, digest} -> admit_confirmed(call, digest)
        :error -> apply_decision(decide(capability, context, args), call)
      end
    else
      {:dispatch, context}
    end
  end

  @doc """
  Whether a call `admit/3` decides here (the moduledoc's two kinds) may run now
  in `context`, must wait for the owner on a surface, or is refused. `args` are
  the call's arguments; without them (a job's tools, checked before any call) a
  call is never the next run of a chain. Pure apart from the job-row read a
  scheduled run makes and the link resolution a chained run's folder takes.
  """
  @spec decide(Capability.t(), map(), map()) :: decision()
  def decide(%Capability{} = capability, context, args \\ %{})
      when is_map(context) and is_map(args) do
    if gate_kind(capability, args) == :sign_in,
      do: sign_in_decision(context),
      else: command_decision(capability, context, args)
  end

  defp command_decision(capability, context, args) do
    cond do
      Access.worker?(context) -> {:refuse, :worker}
      cue_run?(context) -> {:refuse, :cue_run}
      scheduled_operator?(context) -> scheduled_decision(capability.name, context)
      chained_run?(capability, args, context) -> :chained
      not Access.attended_operator_turn?(context) -> {:refuse, :unattended}
      tainted?(capability, context) -> confirm_on(surface(context))
      true -> :dispatch
    end
  end

  @doc """
  Whether the turn in `context` is the owner's consent to change what a watcher
  reads or what a task may do (M60 S6). All must hold:

    * an attended owner turn (`Temporal.Access.attended_operator_turn?/1`) and
      no delegated worker of one;
    * not a scheduled run of any kind (`Harness.Authorization.scheduled?/1`),
      and never a context a cue woke (`trigger: "cue"`);
    * a private chat: `chat_type` is a direct-message label
      (`Tools.RequestDirectoryAccess.private_chat?/1`), so an absent label (a
      Slack channel mention carries none) counts as shared; or the owner's own
      paired device (the phone or the Mac app), whose channels carry no label
      because they hold no other kind of chat;
    * not a shared Buzz session (`Acp.Identity.multi_principal?/1`);
    * the turn read nothing someone else could have written: `:outside_sources`
      is an empty set. A context the loop never stamped is not consent.

  Asked by `manage_watcher` for every change but a `drop` example, and by
  `update_job` on a job a watcher wakes. It is `owner_private_turn?/1` and
  read-nothing.
  """
  @spec owner_consent_turn?(map()) :: boolean()
  def owner_consent_turn?(context) when is_map(context) do
    owner_private_turn?(context) and read_nothing?(context)
  end

  @doc """
  Whether `context` is the owner's own attended turn in a private chat, whatever
  it has read: every condition of `owner_consent_turn?/1` except the last.
  `manage_watcher` asks it for a `drop` example, which a tainted private turn
  may add, and `OpenLoops.Access` builds its own private turn on it.
  """
  @spec owner_private_turn?(map()) :: boolean()
  def owner_private_turn?(context) when is_map(context) do
    Access.attended_operator_turn?(context) and
      not Access.worker?(context) and
      not Authorization.scheduled?(context) and
      not cue_run?(context) and
      private_chat?(context) and
      not shared_channel?(context)
  end

  @doc """
  The execution check of a tool offered only on an attended owner turn
  (`manage_watcher`, `list_cues`). Advertisement is never the only barrier, so
  the tool's `execute/2` asks this too, as `recall_activity` re-checks its gate;
  its `advertise?/1` asks `Temporal.Access.attended_operator_turn?/1`, the same
  predicate. Any other turn (a scheduled or cue run, a worker, a guest) gets the
  refusal sentence, naming the tool so the trace shows which call was denied.
  """
  @spec check_attended(String.t(), map()) :: :ok | {:error, String.t()}
  def check_attended(tool, context) when is_binary(tool) and tool != "" and is_map(context) do
    if Access.attended_operator_turn?(context) do
      :ok
    else
      {:error,
       "#{tool} is available only when the owner asks in their own chat, the Fermix " <>
         "app or by voice."}
    end
  end

  @doc """
  Run a parked call the owner confirmed, once. Re-resolves the capability, which
  must still be a command of either kind on the same plugin and auth profile (a
  built-in host command has neither). Returns a short sentence for the owner
  either way.
  """
  @spec confirm(String.t(), GenServer.server()) :: {:ok, String.t()} | {:error, String.t()}
  def confirm(id, pending \\ Pending) when is_binary(id) do
    case Pending.take(id, pending) do
      {:ok, record} ->
        run_confirmed(record, pending)

      :error ->
        Logger.info("access_gate: confirm of intent #{id} found no waiting request")
        {:error, "that request expired or was already handled"}
    end
  end

  @doc """
  Which kind of call `admit/3` decides here, from the capability and the call's
  arguments: a plugin command flagged access-sensitive, a built-in host
  command, the built-in `browser` tool's `act` of kind `sign_in` (matched on
  the tool module, so no plugin tool of that name is one), or none.
  """
  @spec gate_kind(Capability.t(), map()) :: gate_kind()
  def gate_kind(%Capability{metadata: %{tool_module: Browser}}, %{"kind" => "sign_in"}),
    do: :sign_in

  def gate_kind(%Capability{metadata: %{access_sensitive?: true}}, args) when is_map(args),
    do: :access_sensitive

  def gate_kind(%Capability{metadata: %{host_command?: true}}, args) when is_map(args),
    do: :host_command

  def gate_kind(%Capability{}, args) when is_map(args), do: nil

  @doc """
  Ask the owner from inside a call and wait there for the answer (M84, the
  sign-in's approval). `prompt` is the whole question, its values already
  through `visible/1`; it is made `visible/1` again as one line, the approval
  line follows, and it goes out on the turn's surface as a parked call's prompt
  does: this chat (`approval_fn`, then `reply_fn`'s `{:approval_prompt, text,
  token}`) or the owner's own inbox (`owner_inbox_approval_fn`, the request
  marked `in_call: true`).

  The record (`Pending.park_in_call/3`, in the context's `:access_pending`
  store) names this process, which then waits at most `timeout_ms`, no longer
  than the confirmation window (`Pending.ttl_ms/0`; a longer bound raises), for
  `{:access_answer, id, :confirmed | :denied}` from a confirm or deny path. The
  deadline is `{:access_timeout, id}`, sent to this process by its own timer,
  and its firing is routed through `Timeouts.expired/3` as `:sign_in_approval`.

  A stopped turn never returns from here: `/stop` kills the turn's task, this
  call included, and the store's monitor drops the record, so a later answer
  finds nothing waiting. `{:error, {:not_delivered, reason}}` when the owner
  could not be asked (`:no_surface`, `:voice`, `:too_many_pending`, the owner
  inbox's own reason); the record is dropped first.
  """
  @spec ask_in_call(String.t(), map(), pos_integer()) :: in_call_result()
  def ask_in_call(prompt, context, timeout_ms)
      when is_binary(prompt) and prompt != "" and is_map(context) and is_integer(timeout_ms) and
             timeout_ms > 0 do
    if timeout_ms > Pending.ttl_ms(),
      do: raise(ArgumentError, "ask_in_call waits at most #{Pending.ttl_ms()} ms")

    with {:ok, surface} <- in_call_surface(context),
         {:ok, id} <- park_in_call(context),
         :ok <- deliver_in_call(surface, id, visible(prompt), context) do
      await_answer(id, context, timeout_ms)
    end
  end

  @doc """
  The owner's yes to a call waiting in `ask_in_call/3`: its process is answered
  `:confirmed` and its record ends. `{:error, :not_in_call}` when `id` names no
  such live wait: a parked call, which `confirm/2` runs, or a wait that ended.
  """
  @spec confirm_in_call(String.t(), GenServer.server()) :: :ok | {:error, :not_in_call}
  def confirm_in_call(id, pending \\ Pending) when is_binary(id) do
    case Pending.answer_in_call(id, pending) do
      :ok ->
        Logger.info("access_gate: intent #{id} confirmed in its call")
        :ok

      {:error, :not_in_call} ->
        {:error, :not_in_call}
    end
  end

  @doc """
  The owner's no, from any deny path, answered with the kind of request it
  reached: a call waiting in `ask_in_call/3` is answered `:denied` at once
  (`{:ok, :in_call}`; its turn tells the owner the outcome), and a parked call
  still waiting is dropped (`{:ok, :parked}`), so nothing of it can run and a
  call parked again asks afresh. `{:error, :not_found}` when nothing waits
  under `id`.
  """
  @spec deny(String.t(), GenServer.server()) ::
          {:ok, :in_call | :parked} | {:error, :not_found}
  def deny(id, pending \\ Pending) when is_binary(id) do
    case Pending.deny(id, pending) do
      {:ok, kind} ->
        Logger.info("access_gate: intent #{id} denied (#{kind})")
        {:ok, kind}

      {:error, :not_found} ->
        Logger.info("access_gate: deny of intent #{id} found no waiting request")
        {:error, :not_found}
    end
  end

  @doc """
  Settle a spoken answer to a parked voice call. Only a whole-utterance yes
  confirms; anything else drops the record so nothing runs.
  """
  @spec answer_spoken(String.t(), String.t(), GenServer.server()) ::
          {:confirmed, String.t()} | :declined
  def answer_spoken(id, text, pending \\ Pending) when is_binary(id) and is_binary(text) do
    if affirmative?(text) do
      {:confirmed, id}
    else
      Logger.info("access_gate: intent #{id} declined by voice")
      :ok = Pending.discard(id, pending)
      :declined
    end
  end

  @doc """
  Whether a call the turn (or voice call) in `context` parked still waits on the
  owner. While it does, that call may run nothing else: the Realtime session
  stamps `:access_waiting` from it and `admit/3` refuses every call.
  """
  @spec waiting?(map()) :: boolean()
  def waiting?(context) when is_map(context) do
    case Map.get(context, :session_id) do
      session_id when is_binary(session_id) ->
        Pending.pending_from(session_id, pending(context)) != :none

      _no_session ->
        false
    end
  end

  @doc """
  The owner's confirm line, shared by the in-chat prompt and the owner-inbox
  delivery: the one token-visibility rule, and a promise that matches what
  happens. For a parked call (`:parked`) the daemon runs the command and
  nothing resumes; for a call waiting in `ask_in_call/3` (`:in_call`) that call
  goes ahead only on a yes.
  """
  @spec approval_line(String.t(), map(), :parked | :in_call) :: String.t()
  def approval_line(token, context, kind \\ :parked)
      when is_binary(token) and is_map(context) and kind in [:parked, :in_call],
      do: RequestDirectoryAccess.approval_line(token, context, after_confirm(kind))

  defp after_confirm(:parked), do: @after_confirm
  defp after_confirm(:in_call), do: @after_confirm_in_call

  @doc """
  Control, format and line-separator characters (a line break, a bidi
  override, a zero-width space) shown as escapes, so a value cannot forge a
  line of an owner's prompt or reorder what the owner reads. Every value a
  prompt quotes goes through it.
  """
  @spec visible(String.t()) :: String.t()
  def visible(text) when is_binary(text),
    do: String.replace(text, ~r/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u, &escaped/1)

  @doc """
  Whether a spoken utterance is, as a whole, a yes. Lower-cased, punctuation
  removed, then matched against a closed English set, so "yes, but first…" and
  an echoed "say yes to confirm" are not a yes. Fails closed.
  """
  @spec affirmative?(String.t()) :: boolean()
  def affirmative?(text) when is_binary(text) do
    normalized =
      text
      |> String.downcase()
      |> String.replace(~r/[\p{P}]+/u, " ")
      |> String.split()
      |> Enum.join(" ")

    MapSet.member?(@affirmatives, normalized)
  end

  @doc """
  For `schedule_job`, `update_job`, `resume_job` and `run_job_now`: a job naming
  a tool this gate decides in `context` (a flagged tool; a host command where
  the kernel does not hold it, from a tainted turn) may be set up, changed,
  resumed or run now only from a turn that would run that tool directly.

  A job can also reach host commands its list does not name: an empty list is
  the full operator surface (`Jobs.Runner` narrows `[]` to nil), and a job that
  can run now or resume a job (`run_job_now`, `resume_job`) can start, from its
  clean run, an existing job that names any tool. A job that can start a skill
  (`skill_run`, or a skill capability by name) or set up or change a job
  (`schedule_job`, `update_job`) hands on at most its own tools (the skill's
  worker meets the run's surface, and so does a job the run sets up or
  changes), and is counted the same way. Such a job counts as naming every host
  command, so a tainted turn where commands are not confined cannot launder one
  through it. A `subagents` worker takes the job's own list and widens nothing.
  Unknown names and every other tool pass.
  """
  @spec check_job_tools([String.t()], map()) :: :ok | {:error, String.t()}
  def check_job_tools(names, context) when is_list(names) and is_map(context) do
    registry = Map.get(context, :capability_registry) || CapabilityRegistry

    case Enum.find(names, &blocked_job_tool?(registry, &1, context)) do
      nil -> check_wider_surface(registry, names, context)
      name -> {:error, job_refusal(name)}
    end
  end

  defp check_wider_surface(registry, names, context) do
    if reaches_unnamed_tools?(registry, names) and
         registry |> host_commands() |> Enum.any?(&held_for_job?(&1, context)),
       do: {:error, open_job_refusal()},
       else: :ok
  end

  # The tools through which a job's run can set up or retarget a job.
  @job_managers ~w(schedule_job update_job run_job_now resume_job)

  defp reaches_unnamed_tools?(_registry, []), do: true
  defp reaches_unnamed_tools?(registry, names), do: Enum.any?(names, &widens?(registry, &1))

  defp widens?(_registry, name) when name in @job_managers or name == "skill_run", do: true

  defp widens?(registry, name),
    do: match?({:ok, %Capability{kind: :skill}}, CapabilityRegistry.find(registry, name))

  defp host_commands(registry) do
    registry
    |> CapabilityRegistry.list()
    |> Enum.filter(&(gate_kind(&1, %{}) == :host_command))
  end

  @doc """
  What a voice model is told when a confirmed run crashed before it reported:
  whether the command reached the device is unknown, so it must not be resent
  blindly. Shared by both voice engines.
  """
  @spec outcome_unknown_text() :: String.t()
  def outcome_unknown_text do
    "The owner said yes, but whether the command reached the device is unknown. " <>
      "Check its state before sending it again."
  end

  @doc "The typed proof that a held or refused call never reached its executor."
  @spec pre_execution_marker(:confirm | :deny) :: map()
  def pre_execution_marker(decision) when decision in [:confirm, :deny] do
    %{source: "access_gate", decision: Atom.to_string(decision), phase: "pre_execution"}
  end

  @doc """
  The exec-event metadata of a call held for the owner (`:confirm`) or refused
  (`:deny`), whose executor never ran: the gate's `label`, the typed marker,
  and a bounded `error_code` (the label) with a fixed `error_summary`, so the
  exported span is errored, never a call that succeeded. No user content.
  Shared with `Cues.MandateGate`.
  """
  @spec held_metadata(String.t(), :confirm | :deny) :: map()
  def held_metadata(label, decision)
      when is_binary(label) and label != "" and decision in [:confirm, :deny] do
    %{
      access_gate: label,
      policy_enforcement: pre_execution_marker(decision),
      error_code: label,
      error_summary: held_summary(decision)
    }
  end

  defp held_summary(:confirm), do: "held by the access gate for the owner's confirmation"
  defp held_summary(:deny), do: "refused by the access gate"

  @doc "The fingerprint a confirmation is bound to: the tool and its exact arguments."
  @spec digest(String.t(), map()) :: String.t()
  def digest(tool, args) when is_binary(tool) and is_map(args) do
    {tool, args}
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # --- decision ------------------------------------------------------------

  # The one predicate for whether a call meets `decide/3`: a flagged command
  # and a sign-in always; a host command only where the kernel does not hold
  # it, and only in a tainted turn. Metadata first, so every other call returns
  # without reading the context.
  defp gated?(capability, args, context) do
    case gate_kind(capability, args) do
      :access_sensitive -> true
      :sign_in -> true
      :host_command -> host_command_gated?(capability, context)
      nil -> false
    end
  end

  # A sign-in only refuses: it never parks, and an admitted one asks the owner
  # from its own call. Who is refused is `sign_in_refusal/1`'s answer.
  defp sign_in_decision(context) do
    case sign_in_refusal(context) do
      nil ->
        :dispatch

      :voice ->
        {:refuse, :sign_in_not_on_voice}

      cause ->
        Logger.info("access_gate: browser sign_in refused (#{cause})")
        {:refuse, :sign_in_not_allowed}
    end
  end

  # In order: no owner is in a worker's, a cue run's or a scheduled run's loop
  # (a job row naming `browser` is never read), only the owner's attended turn
  # may sign in, and other people post in a shared Buzz channel. A voice turn is
  # a live call's (`voice_call_id`) or one its origin marks as voice.
  defp sign_in_refusal(context) do
    cond do
      Access.worker?(context) -> :worker
      cue_run?(context) -> :cue_run
      Authorization.scheduled?(context) -> :scheduled
      not Access.attended_operator_turn?(context) -> :unattended
      shared_channel?(context) -> :shared_channel
      voice_turn?(context) -> :voice
      true -> nil
    end
  end

  defp voice_turn?(context),
    do:
      is_binary(Map.get(context, :voice_call_id)) or
        Map.get(context, :computer_use_origin) == :voice

  # A host command is gated when the turn read outside content and Fermix cannot
  # sandbox this call: the host has no kernel enforcement (Linux without
  # Landlock), or the call runs unconfined even where it does (the
  # `codex`/`claude_code` presets, the coding runs). Its taint is only what the turn read, never the shared Buzz
  # channel on its own (owner decision): a Buzz session answers by running the
  # `buzz` CLI through `shell`.
  defp host_command_gated?(capability, context) do
    read_outside?(capability, context) and
      (not confined_call?(capability) or not OsSandbox.enforced?(os_opts(context)))
  end

  # What a chained run may carry: its task and folder, and settings that widen
  # nothing it can reach or how. Every other argument (extra directories, a
  # sandbox or permission posture, a file of instructions, images, a schema
  # file, a session to resume, tool lists, extra instructions) would be chosen
  # from the finished run's report and was never shown to the owner.
  @chain_argument_keys ~w(prompt cwd model effort max_turns timeout_minutes progress)

  # The coding agent each run tool starts, as a ledger row names it.
  @chain_vendors %{"codex_run" => "codex", "claude_code_run" => "claude"}

  # Owner decision ("same folder only"): a finished coding run's follow-up turn
  # (`harness_continuation_depth` above zero) may start the next run of the
  # chain without asking, when that run's report is all the turn has read, its
  # arguments are only `@chain_argument_keys`, and the finished run's ledger row
  # (by the notice's `:harness_run_id`) allows it (`chain_parent_allows?/3`).
  # The ledger records no posture for a run, so a posture-bearing argument is
  # never known to match it and is never chained. Anything else meets the rules
  # after it in `decide/3`, which refuse it: a follow-up turn is not the owner's
  # own. The chain stays bounded by `Harness.Continuation`'s depth cap
  # (`max_depth/0`, `continuable?/1`): a run started here carries the turn's
  # depth on its row, and at the cap its outcome is delivered as text, with no
  # follow-up turn. Cheap checks first, so a turn that read anything else never
  # reads the ledger.
  defp chained_run?(%Capability{metadata: %{coding_run?: true}} = capability, args, context) do
    follow_up_turn?(context) and
      Map.get(context, :outside_sources) ==
        MapSet.new([UntrustedContent.harness_continuation_source()]) and
      Enum.all?(Map.keys(args), &(&1 in @chain_argument_keys)) and
      chain_parent_allows?(capability, args, context)
  end

  defp chained_run?(%Capability{}, _args, _context), do: false

  # The finished run, read from its row: the new run starts the same coding
  # agent in the same starting folder, and no run yet names it as the run it
  # continued (`Ledger.children/2`, which the admit records from the launching
  # turn), so one finished run continues as one run, never a tree, whichever
  # turn asks: a resumed follow-up, or one after a restart. The Manager checks
  # the same again inside the admit (`sole_continuation`). A lookup that fails
  # chains nothing.
  defp chain_parent_allows?(capability, args, context) do
    repo = Map.get(context, :memory_repo) || Repo

    with run_id when is_binary(run_id) <- Map.get(context, :harness_run_id),
         {:ok, %{vendor: vendor, cwd: cwd}} <- Ledger.get(run_id, server: repo),
         true <- Map.fetch!(@chain_vendors, capability.name) == vendor,
         true <- same_folder?(Map.get(args, "cwd"), cwd),
         {:ok, []} <- Ledger.children(run_id, server: repo) do
      true
    else
      _unknown_other_or_already_continued -> false
    end
  end

  defp follow_up_turn?(context) do
    depth = Map.get(context, :harness_continuation_depth)
    is_integer(depth) and depth > 0
  end

  # Both resolved through their links; a relative folder never matches, since
  # the run would resolve it against a base this check does not know.
  defp same_folder?(folder, run_folder) when is_binary(folder) and is_binary(run_folder) do
    with :absolute <- Path.type(folder),
         {{:ok, same}, {:ok, same}} <-
           {PathPolicy.resolve_links(folder), PathPolicy.resolve_links(run_folder)} do
      true
    else
      _relative_different_or_unresolvable -> false
    end
  end

  defp same_folder?(_folder, _run_folder), do: false

  defp confined_call?(%Capability{metadata: metadata}),
    do: Map.get(metadata, :host_command_confined?, true)

  # The platform seam `OsSandbox` reads; tests inject `os: {:unix, :linux}` or
  # `{:unix, :darwin}` here so the host the suite runs on never decides.
  defp os_opts(context), do: Map.get(context, :os_sandbox, [])

  # Every job run carries its `trigger`; only a cue run's is "cue".
  defp cue_run?(context), do: Map.get(context, :trigger) == "cue"

  # The phone and the Mac app are paired to the owner and hold one conversation
  # each, so their channels set no `chat_type`; for consent they are private.
  @owner_device_channels ["mobile", "companion"]

  defp private_chat?(context) do
    RequestDirectoryAccess.private_chat?(Map.get(context, :chat_type)) or
      Map.get(context, :channel) in @owner_device_channels
  end

  defp scheduled_operator?(context),
    do: Map.get(context, :source_trust) == :operator and Authorization.scheduled?(context)

  defp scheduled_decision(name, context) do
    case Authorization.authorize(name, context) do
      :ok ->
        :dispatch

      {:error, reason} ->
        Logger.info("access_gate: scheduled #{name} refused: #{inspect(reason)}")
        {:refuse, :not_allowlisted}
    end
  end

  defp tainted?(capability, context),
    do: shared_channel?(context) or read_outside?(capability, context)

  # Other people can post in a Buzz channel, so a request there is not proof the
  # owner asked, whatever the turn read (owner decision, MOB-1).
  defp shared_channel?(context), do: Identity.multi_principal?(Map.get(context, :session_env))

  # A context the loop never stamped is read as tainted: absence is not proof
  # that the turn read nothing.
  defp read_outside?(capability, context) do
    case Map.fetch(context, :outside_sources) do
      {:ok, %MapSet{} = sources} -> outside_labels(capability, sources) != []
      _absent_or_malformed -> true
    end
  end

  # Consent needs an empty set the loop stamped; absent or malformed is not one.
  defp read_nothing?(context) do
    case Map.fetch(context, :outside_sources) do
      {:ok, %MapSet{} = sources} -> MapSet.size(sources) == 0
      _absent_or_malformed -> false
    end
  end

  defp outside_labels(capability, sources) do
    sources
    |> MapSet.delete(UntrustedContent.outside_source(capability))
    |> Enum.map(fn {_kind, label} -> label end)
    |> Enum.sort()
  end

  defp source_set(context) do
    case Map.get(context, :outside_sources) do
      %MapSet{} = sources -> sources
      _absent_or_malformed -> MapSet.new()
    end
  end

  # The facts are disjoint configurations, checked in one order: a voice call
  # first (the voice channel is also an owner surface without slash commands).
  defp surface(context) do
    cond do
      is_binary(Map.get(context, :voice_call_id)) -> :voice
      RequestDirectoryAccess.attended_operator?(context) -> :this_chat
      is_function(Map.get(context, :owner_inbox_approval_fn), 1) -> :owner_inbox
      true -> :none
    end
  end

  defp confirm_on(:none), do: {:refuse, :no_surface}
  defp confirm_on(surface), do: {:confirm, surface}

  # The store a context parks in: the application's, unless a caller hands one
  # in (`:access_pending`), as a test does to stay off the shared store.
  defp pending(context), do: Map.get(context, :access_pending) || Pending

  # --- effects (`call` is the one flagged call: capability, args, context) --

  defp apply_decision(:dispatch, %{context: context}),
    do: {:dispatch, Map.put(context, :access_gate, dispatch_label(context))}

  defp apply_decision(:chained, %{context: context}),
    do: {:dispatch, Map.put(context, :access_gate, "chained")}

  defp apply_decision({:confirm, surface}, call), do: park_or_refuse(call, surface)
  defp apply_decision({:refuse, reason}, call), do: refuse(call, reason)

  defp dispatch_label(context),
    do: if(Authorization.scheduled?(context), do: "scheduled", else: "direct")

  defp admit_confirmed(%{capability: capability, args: args, context: context} = call, digest) do
    if digest == digest(capability.name, args) do
      {:dispatch, Map.put(context, :access_gate, "confirmed")}
    else
      Logger.warning("access_gate: #{capability.name} confirmation did not match its call")
      hold(call, mismatch_text(capability.name), "refused_confirm_mismatch")
    end
  end

  # A host command is parked only where the owner reads it whole. Never on a
  # voice call, where the model that read the hostile content would phrase the
  # question; never when it is too long to show. Both are refused instead, and a
  # plugin command keeps the surface `decide/2` chose, a spoken yes included.
  defp park_or_refuse(%{capability: capability} = call, surface) do
    cond do
      gate_kind(capability, %{}) != :host_command ->
        park(call, surface)

      surface == :voice ->
        refuse(call, :voice_surface)

      unshown_file?(call) ->
        hold(call, unshown_file_text(capability.name), "refused_unshown_file")

      String.length(shown_command(call)) > @max_command_chars ->
        hold(call, command_too_long_text(capability.name), "refused_command_too_long")

      true ->
        park(call, surface)
    end
  end

  defp park(call, surface) do
    call = with_sources(call)

    call
    |> pending_attrs(surface)
    |> Pending.park(pending(call.context))
    |> parked(call, surface)
  end

  # Why the owner is asked, resolved once: the sources the turn read (minus the
  # target plugin's own) and, for a plugin command, whether the channel is
  # shared. A host command is never held for the channel alone, so its reason
  # never names it. Both the park and the refuse paths read it.
  defp with_sources(%{capability: capability, context: context} = call) do
    Map.merge(call, %{
      sources: outside_labels(capability, source_set(context)),
      shared_channel?:
        gate_kind(capability, %{}) == :access_sensitive and shared_channel?(context)
    })
  end

  defp pending_attrs(%{capability: capability, args: args, context: context} = call, surface) do
    %{
      tool: capability.name,
      args: args,
      digest: digest(capability.name, args),
      plugin: Map.get(capability.metadata, :plugin),
      auth_profile: Map.get(capability.metadata, :auth_profile),
      command_ref: command_ref(capability),
      binding: binding(surface, context),
      sources: call.sources,
      snapshot:
        context |> Map.take(snapshot_keys(capability)) |> Map.put(:source_trust, :operator)
    }
  end

  defp snapshot_keys(%Capability{metadata: %{coding_run?: true}}),
    do: @snapshot_keys ++ @harness_snapshot_keys

  defp snapshot_keys(%Capability{}), do: @snapshot_keys

  defp binding(:voice, context), do: {:voice_call, Map.fetch!(context, :voice_call_id)}
  defp binding(_surface, context), do: {:conversation, Map.get(context, :conversation_key)}

  defp parked({:ok, id, fresh}, call, surface) when fresh in [:new, :existing] do
    Logger.info(
      "access_gate: #{call.capability.name} parked as intent #{id} (#{surface}, #{fresh})"
    )

    deliver(surface, Map.put(call, :id, id), fresh)
  end

  defp parked({:ok, id, :running}, call, surface),
    do: hold(call, existing_text(), "held_#{surface}", id)

  defp parked({:ok, id, {:done, outcome}}, call, _surface),
    do: hold(call, done_text(call.capability.name, outcome), "already_confirmed", id)

  defp parked({:error, :too_many_pending}, call, _surface) do
    Logger.warning("access_gate: #{call.capability.name} refused, too many confirmations waiting")
    hold(call, full_text(call.capability.name), "refused_full")
  end

  # The channel confirmations store answers whether a prompt is live: `:new`
  # means the owner has no live token for this call (first ask, or the last one
  # was denied or expired), so the prompt goes out; `:existing` sends nothing.
  defp deliver(:this_chat, call, _fresh) do
    case call.context.approval_fn.(%{access_sensitive: call.id}) do
      {:ok, token, :new} ->
        call.context.reply_fn.({:approval_prompt, chat_prompt(call, token), token})
        hold_parked(call, chat_text(call), "held_this_chat")

      {:ok, _token, :existing} ->
        hold_parked(call, existing_text(), "held_this_chat")
    end
  end

  defp deliver(:owner_inbox, call, _fresh) do
    case call.context.owner_inbox_approval_fn.(%{
           access_sensitive: call.id,
           prompt: owner_prompt(call)
         }) do
      {:ok, _token, :new} ->
        hold_parked(call, inbox_text(call), "held_owner_inbox")

      {:ok, _token, :existing} ->
        hold_parked(call, existing_text(), "held_owner_inbox")

      {:error, reason} ->
        Logger.warning(
          "access_gate: intent #{call.id} owner inbox unreachable: #{inspect(reason)}"
        )

        :ok = Pending.discard(call.id, pending(call.context))
        refuse(call, :no_surface)
    end
  end

  defp deliver(:voice, call, :new),
    do: hold_parked(call, voice_text(call.capability.name), "held_voice")

  defp deliver(:voice, call, :existing), do: hold_parked(call, existing_text(), "held_voice")

  defp refuse(%{capability: capability, args: args} = call, reason) do
    call = with_sources(call)
    Logger.info("access_gate: #{capability.name} refused (#{reason})")
    hold(call, refusal_text(gate_kind(capability, args), reason, call), "refused_#{reason}")
  end

  # One model tool call, one exec event: the executor never ran, so the gate
  # emits the call's event itself, with the typed pre-execution marker.
  defp hold(call, text, label, intent_id \\ nil) do
    metadata =
      label
      |> held_metadata(marker_decision(label))
      |> maybe_put(:access_intent, intent_id)

    ToolTelemetry.exec(call.capability.name, call.context, false, 0,
      metadata: metadata,
      input: call.args
    )

    {:held, Tool.error(text)}
  end

  # The call now waits on the owner under its parked record (a new one, or one
  # this or another turn of the chat parked earlier): the result says so, so the
  # caller runs nothing else of this turn.
  defp hold_parked(call, text, label) do
    {:held, result} = hold(call, text, label, call.id)
    {:held, Map.put(result, :access_waiting, true)}
  end

  defp marker_decision("held_" <> _surface), do: :confirm
  defp marker_decision(_refused_or_done), do: :deny

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # --- asking from inside a call (M84) -------------------------------------

  # The surfaces a parked call's prompt goes out on, minus a voice call's: a
  # spoken yes cannot answer a call that waits in a turn's process.
  defp in_call_surface(context) do
    case surface(context) do
      surface when surface in [:this_chat, :owner_inbox] -> {:ok, surface}
      :voice -> {:error, {:not_delivered, :voice}}
      :none -> {:error, {:not_delivered, :no_surface}}
    end
  end

  defp park_in_call(context) do
    case Pending.park_in_call(
           %{session_id: Map.get(context, :session_id)},
           self(),
           pending(context)
         ) do
      {:ok, id} ->
        {:ok, id}

      {:error, :too_many_pending} ->
        Logger.warning("access_gate: in-call ask refused, too many confirmations waiting")
        {:error, {:not_delivered, :too_many_pending}}
    end
  end

  # A fresh id has no live token, so the channel store answers `:new`; anything
  # else, or an inbox that cannot be reached, ends the ask before it waits.
  defp deliver_in_call(:this_chat, id, prompt, context) do
    case context.approval_fn.(%{access_sensitive: id}) do
      {:ok, token, :new} ->
        text = prompt <> "\n\n" <> approval_line(token, context, :in_call)
        context.reply_fn.({:approval_prompt, text, token})
        :ok

      {:ok, _token, :existing} ->
        not_delivered(id, context, :existing_token)
    end
  end

  defp deliver_in_call(:owner_inbox, id, prompt, context) do
    case context.owner_inbox_approval_fn.(%{access_sensitive: id, prompt: prompt, in_call: true}) do
      {:ok, _token, :new} -> :ok
      {:ok, _token, :existing} -> not_delivered(id, context, :existing_token)
      {:error, reason} -> not_delivered(id, context, reason)
    end
  end

  defp not_delivered(id, context, reason) do
    Logger.warning("access_gate: intent #{id} not delivered: #{inspect(reason)}")
    _closed_or_gone = Pending.close_in_call(id, pending(context))
    {:error, {:not_delivered, reason}}
  end

  # The answer comes from a confirm or deny path through the store; the
  # deadline from this process's own timer. Both are matched on the id, and the
  # timer is cancelled and its message flushed on every way out.
  defp await_answer(id, context, timeout_ms) do
    timer = Process.send_after(self(), {:access_timeout, id}, timeout_ms)
    Logger.info("access_gate: intent #{id} waits in its call for the owner")

    receive do
      {:access_answer, ^id, answer} ->
        cancel_deadline(timer, id)
        answered(id, answer)

      {:access_timeout, ^id} ->
        deadline_passed(id, context, timeout_ms)
    end
  end

  defp cancel_deadline(timer, id) do
    _left = Process.cancel_timer(timer)

    receive do
      {:access_timeout, ^id} -> :ok
    after
      0 -> :ok
    end
  end

  # The store sends an answer before it replies to any later call, so a wait
  # whose record already ended finds that answer here; a record the window
  # dropped has none, and the wait is unanswered.
  defp deadline_passed(id, context, timeout_ms) do
    case Pending.close_in_call(id, pending(context)) do
      :ok -> unanswered(id, context, timeout_ms)
      {:error, :not_found} -> answer_or_unanswered(id, context, timeout_ms)
    end
  end

  defp answer_or_unanswered(id, context, timeout_ms) do
    receive do
      {:access_answer, ^id, answer} -> answered(id, answer)
    after
      0 -> unanswered(id, context, timeout_ms)
    end
  end

  defp answered(id, :confirmed) do
    Logger.info("access_gate: intent #{id} approved by the owner")
    {:ok, :confirmed}
  end

  defp answered(id, :denied) do
    Logger.info("access_gate: intent #{id} denied by the owner")
    {:error, :denied}
  end

  defp unanswered(id, context, timeout_ms) do
    Logger.info("access_gate: intent #{id} unanswered")
    correlation = Map.take(context, [:session_id, :parent_session])

    {:error, {:timeout, :sign_in_approval, _ms}} =
      Timeouts.expired(:sign_in_approval, timeout_ms, correlation)

    {:error, :unanswered}
  end

  # --- confirmation --------------------------------------------------------

  defp run_confirmed(record, pending) do
    {status, text} =
      case current_capability(record) do
        {:ok, capability} -> dispatch_confirmed(capability, record)
        {:error, :plugin_changed} -> {:error, changed_text(record.tool)}
      end

    :ok = Pending.finish(record, text, pending)
    Logger.info("access_gate: intent #{record.id} confirmed and run: #{status}")
    {status, text}
  end

  defp current_capability(record) do
    registry = Map.get(record.snapshot, :capability_registry) || CapabilityRegistry

    case CapabilityRegistry.find(registry, record.tool) do
      {:ok, %Capability{} = capability} ->
        same_command(capability, record)

      :error ->
        Logger.warning("access_gate: intent #{record.id} lost #{record.tool} before confirm")
        {:error, :plugin_changed}
    end
  end

  defp same_command(%Capability{} = capability, record) do
    if command_unchanged?(capability, record) do
      {:ok, capability}
    else
      Logger.warning("access_gate: intent #{record.id} #{record.tool} changed before confirm")
      {:error, :plugin_changed}
    end
  end

  # The command the owner confirmed must be the one that runs. A plugin command
  # is pinned by its plugin and auth profile; a host command by what it runs
  # (the built-in module, or a declared command's executable and args), so a
  # command re-declared between park and confirm never runs under the old yes.
  defp command_unchanged?(%Capability{metadata: metadata} = capability, record) do
    case gate_kind(capability, %{}) do
      :access_sensitive ->
        Map.get(metadata, :plugin) == record.plugin and
          Map.get(metadata, :auth_profile) == record.auth_profile

      :host_command ->
        command_ref(capability) == record.command_ref

      _neither_command ->
        false
    end
  end

  # What pins a host command across the confirmation: the built-in's module, or
  # a declared command's executable and fixed args.
  defp command_ref(%Capability{executor: {CommandTool, :execute, [spec]}}),
    do: {:command, Map.get(spec, :command), Map.get(spec, :args, [])}

  defp command_ref(%Capability{metadata: %{tool_module: module}}), do: {:module, module}
  defp command_ref(%Capability{}), do: nil

  defp dispatch_confirmed(capability, record) do
    context =
      Map.merge(record.snapshot, %{access_confirmed: record.digest, access_intent: record.id})

    capability
    |> Capability.execute(record.args, context)
    |> confirmed_outcome(capability, record)
  end

  # What the owner reads in their chat once a confirmed call ran, redacted and
  # made `visible/1` as the prompt was, since a command's output or error can
  # carry anything its target wrote.
  defp confirmed_outcome({:ok, %{success: true, output: output}}, capability, record),
    do: {:ok, ran_text(capability, record, output)}

  defp confirmed_outcome({:ok, %{success: false, error: error}}, _capability, record),
    do: {:error, "#{record.tool} failed: #{shown_outcome(error, record)}"}

  defp confirmed_outcome({:error, reason}, _capability, record),
    do: {:error, "#{record.tool} failed: #{shown_outcome(inspect(reason), record)}"}

  defp shown_outcome(text, record) do
    text
    |> ToolTelemetry.redact(Map.get(record.snapshot, :redact_values, []))
    |> visible()
    |> bounded(@max_outcome_chars)
  end

  defp blocked_job_tool?(registry, name, context) when is_binary(name) do
    case CapabilityRegistry.find(registry, name) do
      {:ok, %Capability{} = capability} -> held_for_job?(capability, context)
      :error -> false
    end
  end

  defp blocked_job_tool?(_registry, _name, _context), do: false

  # Whether this turn could not run `capability` itself, so a job naming it may
  # not be set up from here either. No call's arguments: a job's run is never
  # the next run of a coding-run chain.
  defp held_for_job?(capability, context),
    do: gated?(capability, %{}, context) and decide(capability, context) != :dispatch

  # --- owner-facing text (Fermix-authored; never quotes the model or a sender)

  # A plugin command shows its description and JSON arguments; a host command
  # shows everything that will run, verbatim (`shown_command/1`).
  defp owner_prompt(%{capability: %{metadata: %{host_command?: true}} = capability} = call) do
    [
      "Confirm #{capability.name}? " <> prompt_head(capability),
      shown_command(call),
      "Asked because #{reason_phrase(call)}."
    ]
    |> Enum.join("\n")
  end

  defp owner_prompt(%{capability: capability} = call) do
    """
    Confirm #{capability.name}? #{capability.description}
    Arguments: #{args_text(call)}
    Asked because #{reason_phrase(call)}.\
    """
  end

  defp prompt_head(%Capability{metadata: %{coding_run?: true}}),
    do: "It starts a coding agent on this computer, outside Fermix's sandbox, with your access."

  defp prompt_head(%Capability{}),
    do: "It runs a command on this computer, which Fermix cannot sandbox here."

  defp command_label(%Capability{metadata: %{coding_run?: true}}), do: "Task"
  defp command_label(%Capability{}), do: "Command"

  defp chat_prompt(call, token),
    do: owner_prompt(call) <> "\n\n" <> approval_line(token, call.context)

  defp args_text(%{args: args, context: context}) do
    args
    |> Jason.encode!()
    |> ToolTelemetry.redact(Map.get(context, :redact_values, []))
    |> visible()
    |> bounded(@max_args_chars)
  end

  # What the owner is shown of a host command, one named line each: the
  # command (a coding run's task), every other argument a coding run hands its
  # vendor CLI, and the folder when that is known. Each value is redacted (a
  # session secret the command echoes is never posted to the chat, as a plugin
  # command's JSON arguments are not) and made `visible/1`, so no value can
  # start a line of its own. Unbounded here; `park_or_refuse/2` refuses past
  # `@max_command_chars`, measured on this whole text.
  defp shown_command(%{capability: capability, args: args, context: context}) do
    [{command_label(capability), command_text(capability, args)}]
    |> Kernel.++(argument_lines(capability, args))
    |> Kernel.++(folder_line(command_folder(capability, args, context)))
    |> Enum.map_join("\n", fn {label, value} ->
      label <> ": " <> (value |> redacted(context) |> visible())
    end)
  end

  defp escaped("\n"), do: "\\n"
  defp escaped("\r"), do: "\\r"
  defp escaped("\t"), do: "\\t"
  defp escaped(<<code::utf8>>), do: "\\u{" <> Integer.to_string(code, 16) <> "}"

  # The exact command a host-command call runs, verbatim: the shell string, the
  # git argv, a declared command's executable and args, or the task a coding
  # agent is given.
  defp command_text(%Capability{name: "shell"}, %{"command" => command}) when is_binary(command),
    do: command

  defp command_text(%Capability{name: "git_write"}, args),
    do: join_words(["git", Map.get(args, "command") | extra_list(Map.get(args, "args"))])

  defp command_text(%Capability{executor: {CommandTool, :execute, [spec]}}, args) do
    join_words(
      [Map.get(spec, :command) | Map.get(spec, :args, [])] ++
        extra_list(Map.get(args, "args")) ++ [Map.get(args, "prompt")]
    )
  end

  defp command_text(%Capability{metadata: %{coding_run?: true}}, args),
    do: argument_value(Map.get(args, "prompt"))

  defp command_text(%Capability{}, args), do: Jason.encode!(args)

  # Where a host command runs, when the call or the turn says: `shell`'s
  # `working_dir`, else the turn's folder; `git_write`'s `repo`; a coding run's
  # `cwd`.
  defp command_folder(%Capability{name: "shell"}, args, context),
    do: Map.get(args, "working_dir") || Map.get(context, :cwd)

  defp command_folder(%Capability{name: "git_write"}, args, _context), do: Map.get(args, "repo")

  defp command_folder(%Capability{metadata: %{coding_run?: true}}, args, _context),
    do: Map.get(args, "cwd")

  defp command_folder(%Capability{}, _args, _context), do: nil

  defp folder_line(folder) when is_binary(folder), do: [{"Folder", folder}]
  defp folder_line(_none), do: []

  # A coding run hands every argument but its task and folder to the vendor CLI
  # (or to the run's own limits), so each is shown on a named line, in this
  # order; one not named here follows as JSON, so nothing that will run is
  # hidden from the owner.
  @coding_run_argument_lines [
    {"append_system_prompt", "Extra instructions"},
    {"append_system_prompt_file", "Extra instructions file"},
    {"add_dirs", "Extra directories"},
    {"permission_mode", "Permission mode"},
    {"sandbox", "Sandbox"},
    {"allowed_tools", "Allowed tools"},
    {"disallowed_tools", "Disallowed tools"},
    {"profile", "Codex profile"},
    {"model", "Model"},
    {"effort", "Effort"},
    {"images", "Images"},
    {"output_schema", "Output schema"},
    {"json_schema", "JSON schema"},
    {"resume", "Resumes session"},
    {"continue", "Continues the last session"},
    {"max_turns", "Max turns"},
    {"bare", "Bare mode"},
    {"ephemeral", "Ephemeral"},
    {"timeout_minutes", "Time limit (minutes)"},
    {"progress", "Progress updates"}
  ]
  @coding_run_shown_keys ["prompt", "cwd" | Enum.map(@coding_run_argument_lines, &elem(&1, 0))]

  defp argument_lines(%Capability{metadata: %{coding_run?: true}}, args) do
    named =
      for {key, label} <- @coding_run_argument_lines,
          Map.has_key?(args, key),
          do: {label, argument_value(Map.fetch!(args, key))}

    named ++ other_arguments(Map.drop(args, @coding_run_shown_keys))
  end

  defp argument_lines(%Capability{}, _args), do: []

  defp other_arguments(rest) when map_size(rest) == 0, do: []
  defp other_arguments(rest), do: [{"Other arguments", Jason.encode!(rest)}]

  # A file of extra instructions is passed to the vendor CLI by path, so the
  # owner cannot review its contents in a confirmation: such a held run is
  # refused rather than parked.
  defp unshown_file?(%{capability: %Capability{metadata: %{coding_run?: true}}, args: args}),
    do: Map.has_key?(args, "append_system_prompt_file")

  defp unshown_file?(_call), do: false

  defp argument_value(value) when is_binary(value), do: value

  defp argument_value(values) when is_list(values) do
    if Enum.all?(values, &is_binary/1), do: Enum.join(values, ", "), else: Jason.encode!(values)
  end

  defp argument_value(value), do: Jason.encode!(value)

  defp redacted(text, context),
    do: ToolTelemetry.redact(text, Map.get(context, :redact_values, []))

  defp extra_list(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp extra_list(_absent), do: []

  defp join_words(parts), do: parts |> Enum.filter(&is_binary/1) |> Enum.join(" ")

  # Why the owner is asked: the shared channel, what the turn read, or both.
  defp reason_phrase(%{shared_channel?: true, sources: []}), do: shared_channel_reason()

  defp reason_phrase(%{shared_channel?: true, sources: sources}),
    do: shared_channel_reason() <> ", and " <> read_reason(sources)

  defp reason_phrase(%{sources: []}), do: "Fermix could not tell what this request read first"
  defp reason_phrase(%{sources: sources}), do: "this request came " <> read_reason(sources)

  defp shared_channel_reason,
    do: "this request came from a shared Buzz channel, where other people can send messages"

  defp read_reason(sources) do
    shown = sources |> Enum.take(@max_source_labels) |> Enum.join(", ")
    "after reading content someone else could have written (#{shown})"
  end

  defp bounded(text, max) when is_binary(text) do
    if String.length(text) <= max, do: text, else: String.slice(text, 0, max) <> "…"
  end

  # What the owner reads once a confirmed call ran. A coding run returns its
  # launch acknowledgment, so they read which run started, where, and where its
  # outcome lands; every other call, its bounded output.
  defp ran_text(%Capability{metadata: %{coding_run?: true}}, record, output) do
    case Jason.decode(output) do
      {:ok, %{"run_id" => run_id}} when is_binary(run_id) ->
        coding_run_started(record, run_id)

      {:ok, %{"status" => "awaiting_acknowledgment"}} ->
        "#{record.tool} did not start: you were asked to acknowledge a change to " <>
          "coding-agent config first."

      _not_a_launch ->
        output_text(record, output)
    end
  end

  defp ran_text(%Capability{}, record, output), do: output_text(record, output)

  defp output_text(record, output), do: "#{record.tool} ran: #{shown_outcome(output, record)}"

  defp coding_run_started(record, run_id) do
    folder = record.args |> Map.get("cwd") |> argument_value()

    "#{record.tool} started coding run #{shown_outcome(run_id, record)} in " <>
      shown_outcome(folder, record) <>
      ". It reports back into the chat that asked for it when it finishes."
  end

  # --- model-facing text (fixed, never carries the token) -------------------

  # Why the command needs the owner's consent at all, before why now.
  defp what(%{capability: capability}) do
    case gate_kind(capability, %{}) do
      :access_sensitive -> "is an access-sensitive command"
      :host_command -> "runs a command Fermix cannot sandbox here"
    end
  end

  defp chat_text(%{capability: %{name: tool}} = call) do
    "Not sent. #{tool} #{what(call)} and #{reason_phrase(call)}, so the " <>
      "owner must confirm it. A confirmation is now in this chat and expires in 60 seconds. " <>
      "Tell the owner and stop. Do not call #{tool} again: it runs the moment they confirm."
  end

  defp inbox_text(%{capability: %{name: tool}} = call) do
    "Not sent. #{tool} #{what(call)} and #{reason_phrase(call)}, so the " <>
      "confirmation went to the owner's own chat. Say it is waiting on the owner's " <>
      "confirmation there, then stop. Do not call #{tool} again: it runs the moment they confirm."
  end

  defp voice_text(tool) do
    "Not sent yet. The owner must say yes. Ask them in one short sentence whether to run " <>
      "#{tool} with these arguments, then wait. Do not call it again: Fermix runs it when " <>
      "it hears their yes and tells you what happened."
  end

  defp waiting_text do
    "Not run: a command that needs the owner's confirmation is already waiting on their " <>
      "answer, and nothing else runs until they give it. Tell the owner it is waiting, then stop."
  end

  defp existing_text do
    "Not sent. A confirmation for this exact request is already waiting on the owner. " <>
      "Do not call it again."
  end

  defp done_text(tool, outcome) do
    "Already done after the owner confirmed: #{outcome}. Do not send #{tool} again."
  end

  defp full_text(tool) do
    "#{tool} was not sent: too many confirmations are waiting; try again shortly."
  end

  defp unshown_file_text(tool) do
    "#{tool} was not run: it names a file of extra instructions " <>
      "(append_system_prompt_file) whose contents the owner cannot review in a " <>
      "confirmation. Put the instructions in the task, or ask the owner to run it themselves."
  end

  defp command_too_long_text(tool) do
    "#{tool} was not run: the command is too long for the owner to confirm safely. " <>
      "Ask the owner to run a shorter command, or run it themselves."
  end

  defp mismatch_text(tool) do
    "#{tool} was not sent: this call does not match the request the owner confirmed."
  end

  defp changed_text(tool) do
    "#{tool} did not run: the command changed since the owner was asked (it was removed, or " <>
      "its plugin was turned off, no longer marks it, or signs in under a different " <>
      "profile). Ask again."
  end

  defp refusal_text(:access_sensitive, reason, call),
    do: refusal_text(reason, call.capability.name)

  defp refusal_text(:sign_in, :sign_in_not_allowed, _call) do
    "Not signed in: Fermix signs in to a website only when the owner asks in their own " <>
      "chat or the Fermix app, never from a delegated worker, a cue, a scheduled job or a " <>
      "shared channel. Ask the owner to request the sign-in from their own chat or the " <>
      "Fermix app. (sign_in_not_allowed)"
  end

  defp refusal_text(:sign_in, :sign_in_not_on_voice, _call) do
    "Not signed in: a sign-in is not approved on a voice call. Tell the owner to ask for it " <>
      "in their own chat or the Fermix app, where they approve it. (sign_in_not_on_voice)"
  end

  # The host-command refusal names the same reason the park prompt would
  # (`reason_phrase/1`), so it never claims "came after content" when the only
  # taint is a shared channel or an unstamped context.
  defp refusal_text(:host_command, reason, %{capability: %{name: tool}} = call) do
    "#{tool} was not run: Fermix cannot sandbox commands here, and #{reason_phrase(call)}. " <>
      host_rule(reason, tool) <> chain_note(call)
  end

  # A follow-up turn's coding run is refused when it left the chain's folder or
  # read something else (`chained_run?/3`); say what would have run it.
  defp chain_note(%{capability: %{metadata: %{coding_run?: true}}, context: context}) do
    if follow_up_turn?(context) do
      " A coding run's follow-up turn starts the next run without asking only in that " <>
        "run's own starting folder, with the same coding agent, once per run, before it " <>
        "reads anything else, and carrying only its task, folder, model, effort and limits."
    else
      ""
    end
  end

  defp chain_note(_call), do: ""

  defp host_rule(:worker, _tool) do
    "A delegated worker never runs one after such content. Report that the owner must ask " <>
      "for it directly."
  end

  defp host_rule(:cue_run, _tool) do
    "A task woken by a cue never runs one. Report what you found; the owner can run it " <>
      "from their own chat."
  end

  defp host_rule(:unattended, _tool) do
    "After such content it runs only when the owner asks directly in their chat, the Fermix " <>
      "app or by voice, or from a scheduled job that names it."
  end

  defp host_rule(:not_allowlisted, tool) do
    "This scheduled job does not name it. The owner can recreate the job from their own " <>
      "chat and name #{tool} in its allowed tools."
  end

  defp host_rule(:no_surface, _tool) do
    "It needs the owner's confirmation and Fermix has no private chat to ask them on. Ask " <>
      "from the Fermix app or your own chat."
  end

  defp host_rule(:voice_surface, _tool) do
    "A voice call cannot show the owner the exact command, so it is not asked aloud. Tell " <>
      "the owner to ask for it from their own chat or the Fermix app."
  end

  defp refusal_text(:worker, tool) do
    "#{tool} was not sent: it never runs from a delegated worker. Report that the owner " <>
      "must ask for it directly."
  end

  defp refusal_text(:cue_run, tool) do
    "#{tool} was not sent: a task woken by a cue never runs an access-sensitive command. " <>
      "Report what you found; the owner can run it from their own chat."
  end

  defp refusal_text(:unattended, tool) do
    "#{tool} was not sent: it runs only when the owner asks directly in their chat, the " <>
      "Fermix app or by voice, or from a scheduled job that names it."
  end

  defp refusal_text(:not_allowlisted, tool) do
    "#{tool} was not sent: this scheduled job does not name it. The owner can recreate the " <>
      "job from their own chat and name #{tool} in its allowed tools."
  end

  defp refusal_text(:no_surface, tool) do
    "#{tool} was not sent: it needs the owner's confirmation and Fermix has no private chat " <>
      "to ask them on. Ask from the Fermix app, your own chat, or by voice."
  end

  defp job_refusal(tool) do
    "A scheduled job that may run #{tool} can be set up, changed or run now only when you " <>
      "ask directly, from your own chat, app or voice, in a request that has read nothing " <>
      "from outside. Ask again directly."
  end

  defp open_job_refusal do
    "A scheduled job with no allowed_tools, or one that can start a skill or manage jobs, " <>
      "can run commands Fermix cannot sandbox here, so it cannot be set up, changed or run " <>
      "now from a request that read content from outside. Name the tools the job needs in " <>
      "allowed_tools (no skill or job tools), or ask again in a request that has read " <>
      "nothing from outside."
  end
end
