defmodule FermixCore.Cues.FollowUps do
  @moduledoc """
  A watcher's follow-up triggers (M60_WATCHER_CODING_RUNS.md §4.3–§4.6): the
  card that asks the owner first, the owner's answer, the hold, the expiry,
  and what a follow-up's run is told. Rows live in `cue_follow_up_triggers`
  through `Memory.Repo.CuesFollowUpSql`; a trigger is written by the pass that
  passed its item (`CuesFollowUpSql.on_pass/3`), and `Jobs.Scheduler` moves it
  on: it offers each new card (`offer/2`) and admits each `starting` trigger
  in the cue share of its run slots (`Jobs.CueAdmission`), never through the
  manual run path.

  ## Held (§4.6)

  A follow-up is held while the owner's one switch stops every watcher action
  (`[fermix_core.cues] mandates_enabled`, "Let watchers act") or it is not
  ready (`readiness/2`, `Cues.FollowUpReadiness`: a tool it names is not set
  up, a folder its instructions name is outside the sandbox's roots, or the
  channel it reports to is not set up). A held trigger is refused with
  Fermix's sentence before its card goes out or its run starts (`check/3`),
  and the watcher sends one `:follow_up_held` notice per hold and one
  `:follow_up_recovered` when the follow-up next passes the check.

  ## The card

  `offer/2` hands a waiting trigger's card (`card/2`: the watcher and what
  sets it off, the follow-up and its instructions, tools and delivery, the
  item apart as outside text, the expiry) to the sender
  (`Cues.FollowUpCards.send_card/2`), which writes the message
  (`Cues.Card.follow_up/2`) and the token (`Cues.Proposals.new_token/0`) and
  answers where it went (`CuesFollowUpSql.binding()`): the token's digest and
  the chat that may answer it, or no chat when only an app can show it. Where
  it went is recorded with the digest of what the card showed, read with the
  card. A sender that fails, or no sender, refuses the trigger ("could not
  reach you"). A card that went out is offered to every app surface through
  `Cues.Proposals.announce/2` (`Cues.ProposalView.follow_up_card/2`), and its
  end is told there too. An offer runs in a task nobody answers, so one that
  fails is logged and traced there.

  The owner answers Run, Skip or Always allow: by token from that chat
  (`confirm/3`, `deny/3`, `always_allow/3`, which `Cues.Proposals` dispatches
  to), by id from an app (`decide/4`), or with a bare command resolved
  through `waiting_in_chat/2`. Run moves the trigger to `starting` and wakes
  the scheduler, and a chat's card becomes the one line saying it is starting
  (`Cues.Card.starting/2`). Always allow does the same and, in that one write,
  allows the follow-up for what the card showed, so later items run it with
  no card until what it runs or what sets it off changes; one whose follow-up
  changed since the card was shown allows nothing, and its line says so. A
  card nobody answers expires after 30 minutes (`expire/3`, a `Cues.Sweeper`
  step).

  ## Refused at its turn

  The scheduler's claim refuses a `starting` trigger it cannot start (held,
  its job paused or gone, or its follow-up still running, §4.2), and hands it
  to `refused/3`: traced, and, when the owner confirmed it, its end told to
  every app surface and its sentence sent through the follow-up's delivery,
  so a run the owner was told is starting never ends in silence.

  Seams (opts): `:repo`, `:now`, `:cues_config`, `:capability_registry`,
  `:follow_up_sender` (`fn card -> {:ok, binding} | {:error, reason} end`),
  `:notice` (`fn watcher_id, kind, data -> term end`), `:wake_scheduler`,
  `:proposal_listener` (`Cues.Proposals.announce/2`), the `Cues.Notices`
  channel seams, and `Cues.FollowUpReadiness`' seams.
  """

  require Logger

  alias FermixCore.Clock
  alias FermixCore.Cues
  alias FermixCore.Cues.Card
  alias FermixCore.Cues.Config
  alias FermixCore.Cues.FollowUpCards
  alias FermixCore.Cues.FollowUpReadiness
  alias FermixCore.Cues.Notices
  alias FermixCore.Cues.Proposals
  alias FermixCore.Cues.ProposalView
  alias FermixCore.Cues.Telemetry
  alias FermixCore.Jobs.Registry, as: JobsRegistry
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesFollowUpSql

  @switch_off "Watchers may not act: \"Let watchers act\" is off in settings."
  @unreachable "Fermix could not reach you, so the card was not sent."
  @job_gone "Not started: the follow-up's job is gone."
  @unread "Fermix recorded your answer but could not read the card back."

  @typedoc "A trigger as `CuesFollowUpSql` reads it."
  @type trigger :: CuesFollowUpSql.trigger()
  @typedoc "Why a follow-up is held: a short label for traces and Fermix's sentence."
  @type hold :: {String.t(), String.t()}

  @typedoc """
  What a card shows (§6.1): Fermix's own fields, and `outside`, the item and
  the filter's reason, which an outsider's text decided, kept apart.
  """
  @type card :: %{
          trigger_id: String.t(),
          state: String.t(),
          mode: String.t(),
          reason: String.t() | nil,
          created_at: DateTime.t(),
          expires_at: DateTime.t() | nil,
          decided_at: DateTime.t() | nil,
          decided_from: String.t() | nil,
          run_id: String.t() | nil,
          always_allow: String.t() | nil,
          digest: String.t() | nil,
          watcher: %{
            id: String.t(),
            name: String.t() | nil,
            sources: [String.t()],
            listen_for: [String.t()]
          },
          follow_up: %{
            job_id: String.t(),
            name: String.t() | nil,
            instructions: String.t() | nil,
            tools: [String.t()],
            delivery: %{mode: String.t() | nil, target: map() | nil}
          },
          outside: %{
            source_ref: String.t() | nil,
            received_at: DateTime.t() | nil,
            occurred_at: DateTime.t() | nil,
            type: String.t() | nil,
            subject: String.t() | nil,
            text: String.t() | nil,
            reason: String.t() | nil
          }
        }

  # --- the hold ---------------------------------------------------------------------

  @doc """
  Whether follow-up `job` is held (§4.6): `{label, sentence}` while the switch
  is off or it is not ready (`readiness/2`), else nil.
  """
  @spec held(map(), keyword()) :: hold() | nil
  def held(%{allowed_tools: tools} = job, opts) when is_list(tools) and is_list(opts) do
    if Config.mandates_enabled?(cues_config(opts)) do
      case readiness(job, opts) do
        :ready -> nil
        {:not_ready, sentence} -> {"not_ready", sentence}
      end
    else
      {"switch_off", @switch_off}
    end
  end

  @doc """
  Whether follow-up `job` can run now (§3.2, `Cues.FollowUpReadiness`): every
  tool it names set up on this computer, in its family's words where it has
  them (a coding agent, a plugin), every folder its instructions name inside
  the sandbox's roots, and the channel it reports to set up. The one check the
  setup and every trigger use.
  """
  @spec readiness(map(), keyword()) :: :ready | {:not_ready, String.t()}
  def readiness(%{allowed_tools: tools} = job, opts) when is_list(tools) and is_list(opts),
    do: FollowUpReadiness.check(job, opts)

  @doc """
  Checks trigger `trigger` against the hold before its card goes out or its
  run starts, with `job` its follow-up's job: held refuses it (from its state)
  with Fermix's sentence and asks `opts[:notice]` for the `:follow_up_held`
  notice, answering the refused trigger and its label for `refused/3`;
  otherwise it asks for `:follow_up_recovered`, which goes only after a
  notified hold, and answers `:ready`.
  """
  @spec check(trigger(), map(), keyword()) ::
          :ready | {:refused, trigger(), String.t()} | {:error, term()}
  def check(%{id: id, watcher_id: watcher_id} = trigger, job, opts)
      when is_binary(id) and is_map(job) and is_list(opts) do
    notice = Keyword.fetch!(opts, :notice)

    case held(job, opts) do
      nil ->
        notice.(watcher_id, :follow_up_recovered, %{})
        :ready

      {label, sentence} ->
        with {:ok, refused} <- refuse(trigger, sentence, opts) do
          notice.(watcher_id, :follow_up_held, %{reason: sentence})
          {:refused, refused, label}
        end
    end
  end

  # --- the card -----------------------------------------------------------------------

  @doc """
  Offers waiting trigger `trigger` (claimed by the scheduler, `offered_at`
  set): checked against the hold, then its card handed to the sender, and
  where it went recorded. Runs in a task of its own, which nobody answers, so
  an offer that fails is logged and traced here before it returns.
  """
  @spec offer(trigger(), keyword()) :: :offered | :refused | {:error, term()}
  def offer(%{id: id, state: "waiting"} = trigger, opts) when is_binary(id) and is_list(opts) do
    opts = Keyword.put_new(opts, :notice, &Notices.watcher(&1, &2, &3, opts))
    trigger |> offer_card(opts) |> offered(trigger, opts)
  end

  defp offer_card(trigger, opts) do
    with {:ok, job} <- trigger_job(trigger, opts),
         :ready <- check(trigger, job, opts),
         do: send_card(trigger, opts)
  end

  defp offered({:refused, refused, label}, _trigger, opts), do: refused(refused, label, opts)

  defp offered({:error, reason}, trigger, _opts) do
    trace_error(:follow_up_offer, trigger, reason)
    Logger.error("Follow-up card #{trigger.id} was not offered: #{inspect(reason)}")
    {:error, reason}
  end

  defp offered(done, _trigger, _opts) when done in [:offered, :refused], do: done

  defp trigger_job(trigger, opts) do
    case JobsRegistry.get_job(trigger.job_id, registry_opts(opts)) do
      {:ok, job} -> {:ok, job}
      {:error, :not_found} -> refused_as(trigger, "job_gone", @job_gone, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp send_card(trigger, opts) do
    with {:ok, card} <- card(trigger.id, opts) do
      case FollowUpCards.send_card(card, opts) do
        {:ok, binding} when is_map(binding) ->
          record_offer(trigger, card, binding, opts)

        {:error, reason} ->
          Logger.warning("Follow-up card #{trigger.id} was not sent: #{inspect(reason)}")
          refused_as(trigger, "unreachable", @unreachable, opts)
      end
    end
  end

  # Recorded with the digest of what the card showed, then offered to every
  # app surface, which hears its end too.
  defp record_offer(trigger, card, binding, opts) do
    request = {:record_offer, trigger.id, binding, card.digest, FollowUpCards.now(opts)}

    case repo_call(request, opts) do
      {:ok, _offered} ->
        Proposals.announce({:offered, ProposalView.follow_up_card(card, opts)}, opts)
        :offered

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  What trigger `trigger_id`'s card shows (§6.1, §6.2): Fermix's fields, the
  digest of what it shows now (`digest`, nil once the watcher or its
  follow-up is gone), and the item and the filter's reason apart, in
  `outside`.
  """
  @spec card(String.t(), keyword()) :: {:ok, card()} | {:error, :not_found | term()}
  def card(trigger_id, opts \\ []) when is_binary(trigger_id) and is_list(opts) do
    case repo_call({:card, trigger_id}, opts) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, row} -> card_of(row)
      {:error, reason} -> {:error, reason}
    end
  end

  defp card_of(row) do
    with {:ok, tools} <- decoded(row.allowed_tools, []),
         {:ok, target} <- decoded(row.delivery_target, nil),
         {:ok, sources} <- decoded(row.sources, []),
         {:ok, words} <- decoded(row.listen_for, []) do
      {:ok,
       %{
         trigger_id: row.id,
         state: row.state,
         mode: row.mode,
         reason: row.reason,
         created_at: row.created_at,
         expires_at: row.expires_at,
         decided_at: row.decided_at,
         decided_from: row.decided_from,
         run_id: row.run_id,
         always_allow: row.always_allow,
         digest: row.digest,
         watcher: %{
           id: row.watcher_id,
           name: row.watcher_name,
           sources: sources || [],
           listen_for: words || []
         },
         follow_up: %{
           job_id: row.job_id,
           name: row.job_name,
           instructions: row.task_prompt,
           tools: tools,
           delivery: %{mode: row.delivery_mode, target: target}
         },
         outside: outside(row)
       }}
    end
  end

  defp outside(row) do
    item = snapshot_fields(row.snapshot)

    %{
      source_ref: row.source_ref,
      received_at: row.received_at,
      occurred_at: row.occurred_at,
      type: item["type"],
      subject: item["subject"],
      text: item["text"],
      reason: row.decision_reason
    }
  end

  defp snapshot_fields(nil), do: %{}

  defp snapshot_fields(snapshot) do
    case Jason.decode(snapshot) do
      {:ok, %{} = fields} -> Map.take(fields, ["type", "subject", "text"])
      _not_json -> %{"text" => snapshot}
    end
  end

  defp decoded(nil, default), do: {:ok, default}

  defp decoded(json, _default) do
    case Jason.decode(json) do
      {:ok, value} -> {:ok, value}
      {:error, _reason} -> {:error, :corrupt_job_row}
    end
  end

  # --- answers -----------------------------------------------------------------------

  @doc """
  The owner's Run by token from `origin` (`%{platform, chat_id, user_id}`):
  one Repo call fenced on the token's digest, `waiting`, the chat it went to
  and the expiry moves the trigger to `starting`, and the scheduler is woken
  to start it. Returns the one line the card becomes.
  """
  @spec confirm(String.t(), map(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def confirm(token, origin, opts \\ []) when is_binary(token) and is_map(origin),
    do: answer_by_token(token, origin, :confirm, opts)

  @doc "The owner's Skip by token from `origin`: `waiting → skipped`. Returns the card's line."
  @spec deny(String.t(), map(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def deny(token, origin, opts \\ []) when is_binary(token) and is_map(origin),
    do: answer_by_token(token, origin, :deny, opts)

  @doc """
  The owner's Always allow by token from `origin`: Run's write, which in the
  same transaction allows the follow-up for the digest the card showed, so
  later items run it with no card. Allows nothing when the follow-up or what
  sets it off changed since the card was shown; the run starts either way.
  Returns the card's line, which says which.
  """
  @spec always_allow(String.t(), map(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def always_allow(token, origin, opts \\ []) when is_binary(token) and is_map(origin),
    do: answer_by_token(token, origin, :always_allow, opts)

  defp answer_by_token(token, origin, decision, opts) do
    request = {:answer, Proposals.digest(token), origin, decision, FollowUpCards.now(opts)}

    case repo_call(request, opts) do
      {:ok, trigger} -> trigger |> decided(decision, origin.platform, opts) |> answered(opts)
      {:error, why} -> {:error, FollowUpCards.refusal_reply(why)}
    end
  end

  @doc """
  An answer by id (`:confirm`, `:deny` or `:always_allow`) from one of the
  owner's apps or from a chat whose waiting card `waiting_in_chat/2`
  resolved: `origin_label` is where it came from (`companion`, `management`,
  `mobile:<device>`, or a chat's `<platform>:<chat>:<user>`). Fenced on
  `waiting` and the expiry, so the first answer from any surface wins.
  Returns the trigger as it now is, its `always_allow` saying what an Always
  allow came to.
  """
  @spec decide(String.t(), :confirm | :deny | :always_allow, String.t(), keyword()) ::
          {:ok, trigger()} | {:error, String.t()}
  def decide(trigger_id, decision, origin_label, opts \\ [])
      when is_binary(trigger_id) and decision in [:confirm, :deny, :always_allow] and
             is_binary(origin_label) do
    with :ok <- FollowUpCards.known_origin(origin_label) do
      request = {:decide, trigger_id, decision, origin_label, FollowUpCards.now(opts)}

      case repo_call(request, opts) do
        {:ok, trigger} ->
          {:ok, decided(trigger, decision, FollowUpCards.origin_kind(origin_label), opts)}

        {:error, why} ->
          {:error, FollowUpCards.refusal_reply(why)}
      end
    end
  end

  @doc """
  The one line a decided card becomes (§3.3): starting, naming the item and,
  after Always allow, whether it runs with no card from now on; or skipped. A
  run refused when its turn comes is told by `refused/3`.
  """
  @spec answered(trigger(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def answered(%{id: id, state: state}, opts) when is_list(opts) do
    case card(id, opts) do
      {:ok, card} when state == "skipped" -> {:ok, Card.skipped(card)}
      {:ok, card} -> {:ok, Card.starting(card, opts)}
      {:error, reason} -> unread(id, reason)
    end
  end

  defp unread(id, reason) do
    Logger.error("Follow-up #{id} decided, then not read back: #{inspect(reason)}")
    {:error, @unread}
  end

  @doc """
  The cards waiting in the chat `origin` (`%{platform, chat_id, user_id}`),
  oldest first: what a bare `/confirm` or `/deny` from it resolves to.
  """
  @spec waiting_in_chat(map(), keyword()) :: {:ok, [trigger()]} | {:error, term()}
  def waiting_in_chat(origin, opts \\ []) when is_map(origin) and is_list(opts),
    do: repo_call({:waiting_in_chat, origin, FollowUpCards.now(opts)}, opts)

  @doc """
  The card of every follow-up still waiting that went out, oldest first, as an
  app shows it: what an app that connects is offered.
  """
  @spec waiting_cards(pos_integer(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def waiting_cards(limit, opts \\ []) when is_integer(limit) and limit > 0 and is_list(opts) do
    with {:ok, rows} <- repo_call({:waiting_cards, FollowUpCards.now(opts), limit}, opts),
         do: collect(rows, &app_card(&1, opts))
  end

  defp app_card(row, opts) do
    with {:ok, card} <- card_of(row), do: {:ok, ProposalView.follow_up_card(card, opts)}
  end

  defp collect(rows, fun) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, done} ->
      case fun.(row) do
        {:ok, value} -> {:cont, {:ok, done ++ [value]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # Traced, an Always allow with what it came to; a run wakes the scheduler,
  # whose claim starts it or refuses it (`refused/3`); every app surface hears
  # the end. Returns the trigger.
  defp decided(trigger, decision, kind, opts) do
    Telemetry.lifecycle(
      :follow_up_decided,
      %{},
      Map.merge(trigger_ids(trigger), %{
        state: trigger.state,
        decision: decision,
        kind: kind,
        outcome: trigger.always_allow
      })
    )

    if decision != :deny, do: Keyword.get(opts, :wake_scheduler, &Cues.wake_scheduler/0).()
    announce_end(trigger, opts)
    trigger
  end

  defp announce_end(trigger, opts) do
    resolved = %{
      proposal_id: trigger.id,
      state: ProposalView.follow_up_state(trigger.state),
      result_status: nil,
      sentence: end_sentence(trigger),
      result_text: nil
    }

    Proposals.announce({:resolved, resolved}, opts)
  end

  defp end_sentence(%{state: state, always_allow: "allowed"})
       when state in ["starting", "started"],
       do: "Confirmed; the follow-up is starting, and runs with no card from now on."

  defp end_sentence(%{state: state, always_allow: "changed"})
       when state in ["starting", "started"],
       do:
         "Confirmed; the follow-up is starting. It changed since this card was shown, so it " <>
           "still asks first."

  defp end_sentence(%{state: state}) when state in ["starting", "started"],
    do: "Confirmed; the follow-up is starting."

  defp end_sentence(%{state: "skipped"}), do: "Skipped; the follow-up did not run."
  defp end_sentence(%{state: "expired"}), do: "That card expired; nothing ran."
  defp end_sentence(%{reason: reason}) when is_binary(reason), do: reason

  # --- refusal, expiry --------------------------------------------------------------------

  @doc """
  Ends trigger `trigger`, refused before it could start (held, its job paused
  or gone, already running, or its card not sent; `label` says which, for the
  trace), with Fermix's sentence in `reason`: traced, and, when the owner had
  confirmed it, so their tap said it was starting, its end told to every app
  surface and its sentence sent through the follow-up's delivery
  (`Cues.Notices.follow_up_not_started/3`, which logs a send that fails).
  Returns `:refused`.
  """
  @spec refused(trigger(), String.t(), keyword()) :: :refused
  def refused(%{state: "refused", reason: reason} = trigger, label, opts)
      when is_binary(reason) and is_binary(label) and is_list(opts) do
    emit_refused(trigger, label)
    if trigger.decided_at, do: not_started(trigger, opts)
    :refused
  end

  defp not_started(trigger, opts) do
    announce_end(trigger, opts)

    case card(trigger.id, opts) do
      {:ok, card} ->
        Notices.follow_up_not_started(trigger.job_id, Card.not_started(card), opts)

      {:error, reason} ->
        Logger.error(
          "Follow-up #{trigger.id} did not start, and its card was not read to say so: " <>
            inspect(reason)
        )
    end
  end

  # Refused, then ended as every refused trigger is.
  defp refused_as(trigger, label, sentence, opts) do
    with {:ok, refused} <- refuse(trigger, sentence, opts), do: refused(refused, label, opts)
  end

  defp refuse(trigger, sentence, opts) do
    case repo_call({:refuse, trigger.id, [trigger.state], sentence}, opts) do
      {:ok, refused} ->
        {:ok, refused}

      {:error, :stale} ->
        {:error, :stale}

      {:error, reason} ->
        Logger.error("Follow-up trigger #{trigger.id} was not refused: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  The `Cues.Sweeper` step: waiting cards past their expiry become `expired`;
  nothing runs. Each is traced.
  """
  @spec expire(keyword(), DateTime.t(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def expire(repo_opts, %DateTime{} = now, limit)
      when is_list(repo_opts) and is_integer(limit) and limit > 0 do
    # A claim the next pass makes again: one the Repo reaches after this call
    # gave up is skipped, so no card expires that nobody announces.
    claim_opts = Keyword.put(repo_opts, :skip_when_late, true)

    with {:ok, expired} <- Repo.cues_call(CuesFollowUpSql, {:expire, now, limit}, claim_opts) do
      Enum.each(expired, fn trigger ->
        emit(:follow_up_expired, trigger, %{})
        announce_end(trigger, repo_opts)
      end)

      {:ok, length(expired)}
    end
  end

  # --- the run ------------------------------------------------------------------------

  @doc """
  The trigger that started run `run_id` and its watcher's name, for the run's
  prompt and trace; nil for a run no trigger started.
  """
  @spec run_trigger(String.t(), keyword()) ::
          {:ok, %{trigger: trigger(), watcher_name: String.t() | nil} | nil} | {:error, term()}
  def run_trigger(run_id, opts \\ []) when is_binary(run_id) and is_list(opts),
    do: repo_call({:run_trigger, run_id}, opts)

  @doc """
  The one line a follow-up's run is told beyond its job's prompt (§4.2): which
  watcher set it off and when, in the owner's time. Nothing of the item.
  """
  @spec run_line(String.t() | nil, DateTime.t(), keyword()) :: String.t()
  def run_line(watcher_name, %DateTime{} = at, opts \\ []) when is_list(opts) do
    "Watcher #{watcher_name || "(removed)"} set this off at #{Clock.stated_time(at, opts)}."
  end

  # --- traces -------------------------------------------------------------------------

  @doc """
  Traces the trigger a pass wrote (`CuesFollowUpSql.on_pass/3`), after its
  transaction committed; nil (no follow-up) traces nothing. `source_ref` is the
  pass's source.
  """
  @spec emit_triggered(map() | nil, String.t() | nil) :: :ok
  def emit_triggered(nil, _source_ref), do: :ok

  def emit_triggered(%{id: _id, code: code} = trigger, source_ref) do
    outcome = if Map.get(trigger, :settled_delivery?), do: "follow_up"
    emit(:follow_up_triggered, trigger, %{reason: code, outcome: outcome, source_ref: source_ref})
  end

  @doc "Traces a trigger refused (held, or not runnable at its turn) with its `label`."
  @spec emit_refused(trigger(), String.t()) :: :ok
  def emit_refused(trigger, label) when is_binary(label),
    do: emit(:follow_up_refused, trigger, %{reason: label})

  @doc "Traces a trigger's run starting, inside the run's session."
  @spec emit_started(trigger(), map()) :: :ok
  def emit_started(trigger, %{id: run_id, session_id: session_id}),
    do: emit(:follow_up_started, trigger, %{run_id: run_id, session_id: session_id})

  defp emit(phase, trigger, extra) do
    trigger
    |> trigger_ids()
    |> Map.merge(%{state: trigger.state, kind: trigger.mode})
    |> Map.merge(extra)
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
    |> then(&Telemetry.lifecycle(phase, %{}, &1))
  end

  # A step on a trigger that failed, on the cues' error path (`sweep_error`).
  defp trace_error(step, trigger, reason) do
    metadata = Map.merge(trigger_ids(trigger), %{reason: step, result: {:error, reason}})
    Telemetry.lifecycle(:sweep_error, %{}, metadata)
  end

  defp trigger_ids(trigger) do
    %{
      trigger_id: trigger.id,
      watcher_id: trigger.watcher_id,
      delivery_id: trigger.delivery_id,
      cue_id: trigger.cue_id,
      job_id: trigger.job_id
    }
  end

  # --- plumbing -----------------------------------------------------------------------

  defp repo_call(request, opts), do: FollowUpCards.repo_call(CuesFollowUpSql, request, opts)

  defp registry_opts(opts),
    do: [repo: Keyword.get(opts, :repo, Repo)] ++ Keyword.take(opts, [:timeout, :on_timeout])

  defp cues_config(opts),
    do:
      Keyword.get_lazy(opts, :cues_config, fn -> Application.get_env(:fermix_core, :cues, []) end)
end
