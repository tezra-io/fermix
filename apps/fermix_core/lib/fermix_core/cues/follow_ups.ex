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
  (`[fermix_core.cues] mandates_enabled`, "Let watchers act") or a tool it
  names is not set up (`readiness/2`). A held trigger is refused with Fermix's
  sentence before its card goes out or its run starts (`check/3`), and the
  watcher sends one `:follow_up_held` notice per hold and one
  `:follow_up_recovered` when the follow-up next passes the check.

  ## The card

  `offer/2` hands a waiting trigger's card (`card/2`: the watcher, the
  follow-up and its instructions, tools and delivery, the item apart as
  outside text, the expiry) to the sender the channels application registers
  as `:cue_follow_up_sender` (`send_follow_up(card)`), which writes the message
  (`Cues.Card.follow_up/2`) and the token (`Cues.Proposals.new_token/0`) and
  answers where it went (`CuesFollowUpSql.binding()`): the token's digest and
  the chat that may answer it, or no chat when only an app can show it. A
  sender that fails, or no sender, refuses the trigger ("could not reach
  you"). A card that went out is offered to every app surface through
  `Cues.Proposals.announce/2` (`Cues.ProposalView.follow_up_card/2`), and its
  end is told there too.

  The owner answers by token from that chat (`confirm/3`, `deny/3`, which
  `Cues.Proposals` dispatches to), by id from an app (`decide/4`), or with a
  bare `/confirm` resolved through `waiting_in_chat/2`. A yes moves the
  trigger to `starting` and wakes the scheduler, unless the follow-up is
  running already: then it is refused at once, so the card says so (§4.2). A
  chat's answer is the one line the card becomes (`Cues.Card.running/2`); a
  card nobody answers expires after 30 minutes (`expire/3`, a `Cues.Sweeper`
  step).

  Seams (opts): `:repo`, `:now`, `:cues_config`, `:capability_registry`,
  `:follow_up_sender` (`fn card -> {:ok, binding} | {:error, reason} end`),
  `:notice` (`fn watcher_id, kind, data -> term end`), `:wake_scheduler`,
  `:proposal_listener` (`Cues.Proposals.announce/2`), and the `Cues.Notices`
  channel seams.
  """

  require Logger

  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Clock
  alias FermixCore.Cues
  alias FermixCore.Cues.Card
  alias FermixCore.Cues.Config
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
  @running "Not started: it is already running."
  @unread "Fermix recorded your answer but could not read the card back."
  @app_origins ["companion", "management"]
  @max_device_id_bytes 128

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
          watcher: %{id: String.t(), name: String.t() | nil},
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
  is off or a tool it names is not set up, else nil.
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
  Whether every tool follow-up `job` names is set up on this computer (§3.2):
  a tool whose command-line program was not found, or whose plugin is not
  installed, is not registered, and is named. The one check the setup and
  every trigger use.
  """
  @spec readiness(map(), keyword()) :: :ready | {:not_ready, String.t()}
  def readiness(%{allowed_tools: tools}, opts) when is_list(tools) and is_list(opts) do
    registry = Keyword.get(opts, :capability_registry, CapabilityRegistry)

    case Enum.reject(tools, &match?({:ok, _capability}, CapabilityRegistry.find(registry, &1))) do
      [] -> :ready
      missing -> {:not_ready, not_set_up(missing)}
    end
  end

  defp not_set_up([tool]),
    do:
      "#{tool} is not set up on this computer (its program was not found or its plugin is " <>
        "not installed)."

  defp not_set_up(tools),
    do:
      "#{Enum.join(tools, ", ")} are not set up on this computer (a program was not found " <>
        "or a plugin is not installed)."

  @doc """
  Checks trigger `trigger` against the hold before its card goes out or its
  run starts, with `job` its follow-up's job: held refuses it (from its state)
  with Fermix's sentence, traces it and asks `opts[:notice]` for the
  `:follow_up_held` notice; otherwise it asks for `:follow_up_recovered`, which
  goes only after a notified hold. Returns `:ready` or `:refused`.
  """
  @spec check(trigger(), map(), keyword()) :: :ready | :refused | {:error, term()}
  def check(%{id: id, watcher_id: watcher_id} = trigger, job, opts)
      when is_binary(id) and is_map(job) and is_list(opts) do
    notice = Keyword.fetch!(opts, :notice)

    case held(job, opts) do
      nil ->
        notice.(watcher_id, :follow_up_recovered, %{})
        :ready

      {label, sentence} ->
        with :refused <- refuse(trigger, label, sentence, opts) do
          notice.(watcher_id, :follow_up_held, %{reason: sentence})
          :refused
        end
    end
  end

  # --- the card -----------------------------------------------------------------------

  @doc """
  Offers waiting trigger `trigger` (claimed by the scheduler, `offered_at`
  set): checked against the hold, then its card handed to the registered
  sender, and where it went recorded. Runs in a task of its own: the send is a
  channel's.
  """
  @spec offer(trigger(), keyword()) :: :offered | :refused | {:error, term()}
  def offer(%{id: id, state: "waiting"} = trigger, opts) when is_binary(id) and is_list(opts) do
    opts = Keyword.put_new(opts, :notice, &Notices.watcher(&1, &2, &3, opts))

    with {:ok, job} <- trigger_job(trigger, opts),
         :ready <- check(trigger, job, opts) do
      send_card(trigger, opts)
    end
  end

  defp trigger_job(trigger, opts) do
    case JobsRegistry.get_job(trigger.job_id, registry_opts(opts)) do
      {:ok, job} ->
        {:ok, job}

      {:error, :not_found} ->
        with :refused <- refuse(trigger, "job_gone", @job_gone, opts), do: {:error, :job_gone}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_card(trigger, opts) do
    with {:ok, card} <- card(trigger.id, opts) do
      case guarded_send(sender(opts), card) do
        {:ok, binding} when is_map(binding) ->
          record_offer(trigger, card, binding, opts)

        {:error, reason} ->
          Logger.warning("Follow-up card #{trigger.id} was not sent: #{inspect(reason)}")
          refuse(trigger, "unreachable", @unreachable, opts)
      end
    end
  end

  # Recorded, then offered to every app surface, which hears its end too.
  defp record_offer(trigger, card, binding, opts) do
    case repo_call({:record_offer, trigger.id, binding, now(opts)}, opts) do
      {:ok, _offered} ->
        Proposals.announce({:offered, ProposalView.follow_up_card(card, opts)}, opts)
        :offered

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A sender that raises is a send that failed; its stacktrace is logged.
  defp guarded_send(nil, _card), do: {:error, :no_follow_up_sender}

  defp guarded_send(send_fun, card) do
    send_fun.(card)
  catch
    kind, reason ->
      Logger.error(
        "The follow-up sender crashed: " <>
          (kind |> Exception.format(reason, __STACKTRACE__) |> String.slice(0, 4_000))
      )

      {:error, {:sender_crashed, kind}}
  end

  # The channels application registers its sender module; nil while it is not
  # running (a tree-less CLI, a test of core alone).
  defp sender(opts) do
    Keyword.get_lazy(opts, :follow_up_sender, fn ->
      case Application.get_env(:fermix_core, :cue_follow_up_sender) do
        nil -> nil
        module when is_atom(module) -> &module.send_follow_up/1
      end
    end)
  end

  @doc """
  What trigger `trigger_id`'s card shows (§6.1, §6.2): Fermix's fields, and
  the item and the filter's reason apart, in `outside`.
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
         {:ok, target} <- decoded(row.delivery_target, nil) do
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
         watcher: %{id: row.watcher_id, name: row.watcher_name},
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
  The owner's yes by token from `origin` (`%{platform, chat_id, user_id}`):
  one Repo call fenced on the token's digest, `waiting`, the chat it went to
  and the expiry moves the trigger to `starting`, and the scheduler is woken
  to start it. Returns the one line the card becomes.
  """
  @spec confirm(String.t(), map(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def confirm(token, origin, opts \\ []) when is_binary(token) and is_map(origin) do
    case repo_call({:confirm, Proposals.digest(token), origin, now(opts)}, opts) do
      {:ok, trigger} -> trigger |> decided(:confirm, origin.platform, opts) |> answered(opts)
      {:error, why} -> {:error, refusal_reply(why)}
    end
  end

  @doc "The owner's no by token from `origin`: `waiting → skipped`. Returns the card's line."
  @spec deny(String.t(), map(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def deny(token, origin, opts \\ []) when is_binary(token) and is_map(origin) do
    case repo_call({:deny, Proposals.digest(token), origin, now(opts)}, opts) do
      {:ok, trigger} -> trigger |> decided(:deny, origin.platform, opts) |> answered(opts)
      {:error, why} -> {:error, refusal_reply(why)}
    end
  end

  @doc """
  An answer by id from one of the owner's apps or from a chat whose waiting
  card `waiting_in_chat/2` resolved: `origin_label` is where it came from
  (`companion`, `management`, `mobile:<device>`, or a chat's
  `<platform>:<chat>:<user>`). Fenced on `waiting` and the expiry, so the first
  answer from any surface wins. Returns the trigger as it now is.
  """
  @spec decide(String.t(), :confirm | :deny, String.t(), keyword()) ::
          {:ok, trigger()} | {:error, String.t()}
  def decide(trigger_id, decision, origin_label, opts \\ [])
      when is_binary(trigger_id) and decision in [:confirm, :deny] and is_binary(origin_label) do
    with :ok <- known_origin(origin_label) do
      request = {:decide, trigger_id, to_state(decision), origin_label, now(opts)}

      case repo_call(request, opts) do
        {:ok, trigger} -> {:ok, decided(trigger, decision, origin_kind(origin_label), opts)}
        {:error, why} -> {:error, refusal_reply(why)}
      end
    end
  end

  @doc """
  The one line a decided card becomes (§3.3): running, skipped, or Fermix's
  sentence for a trigger refused at the owner's yes.
  """
  @spec answered(trigger(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def answered(%{state: "refused", reason: reason}, _opts) when is_binary(reason),
    do: {:ok, reason}

  def answered(%{id: id, state: state}, opts) when is_list(opts) do
    case card(id, opts) do
      {:ok, card} when state == "skipped" -> {:ok, Card.skipped(card)}
      {:ok, card} -> {:ok, Card.running(card, opts)}
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
    do: repo_call({:waiting_in_chat, origin, now(opts)}, opts)

  @doc """
  The card of every follow-up still waiting that went out, oldest first, as an
  app shows it: what an app that connects is offered.
  """
  @spec waiting_cards(pos_integer(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def waiting_cards(limit, opts \\ []) when is_integer(limit) and limit > 0 and is_list(opts) do
    with {:ok, rows} <- repo_call({:waiting_cards, now(opts), limit}, opts),
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

  # Traced; a yes starts the follow-up unless it runs already (then it is
  # refused here, so the owner's card says so); every app surface hears the
  # end. Returns the trigger as it now is.
  defp decided(trigger, decision, kind, opts) do
    Telemetry.lifecycle(:follow_up_decided, %{}, %{
      trigger_id: trigger.id,
      watcher_id: trigger.watcher_id,
      delivery_id: trigger.delivery_id,
      cue_id: trigger.cue_id,
      job_id: trigger.job_id,
      state: trigger.state,
      decision: decision,
      kind: kind
    })

    trigger = if decision == :confirm, do: start(trigger, opts), else: trigger
    announce_end(trigger, opts)
    trigger
  end

  defp start(trigger, opts) do
    case JobsRegistry.get_job(trigger.job_id, registry_opts(opts)) do
      {:ok, %{state: "running"}} -> refuse_running(trigger, opts)
      _idle_or_gone -> wake(trigger, opts)
    end
  end

  # The scheduler may have taken it meanwhile (`:stale`): it starts or is
  # refused there, as any starting trigger is.
  defp refuse_running(trigger, opts) do
    case repo_call({:refuse, trigger.id, ["starting"], @running}, opts) do
      {:ok, refused} ->
        emit_refused(refused, "already_running")
        refused

      {:error, reason} ->
        Logger.info("Follow-up #{trigger.id} left to the scheduler: #{inspect(reason)}")
        trigger
    end
  end

  defp wake(trigger, opts) do
    Keyword.get(opts, :wake_scheduler, &Cues.wake_scheduler/0).()
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

  defp end_sentence(%{state: state}) when state in ["starting", "started"],
    do: "Confirmed; the follow-up is starting."

  defp end_sentence(%{state: "skipped"}), do: "Skipped; the follow-up did not run."
  defp end_sentence(%{state: "expired"}), do: "That card expired; nothing ran."
  defp end_sentence(%{reason: reason}) when is_binary(reason), do: reason

  defp to_state(:confirm), do: "starting"
  defp to_state(:deny), do: "skipped"

  # Where an answer by id may come from: an app, a phone, or a chat's origin.
  defp known_origin(label) when label in @app_origins, do: :ok

  defp known_origin("mobile:" <> device)
       when device != "" and byte_size(device) <= @max_device_id_bytes,
       do: :ok

  defp known_origin(label) do
    case String.split(label, ":", parts: 3) do
      [platform, chat, user] when platform != "" and chat != "" and user != "" -> :ok
      _other -> {:error, "Fermix does not know where that answer came from; nothing changed."}
    end
  end

  defp origin_kind(label), do: label |> String.split(":", parts: 2) |> hd()

  defp refusal_reply(:unknown), do: "That card is not known to Fermix; nothing ran."
  defp refusal_reply(:wrong_origin), do: "Answer it from the chat Fermix sent it to; nothing ran."
  defp refusal_reply(:expired), do: "That card expired; nothing ran."
  defp refusal_reply({:not_waiting, "starting"}), do: "That follow-up is already starting."
  defp refusal_reply({:not_waiting, "started"}), do: "That follow-up already ran."
  defp refusal_reply({:not_waiting, "skipped"}), do: "That card was skipped; nothing ran."
  defp refusal_reply({:not_waiting, "expired"}), do: "That card expired; nothing ran."
  defp refusal_reply({:not_waiting, "refused"}), do: "That card was refused; nothing ran."
  defp refusal_reply(:disabled), do: "Cues keep their records in memory, which is off."

  defp refusal_reply(reason) do
    Logger.error("Follow-up answer failed: #{inspect(reason)}")
    "Fermix could not read that card; nothing ran."
  end

  # --- refusal, expiry --------------------------------------------------------------------

  defp refuse(trigger, label, sentence, opts) do
    case repo_call({:refuse, trigger.id, [trigger.state], sentence}, opts) do
      {:ok, refused} ->
        emit_refused(refused, label)
        :refused

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
    with {:ok, expired} <- Repo.cues_call(CuesFollowUpSql, {:expire, now, limit}, repo_opts) do
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
    metadata =
      %{
        trigger_id: trigger.id,
        watcher_id: trigger.watcher_id,
        delivery_id: trigger.delivery_id,
        cue_id: trigger.cue_id,
        job_id: trigger.job_id,
        state: trigger.state,
        kind: trigger.mode
      }
      |> Map.merge(extra)
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    Telemetry.lifecycle(phase, %{}, metadata)
  end

  # --- plumbing -----------------------------------------------------------------------

  defp repo_call(request, opts) do
    repo_opts =
      [server: Keyword.get(opts, :repo, Repo)] ++ Keyword.take(opts, [:timeout, :on_timeout])

    Repo.cues_call(CuesFollowUpSql, request, repo_opts)
  end

  defp registry_opts(opts),
    do: [repo: Keyword.get(opts, :repo, Repo)] ++ Keyword.take(opts, [:timeout, :on_timeout])

  defp now(opts), do: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

  defp cues_config(opts),
    do:
      Keyword.get_lazy(opts, :cues_config, fn -> Application.get_env(:fermix_core, :cues, []) end)
end
