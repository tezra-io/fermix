defmodule FermixCore.Cues.Proposals do
  @moduledoc """
  Proposals: a mandate's `approve` mode (M60 §10.9, PLAN §1 fixes).

  A cue run's mandate call that passes every check is stored as a proposal in
  the same Repo call that records the decision (`Cues.MandateGate`), with the
  digest of a fresh random token (`cp_` and 32 url-safe characters; only the
  digest is stored, and the model never sees the token). Fermix then sends it to
  the owner's DM through the gateway's approval delivery (a one-tap button on
  Telegram, the tap-to-copy command elsewhere) and records where it went. A
  message that would be over 3,500 characters is refused before anything is
  stored, never cut; a send that fails marks the proposal `refused` ("could not
  reach you").

  `confirm/3` accepts a token only from the chat it was sent to: one Repo call
  moves the proposal `waiting → confirmed`, fenced on the token, that chat and
  the expiry, so a second tap or a confirm after a restart runs nothing. Then
  the switches, the pin check and the validator run again, and the executor
  runs exactly the recorded call, with no model, under the proposing run's
  `session_id` and `access_gate` `confirmed`. A crash between the confirm and
  the result leaves `confirmed` with no result: `report_unknown/3` tells the
  owner once that the outcome is unknown, and it is never run again. `deny/3`
  and the expiry sweep (`expire/3`) run nothing.

  The gateway reaches this module from `/confirm` and `/deny`, and the proposal
  goes out through the sender the channels application registers as
  `:cue_proposal_sender` (`send_cue_proposal(inbox, text, token)`); core never
  depends on channels code. No sender registered means the proposal cannot
  reach the owner's chat.

  ## The owner's devices (M60 app surface §3.7, D28)

  Every waiting proposal is also offered to every app surface, and the first
  answer from any surface wins. `records/2`, `card/2` and `waiting_cards/1`
  read what an app shows (`Cues.ProposalView`: Fermix's record, and the card
  with the outside text apart). `decide/4` is the second entry beside
  `confirm/3` and `deny/3`, for an answer from the Mac app's socket, a paired
  phone or the management socket: the transport authenticated the device, so
  it answers by id, one Repo call fenced on the id, `waiting` and the expiry,
  recording `decided_from` (`companion`, `mobile:<device>`, `management`).
  After it the path is the same: a denial runs nothing; a confirm re-checks
  the switches, the pins, the grant and the validator and runs exactly the
  recorded call, once, with no model, in a task of its own, so `decide/4`
  answers as soon as the decision is recorded. The token stays the direct
  chat's binding.

  **Reach.** Approve mode asks the owner somewhere: the owner's chat, or an app
  (`Cues.Mandates.app_surface?/1`). With an app, a proposal is stored and
  waits for its lifetime whether or not a chat exists and whatever its send
  did; without one, a send that fails refuses it ("could not reach you").

  **Announcements.** Through the listener the channels application registers
  as `:cue_proposal_listener` (`proposal_event(event)`): `{:offered, card}` when
  a proposal is stored and waits, and `{:resolved, resolved}` when it leaves
  `waiting` for `denied`, `expired` or a refusal at the owner's yes, and for
  `confirmed` once its call has finished, whichever surface decided it. A
  proposal refused before it was offered is never announced. No listener
  registered (core alone) announces nothing.

  The owner reads every outside text framed: a validator's refusal reason
  (labelled `validator:<mandate>`) and what the confirmed call answered. The
  unknown-outcome report goes the one way a cue's messages go,
  `Jobs.CueRun.deliver/3`, to the task's delivery target.

  Seams (opts): `:repo`, `:now`, `:proposal_sender` (`fn inbox, text, token ->
  :ok | {:error, reason} end`), `:proposal_listener` (`fn event -> any end`),
  `:task_supervisor` (where a device's confirm runs its call),
  `:app_surface?`, `:capability_registry`, `:jobs_config` and
  `:configured_owners` (the owner inbox), `:adapter` and `:channels` (the
  unknown-outcome report), and the `Cues.Mandates`, `Cues.Pins` and
  `Cues.Validator` seams.
  """

  require Logger

  alias FermixCore.Capabilities.AccessGate
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Capabilities.UntrustedContent
  alias FermixCore.Clock
  alias FermixCore.Cues.Mandates
  alias FermixCore.Cues.Pins
  alias FermixCore.Cues.ProposalView
  alias FermixCore.Cues.Telemetry
  alias FermixCore.Cues.Validator
  alias FermixCore.Delivery.OwnerInbox
  alias FermixCore.Jobs.CueRun
  alias FermixCore.Jobs.Registry, as: JobsRegistry
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesMandateSql

  @token_prefix "cp_"
  @max_message_chars 3_500
  @max_result_chars 2_000
  @max_reply_chars 1_500
  # A confirmed call runs within a few seconds (its HTTP request is bounded);
  # one still without a result after this long stopped mid-run.
  @unknown_after_s 600
  @unknown_reports_per_sweep 5
  @send_timeout_ms 30_000
  # What an app surface lists: every proposal still waiting (oldest first),
  # or those of the last week (newest first).
  @max_waiting 100
  @recent_days 7
  @max_recent 50
  @app_surfaces [:companion, :mobile, :management]
  @max_device_id_bytes 128
  # With no chat the row records no chat: its token then confirms from nowhere.
  @no_chat %{platform: nil, chat_id: nil, user_id: nil}

  @too_long "This call is too long to show you in full; it was not proposed."
  @unreachable "Fermix could not reach you, so the proposal was not sent."
  @recheck_failed "Fermix could not finish checking it"
  @unverified "Fermix could not verify the mandate's pins; the mandate stays on"
  @reapproved "the mandate was approved again while this call was checked"

  @typedoc "What a proposal needs from the mandate call that makes it."
  @type call :: %{
          mandate: Mandates.t(),
          tool: String.t(),
          args: map(),
          args_json: String.t(),
          idempotency_key: String.t(),
          validator: String.t(),
          run_id: String.t(),
          job_id: String.t(),
          session_id: String.t(),
          cue: map(),
          snapshot: String.t() | nil
        }

  @typedoc """
  A proposal ready to store: its row, its token, the owner's message and the
  owner's chat (`inbox` nil when only an app can show it).
  """
  @type prepared :: %{
          row: map(),
          token: String.t(),
          text: String.t(),
          inbox: map() | nil,
          session_id: String.t()
        }

  @typedoc "Where a `/confirm` or `/deny` came from."
  @type origin :: %{platform: String.t(), chat_id: String.t(), user_id: String.t() | nil}

  @typedoc "Which of the owner's devices answered (D28); a phone names itself."
  @type app_origin :: %{
          surface: :companion | :mobile | :management,
          device_id: String.t() | nil
        }

  @typedoc "What every app surface learns when a proposal leaves `waiting`."
  @type resolved :: %{
          proposal_id: String.t(),
          state: String.t(),
          result_status: String.t() | nil,
          sentence: String.t(),
          result_text: String.t() | nil
        }

  @typedoc "An announcement to the app surfaces."
  @type event :: {:offered, ProposalView.card()} | {:resolved, resolved()}

  @doc "Whether `token` has the shape of a proposal token (the gateway's router)."
  @spec token?(term()) :: boolean()
  def token?(@token_prefix <> rest) when byte_size(rest) > 0, do: true
  def token?(_other), do: false

  @doc "The longest message a proposal may be, in characters."
  @spec max_message_chars() :: pos_integer()
  def max_message_chars, do: @max_message_chars

  @doc """
  Builds the proposal of `call` at `now`: the owner's chat (nil when only an
  app can show it), a fresh token, the expiry and the chat's message.
  `{:refuse, sentence}` when Fermix can ask the owner nowhere, or when the
  message would be over #{@max_message_chars} characters (the cap holds
  whether or not a chat gets it, so every surface shows the call whole).
  """
  @spec prepare(call(), DateTime.t(), keyword()) :: {:ok, prepared()} | {:refuse, String.t()}
  def prepare(%{mandate: %Mandates{} = mandate} = call, %DateTime{} = now, opts)
      when is_list(opts) do
    with {:ok, chat} <- reach(opts) do
      token = @token_prefix <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
      expires_at = DateTime.add(now, mandate.approve_within_s, :second)
      text = message(call, token, expires_at)

      if String.length(text) > @max_message_chars,
        do: {:refuse, @too_long},
        else: {:ok, prepared(call, chat, token, expires_at, text)}
    end
  end

  @doc """
  Stores the prepared proposal with the decision of call row `call_id` (Repo
  call (2), which also sets the run's marker), then sends it to the owner's
  chat when there is one and offers it to every app surface (the reach rule
  decides what a failed send does). A proposal with the same idempotency key
  is not stored again.
  """
  @spec store_and_send(String.t(), prepared(), DateTime.t(), keyword()) ::
          {:proposed, String.t()}
          | {:existing, map()}
          | {:unreachable, String.t()}
          | {:error, term()}
  def store_and_send(call_id, %{row: row} = prepared, %DateTime{} = now, opts)
      when is_binary(call_id) and is_list(opts) do
    case repo_call({:decide_propose, call_id, row, now}, opts) do
      {:ok, {:new, id}} -> send_new(id, call_id, prepared, now, opts)
      {:ok, {:existing, existing}} -> {:existing, existing}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The owner's `/confirm <token>` from `origin`. Returns the reply for the owner.
  """
  @spec confirm(String.t(), origin(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def confirm(token, origin, opts \\ []) when is_binary(token) and is_list(opts) do
    now = now(opts)

    with {:ok, origin} <- checked_origin(origin),
         {:ok, proposal} <- repo_call({:confirm_proposal, digest(token), origin, now}, opts) do
      lifecycle(:confirmed, proposal, %{state: "confirmed", kind: origin.platform})
      run_confirmed(proposal, now, opts)
    else
      {:error, why} -> {:error, refusal_reply(why)}
    end
  end

  @doc "The owner's `/deny <token>` from `origin`. Returns the reply for the owner."
  @spec deny(String.t(), origin(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def deny(token, origin, opts \\ []) when is_binary(token) and is_list(opts) do
    with {:ok, origin} <- checked_origin(origin),
         {:ok, proposal} <- repo_call({:deny_proposal, digest(token), origin, now(opts)}, opts) do
      {:ok, denied(proposal, origin.platform, opts)}
    else
      {:error, why} -> {:error, refusal_reply(why)}
    end
  end

  @doc """
  What an app surface lists: Fermix's record of every proposal still waiting
  (oldest first, at most #{@max_waiting}), or of every proposal of the last
  #{@recent_days} days (newest first, at most #{@max_recent}). No argument and
  no cue text. `{:error, :memory_off}` with memory switched off.
  """
  @spec records(:waiting | :recent, keyword()) ::
          {:ok, [ProposalView.record()]} | {:error, :memory_off | term()}
  def records(which, opts \\ []) when which in [:waiting, :recent] and is_list(opts) do
    with {:ok, rows} <- read(list_request(which, now(opts)), opts) do
      {:ok, Enum.map(rows, &ProposalView.record/1)}
    end
  end

  @doc """
  The card of one proposal (`Cues.ProposalView`): its record, when the cue
  arrived, Fermix's sentence and the outside text apart.
  """
  @spec card(String.t(), keyword()) ::
          {:ok, ProposalView.card()} | {:error, :not_found | :memory_off | term()}
  def card(proposal_id, opts \\ []) when is_binary(proposal_id) and is_list(opts) do
    case read({:proposal_card, proposal_id}, opts) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, row} -> {:ok, ProposalView.card(row)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The card of every proposal still waiting, oldest first (at most
  #{@max_waiting}): what an app that connects is shown.
  """
  @spec waiting_cards(keyword()) :: {:ok, [ProposalView.card()]} | {:error, :memory_off | term()}
  def waiting_cards(opts \\ []) when is_list(opts) do
    with {:ok, rows} <- read(list_request(:waiting, now(opts)), opts) do
      {:ok, Enum.map(rows, &ProposalView.card/1)}
    end
  end

  @doc """
  An answer from one of the owner's devices (D28): `origin` names the surface,
  and a phone its `device_id`. One Repo call moves the proposal out of
  `waiting`, fenced on its id and its expiry, so the first answer from any
  surface wins. A denial runs nothing; a confirm runs the path `confirm/3`
  runs (the checks again, then exactly the recorded call, once) in a task of
  its own. Answers Fermix's record as soon as the decision is recorded:
  `denied`, or `confirmed` with no `result_status` while its call runs; every
  app surface hears the outcome (`{:resolved, …}`). A refusal is the owner's
  sentence, and nothing ran.
  """
  @spec decide(String.t(), :confirm | :deny, app_origin(), keyword()) ::
          {:ok, ProposalView.record()} | {:error, String.t()}
  def decide(proposal_id, decision, %{surface: surface} = origin, opts \\ [])
      when is_binary(proposal_id) and decision in [:confirm, :deny] and
             surface in @app_surfaces and is_list(opts) do
    now = now(opts)
    request = {:decide_proposal, proposal_id, to_state(decision), decided_from(origin), now}

    case repo_call(request, opts) do
      {:ok, proposal} ->
        record = read({:proposal_card, proposal_id}, opts)
        after_decision(decision, proposal, Atom.to_string(surface), now, opts)
        decided_record(record, proposal_id)

      {:error, why} ->
        {:error, refusal_reply(why)}
    end
  end

  @doc """
  The `Cues.Sweeper` step: waiting proposals past their expiry become
  `expired`; nothing runs. Every app surface hears it.
  """
  @spec expire(keyword(), DateTime.t(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def expire(repo_opts, %DateTime{} = now, limit) when is_list(repo_opts) do
    with {:ok, expired} <-
           Repo.cues_call(CuesMandateSql, {:expire_proposals, now, limit}, repo_opts) do
      Enum.each(expired, &expired(&1, repo_opts))
      {:ok, length(expired)}
    end
  end

  defp expired(proposal, repo_opts) do
    lifecycle(:proposal_expired, proposal, %{state: "expired"})
    resolved = resolved(proposal, "expired", "That proposal expired; nothing ran.")
    announce({:resolved, resolved}, repo_opts)
  end

  @doc """
  The `Cues.Sweeper` step that reports, once, a confirmed proposal whose call
  stopped before it reported (a crash or a restart between the confirm and the
  result, #{@unknown_after_s} s or more ago). It is never run again. At most
  #{@unknown_reports_per_sweep} a pass, each one send to the task's delivery
  target through `Jobs.CueRun.deliver/3`; a send that fails is tried again on a
  later pass, and one with nowhere to go (the task is gone or delivers nowhere)
  is logged and not tried again.
  """
  @spec report_unknown(keyword(), DateTime.t(), pos_integer(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def report_unknown(repo_opts, %DateTime{} = now, _limit, send_opts \\ [])
      when is_list(repo_opts) and is_list(send_opts) do
    cutoff = DateTime.add(now, -@unknown_after_s, :second)
    request = {:claim_unknown_outcomes, now, cutoff, @unknown_reports_per_sweep}

    with {:ok, claimed} <- Repo.cues_call(CuesMandateSql, request, repo_opts) do
      Enum.each(claimed, &report_one(&1, now, repo_opts, send_opts))
      {:ok, length(claimed)}
    end
  end

  # --- proposing -----------------------------------------------------------------------

  # Where Fermix can ask the owner (the reach rule, C55): the owner's chat when
  # there is one, else nil while an app can show the proposal, else nowhere.
  defp reach(opts) do
    case owner_dm(opts) do
      {:ok, inbox, origin} -> {:ok, {inbox, origin}}
      :none -> if Mandates.app_surface?(opts), do: {:ok, nil}, else: no_reach()
    end
  end

  defp no_reach, do: {:refuse, Mandates.approve_inbox_sentence()}

  # The owner's DM and the origin a confirm from it carries
  # (`OwnerInbox.dm_origin/1` owns the rule that makes that origin checkable).
  defp owner_dm(opts) do
    with {:ok, inbox} <-
           OwnerInbox.resolve(Keyword.take(opts, [:jobs_config, :configured_owners])),
         {:ok, origin} <- OwnerInbox.dm_origin(inbox) do
      {:ok, inbox, origin}
    else
      _no_chat_that_can_confirm -> :none
    end
  end

  defp prepared(call, chat, token, expires_at, text) do
    {inbox, origin} = chat || {nil, @no_chat}

    %{
      row: row(call, origin, token, expires_at),
      token: token,
      text: text,
      inbox: inbox,
      session_id: call.session_id
    }
  end

  defp row(call, origin, token, expires_at) do
    %{
      id: FermixCore.Cues.id("cpr"),
      run_id: call.run_id,
      job_id: call.job_id,
      mandate: call.mandate.name,
      watcher_id: Map.get(call.cue, :watcher_id),
      delivery_id: Map.get(call.cue, :delivery_id),
      tool: call.tool,
      args_json: call.args_json,
      idempotency_key: call.idempotency_key,
      token_digest: digest(token),
      validator: call.validator,
      sent_platform: origin.platform,
      sent_chat_id: origin.chat_id,
      sent_user_id: origin.user_id,
      expires_at: expires_at
    }
  end

  # The owner's chat gets it when there is one; then it waits, offered to every
  # app surface. A chat's failed send refuses it only where no app can show it.
  defp send_new(id, call_id, prepared, now, opts) do
    case deliver(prepared, opts) do
      :ok ->
        offer(id, call_id, prepared, opts)

      {:error, reason} ->
        Logger.warning("Proposal #{id} could not be sent: #{inspect(reason)}")

        if Mandates.app_surface?(opts),
          do: offer(id, call_id, prepared, opts),
          else: refuse_waiting(id, now, opts)
    end
  end

  defp offer(id, call_id, prepared, opts) do
    sent = Map.merge(prepared.row, %{session_id: prepared.session_id, mandate_call_id: call_id})
    lifecycle(:proposed, sent, %{state: "waiting"})

    case card(id, opts) do
      {:ok, card} -> announce({:offered, card}, opts)
      {:error, reason} -> Logger.error("Proposal #{id} not offered: #{inspect(reason)}")
    end

    {:proposed, id}
  end

  defp refuse_waiting(id, now, opts) do
    case repo_call({:refuse_proposal, id, "waiting", @unreachable, now}, opts) do
      {:ok, proposal} ->
        lifecycle(:proposal_refused, proposal, %{state: "refused", reason: "unreachable"})
        {:unreachable, id}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # No chat with the owner: only an app shows it (`reach/1` let it through).
  defp deliver(%{inbox: nil}, _opts), do: :ok

  defp deliver(%{inbox: inbox, text: text, token: token}, opts) do
    case Keyword.get_lazy(opts, :proposal_sender, &registered_sender/0) do
      nil -> {:error, :no_proposal_sender}
      send_fun when is_function(send_fun, 3) -> guarded_send(send_fun, inbox, text, token)
    end
  end

  # A sender that raises after the proposal was stored is a send that failed:
  # the proposal is refused, so no waiting proposal is left that nobody saw.
  # The raise is logged with its stacktrace, the token taken out of it.
  defp guarded_send(send_fun, inbox, text, token) do
    send_fun.(inbox, text, token)
  catch
    kind, reason ->
      formatted =
        kind
        |> Exception.format(reason, __STACKTRACE__)
        |> String.replace(token, @token_prefix <> "…")
        |> String.slice(0, 4_000)

      Logger.error("The proposal sender crashed: " <> formatted)
      {:error, {:sender_crashed, kind}}
  end

  # The channels application registers its sender module; nil while it is not
  # running (a tree-less CLI, a test of core alone).
  defp registered_sender do
    case Application.get_env(:fermix_core, :cue_proposal_sender) do
      nil -> nil
      module when is_atom(module) -> &module.send_cue_proposal/3
    end
  end

  # --- the owner's message ---------------------------------------------------------------

  defp message(call, token, expires_at) do
    """
    Fermix: a task wants to act under your mandate #{call.mandate.name}, and runs it only if \
    you confirm.

    Task: #{call.mandate.job_name || call.job_id} (job #{call.job_id})
    Watcher: #{Map.get(call.cue, :watcher_name) || "unknown"}
    Call: #{call.tool}, with the arguments the task wrote from outside text:
    #{UntrustedContent.frame(call.tool, pretty(call.args))}

    The cue it acted on, from #{Map.get(call.cue, :source_ref)}:
    #{UntrustedContent.frame("cue:" <> to_string(Map.get(call.cue, :source_ref)), snapshot_text(call.snapshot))}

    It waits until #{time_text(expires_at)}. Confirm with `/confirm #{token}` or deny with \
    `/deny #{token}`.\
    """
  end

  defp pretty(args), do: Jason.encode!(args, pretty: true)

  defp snapshot_text(nil), do: "(Fermix no longer keeps this cue's snapshot.)"

  defp snapshot_text(snapshot) when is_binary(snapshot) do
    case Jason.decode(snapshot) do
      {:ok, %{} = fields} -> snapshot_lines(fields)
      _not_json -> snapshot
    end
  end

  defp snapshot_lines(fields) do
    [
      "Type: #{Map.get(fields, "type") || "not given"}",
      "Subject: #{Map.get(fields, "subject") || "none"}",
      to_string(Map.get(fields, "text") || "")
    ]
    |> Enum.join("\n")
  end

  defp time_text(%DateTime{} = at), do: Clock.stated_instant(at)

  # --- confirming ----------------------------------------------------------------------

  defp checked_origin(%{platform: platform, chat_id: chat_id} = origin)
       when is_binary(platform) and is_binary(chat_id) do
    case Map.get(origin, :user_id) do
      user_id when is_binary(user_id) and user_id != "" ->
        {:ok, %{platform: platform, chat_id: chat_id, user_id: user_id}}

      _missing ->
        {:error, :wrong_origin}
    end
  end

  defp checked_origin(_origin), do: {:error, :wrong_origin}

  # The checks again, then the call: the owner's reply, and what every app
  # surface learns once it has finished (nothing when the refusal could not be
  # recorded: the proposal stays confirmed, and the unknown-outcome sweep tells
  # the owner).
  defp run_confirmed(proposal, now, opts) do
    {reply, resolved} =
      case guarded_recheck(proposal, opts, now) do
        {:ok, capability, args} -> execute(capability, args, proposal, opts)
        {:refuse, reason} -> refuse_confirmed(proposal, reason, now, opts)
      end

    if resolved, do: announce({:resolved, resolved}, opts)
    reply
  end

  # --- deciding from a device ----------------------------------------------------------

  defp to_state(:confirm), do: "confirmed"
  defp to_state(:deny), do: "denied"

  defp decided_from(%{surface: :mobile, device_id: device_id})
       when is_binary(device_id) and device_id != "" and
              byte_size(device_id) <= @max_device_id_bytes,
       do: "mobile:" <> device_id

  defp decided_from(%{surface: surface, device_id: nil})
       when surface in [:companion, :management],
       do: Atom.to_string(surface)

  defp after_decision(:deny, proposal, surface, _now, opts),
    do: _ = denied(proposal, surface, opts)

  defp after_decision(:confirm, proposal, surface, now, opts) do
    lifecycle(:confirmed, proposal, %{state: "confirmed", kind: surface})
    start_run(proposal, now, opts)
  end

  # A device's confirm runs its call in a task of its own, so the answer is
  # recorded and acknowledged at once; the task's outcome is announced.
  defp start_run(proposal, now, opts) do
    supervisor = Keyword.get(opts, :task_supervisor, FermixCore.TaskSupervisor)

    case Task.Supervisor.start_child(supervisor, fn -> run_confirmed(proposal, now, opts) end) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "Proposal #{proposal.id}: the confirmed call could not start: #{inspect(reason)}"
        )

        {_reply, resolved} = refuse_confirmed(proposal, "Fermix could not start it", now, opts)
        if resolved, do: announce({:resolved, resolved}, opts)
    end
  end

  # The decision is recorded whatever the read after it found; a read that
  # failed is said as such, never as "nothing ran".
  defp decided_record({:ok, %{} = row}, _proposal_id), do: {:ok, ProposalView.record(row)}

  defp decided_record(other, proposal_id) do
    Logger.error("Proposal #{proposal_id} decided, then not read back: #{inspect(other)}")
    {:error, "Fermix recorded your answer but could not read the proposal back."}
  end

  # A denial, from a chat or a device: its telemetry names the surface, and
  # every app surface hears it. Answers the owner's reply.
  defp denied(proposal, surface, opts) do
    lifecycle(:denied, proposal, %{state: "denied", kind: surface})
    sentence = "Denied. #{proposal.tool} will not run."
    announce({:resolved, resolved(proposal, "denied", sentence)}, opts)
    sentence
  end

  defp resolved(proposal, state, sentence, result_status \\ nil, result_text \\ nil) do
    %{
      proposal_id: proposal.id,
      state: state,
      result_status: result_status,
      sentence: sentence,
      result_text: ProposalView.bounded(result_text, @max_result_chars)
    }
  end

  # A re-check that raises or exits (a seam, a Repo call that timed out) is a
  # refusal: recorded `refused` and announced at once, so a call that never
  # started is never left `confirmed` with no result. Logged with its reason;
  # a crash once the executor has started keeps the unknown-outcome path.
  defp guarded_recheck(proposal, opts, now) do
    recheck(proposal, opts, now)
  catch
    kind, reason ->
      formatted = kind |> Exception.format(reason, __STACKTRACE__) |> String.slice(0, 2_000)
      Logger.error("Proposal #{proposal.id}: the checks at the confirm failed: " <> formatted)
      {:refuse, @recheck_failed}
  end

  # The switches, the pin check, the grant (the tool and `pin_args`, as the
  # mandate reads now: a proposal outlives a narrowing and a new approval) and
  # the validator, again at the owner's yes (design §10.9 step 2); freshness
  # is the proposal's own lifetime.
  defp recheck(proposal, opts, now) do
    with {:ok, mandate} <- live_mandate(proposal.mandate, opts),
         {:ok, approval} <- in_force(mandate, opts),
         :ok <- pin_check(mandate, approval, opts, now),
         {:ok, args} <- decode_args(proposal.args_json),
         :ok <- in_grant(mandate, proposal.tool, args),
         :ok <- validate(mandate, proposal, args, opts),
         {:ok, capability} <- capability(proposal.tool, opts) do
      {:ok, capability, args}
    end
  end

  defp live_mandate(name, opts) do
    case Mandates.get(name, opts) do
      {:ok, %Mandates{status: :active} = mandate} -> {:ok, mandate}
      {:ok, %Mandates{status: {:inactive, reason}}} -> {:refuse, reason}
      :error -> {:refuse, "the mandate #{name} no longer exists"}
    end
  end

  # The switches and the approval are `Mandates.in_force/2`'s, in the owner's
  # words: this answers their yes.
  defp in_force(mandate, opts) do
    case Mandates.in_force(mandate, opts) do
      {:ok, approval} -> {:ok, approval}
      {:error, why} -> {:refuse, not_in_force(why)}
    end
  end

  defp not_in_force(:switched_off), do: "the mandate is switched off"
  defp not_in_force(:mandates_off), do: "unattended mandate calls are switched off in settings"
  defp not_in_force({:inactive, why}), do: why
  defp not_in_force(:unapproved), do: "the mandate is not approved"
  defp not_in_force({:disabled, _why}), do: "the mandate is disabled until you approve it again"

  defp not_in_force({:approval_unreadable, reason}),
    do: "the mandate's approval could not be read: #{inspect(reason)}"

  # As at the gate: only a real change disables the mandate; a job row the
  # Repo could not read refuses this confirm alone, with no disable and no notice.
  defp pin_check(mandate, row, opts, now) do
    case Pins.check(mandate, row, opts) do
      :ok ->
        :ok

      {:error, {:unverified, sentence}} ->
        Logger.warning("Mandate #{mandate.name} pins not verified at a confirm: #{sentence}")
        {:refuse, @unverified}

      {:error, why} ->
        unpinned(mandate, why, row, opts, now)
    end
  end

  # A change disables the mandate and refuses the confirm. An approval the owner
  # gave while the pins were checked is left on (`Pins.disable_changed/5`), and
  # the confirm, checked against the old one, runs nothing. `disable_changed/5`
  # logs a failed write.
  defp unpinned(mandate, why, row, opts, now) do
    case Pins.disable_changed(mandate.name, why, row, now, opts) do
      {:ok, :reapproved} -> {:refuse, @reapproved}
      _disabled_or_failed -> {:refuse, Pins.changed_reason()}
    end
  end

  defp in_grant(mandate, tool, args) do
    case Mandates.outside_grant(mandate, tool, args) do
      nil -> :ok
      reason -> {:refuse, reason}
    end
  end

  defp decode_args(args_json) do
    case Jason.decode(args_json) do
      {:ok, %{} = args} -> {:ok, args}
      _other -> {:refuse, "the recorded call could not be read"}
    end
  end

  defp validate(%Mandates{validator: nil}, _proposal, _args, _opts), do: :ok

  defp validate(mandate, proposal, args, opts) do
    with {:ok, context} <- repo_call({:proposal_context, proposal.id}, opts) do
      request = %{
        "mandate" => mandate.name,
        "tool" => proposal.tool,
        "args" => args,
        "job" => proposal.job_id,
        "run_id" => proposal.run_id,
        "idempotency_key" => proposal.idempotency_key,
        "calls_this_run" => context.calls_this_run,
        "cue" => context.cue
      }

      case Validator.run(mandate, request, opts) do
        :allow -> :ok
        {:refuse, reason} -> {:refuse, {:validator, reason}}
      end
    else
      {:error, reason} -> {:refuse, "the proposal's cue could not be read: #{inspect(reason)}"}
    end
  end

  defp capability(tool, opts) do
    registry = Keyword.get(opts, :capability_registry, CapabilityRegistry)

    case CapabilityRegistry.find(registry, tool) do
      {:ok, %Capability{} = capability} -> {:ok, capability}
      :error -> {:refuse, "#{tool} is not available now (its plugin is off or gone)"}
    end
  end

  defp refuse_confirmed(proposal, why, now, opts) do
    {reason, reply, sentence, outside} = refusal(why, proposal.mandate)

    case repo_call({:refuse_proposal, proposal.id, "confirmed", reason, now}, opts) do
      {:ok, refused} ->
        lifecycle(:proposal_refused, refused, %{state: "refused", reason: "recheck"})
        {{:error, reply}, resolved(proposal, "refused", sentence, nil, outside)}

      {:error, write_error} ->
        Logger.error("Proposal #{proposal.id} refusal not recorded: #{inspect(write_error)}")
        {{:error, reply}, nil}
    end
  end

  # The row keeps the reason as given; a validator's words (which may echo the
  # arguments) reach the owner framed, labelled with the mandate, and an app as
  # outside text beside Fermix's sentence.
  defp refusal({:validator, reason}, mandate) do
    {reason,
     "Not run: the validator refused it:\n" <>
       UntrustedContent.frame("validator:" <> mandate, reason),
     "Not run: the validator refused it.", reason}
  end

  defp refusal(reason, _mandate) when is_binary(reason),
    do: {reason, "Not run: #{reason}.", "Not run: #{reason}.", nil}

  # Exactly the recorded call, through the one invoke boundary: `access_gate`
  # `confirmed` (and, for a flagged tool, the digest the gate checks) labels the
  # executor's own exec event, under the proposing run's session.
  defp execute(capability, args, proposal, opts) do
    context = %{
      session_id: proposal.session_id,
      agent_name: "scheduled:#{proposal.job_id}",
      job_id: proposal.job_id,
      run_id: proposal.run_id,
      access_gate: "confirmed",
      access_confirmed: AccessGate.digest(capability.name, args),
      mandate_call_id: proposal.mandate_call_id,
      mandate_args_normalized?: true
    }

    capability
    |> run_call(args, context)
    |> record_result(proposal, opts)
  end

  defp run_call(capability, args, context) do
    {:ran, Capability.execute(capability, args, context)}
  catch
    kind, reason ->
      Logger.error(
        "Confirmed call #{capability.name} crashed: " <>
          (kind |> Exception.format(reason, __STACKTRACE__) |> String.slice(0, 2_000))
      )

      :crashed
  end

  defp record_result(:crashed, proposal, opts) do
    summary = "the call stopped before it reported, so whether it ran is unknown"
    _ = finish(proposal, "unknown", summary, opts)
    sentence = unknown_sentence(proposal.tool)
    {{:error, sentence}, resolved(proposal, "confirmed", sentence, "unknown")}
  end

  # A result that could not be written is logged by `finish/4`; the owner and
  # every app surface still get it.
  defp record_result({:ran, result}, proposal, opts) do
    {status, summary} = outcome(result)
    _ = finish(proposal, status, summary, opts)

    {reply(status, proposal.tool, summary),
     resolved(proposal, "confirmed", result_sentence(status, proposal.tool), status, summary)}
  end

  defp result_sentence("ok", tool), do: "Confirmed. #{tool} ran."
  defp result_sentence(_error, tool), do: "Confirmed, but #{tool} failed."

  defp unknown_sentence(tool) do
    "Confirmed, but #{tool} stopped before it reported, so whether it ran is unknown. " <>
      "Check it before you do anything; Fermix will not run it again."
  end

  defp finish(proposal, status, summary, opts) do
    case repo_call({:finish_proposal, proposal.id, status, summary, now(opts)}, opts) do
      {:ok, _proposal} ->
        :ok

      {:error, reason} ->
        Logger.error("Proposal #{proposal.id} result not recorded: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp outcome({:ok, %{success: true} = result}),
    do: {"ok", bounded(to_string(Map.get(result, :output) || ""), @max_result_chars)}

  defp outcome({:ok, %{} = result}),
    do: {"error", bounded(to_string(Map.get(result, :error) || "failed"), @max_result_chars)}

  defp outcome(other), do: {"error", bounded(inspect(other), @max_result_chars)}

  # What the service answered may echo outside text: framed, as in the report.
  defp reply("ok", tool, summary),
    do: {:ok, "Confirmed. #{tool} ran:\n" <> framed_result(tool, summary)}

  defp reply(_error, tool, summary),
    do: {:error, "Confirmed, but #{tool} failed:\n" <> framed_result(tool, summary)}

  defp framed_result(tool, summary),
    do: UntrustedContent.frame(tool, bounded(summary, @max_reply_chars))

  defp refusal_reply(:unknown), do: "That confirmation is not known to Fermix."
  defp refusal_reply(:unknown_id), do: "Fermix has no proposal with that id; nothing ran."
  defp refusal_reply(:disabled), do: "Cues keep their records in memory, which is off."

  defp refusal_reply(:wrong_origin),
    do: "Confirm it from the chat Fermix sent it to; nothing ran."

  defp refusal_reply(:expired), do: "That proposal expired; nothing ran."
  defp refusal_reply(:stale), do: "That proposal changed while you answered; nothing ran."

  defp refusal_reply({:not_waiting, "confirmed"}),
    do: "That call was already confirmed; it runs at most once."

  defp refusal_reply({:not_waiting, "denied"}), do: "That call was already denied."
  defp refusal_reply({:not_waiting, "expired"}), do: "That proposal expired; nothing ran."
  defp refusal_reply({:not_waiting, "refused"}), do: "That proposal was refused; nothing ran."

  defp refusal_reply(reason) do
    Logger.error("Proposal answer failed: #{inspect(reason)}")
    "Fermix could not read that proposal; nothing ran."
  end

  # --- the unknown-outcome report -----------------------------------------------------------

  # Through `CueRun.deliver/3`, the one send path of what a cue causes: to the
  # task's delivery target, only on a channel a cue run may reach, previews off.
  defp report_one(proposal, now, repo_opts, send_opts) do
    text =
      "Fermix: the call you confirmed, #{proposal.tool} under mandate #{proposal.mandate}, " <>
        "stopped before it reported, so whether it ran is unknown. Fermix will not run it " <>
        "again; check it before you do anything."

    delivery_opts =
      send_opts
      |> Keyword.take([:adapter, :channels])
      |> Keyword.put(:timeout_ms, @send_timeout_ms)

    case JobsRegistry.get_job(proposal.job_id, repo: Keyword.get(repo_opts, :server, Repo)) do
      {:ok, job} -> job |> CueRun.deliver(text, delivery_opts) |> told(proposal, now, repo_opts)
      {:error, :not_found} -> untold(proposal, "its task is gone", now, repo_opts)
      {:error, reason} -> release(proposal, reason, repo_opts)
    end
  end

  defp told({:ok, "sent"}, proposal, now, repo_opts), do: finish_unknown(proposal, now, repo_opts)

  defp told({:ok, status}, proposal, now, repo_opts),
    do: untold(proposal, "its task delivers nowhere (#{status})", now, repo_opts)

  defp told({:error, reason}, proposal, _now, repo_opts), do: release(proposal, reason, repo_opts)

  # Nowhere to tell the owner, now or later: the claim stays, so it is not
  # tried every pass, and the proposal is finished.
  defp untold(proposal, why, now, repo_opts) do
    Logger.error("Proposal #{proposal.id}: the unknown outcome was not told: #{why}")
    finish_unknown(proposal, now, repo_opts)
  end

  # The report is the only end such a call has: the proposal and its call row
  # are finished `unknown` (fenced on `confirmed` and no result yet), and
  # every app surface hears it, as for a call that crashed while it ran.
  defp finish_unknown(proposal, now, repo_opts) do
    request = {:finish_proposal, proposal.id, "unknown", "stopped before it reported", now}

    case Repo.cues_call(CuesMandateSql, request, repo_opts) do
      {:ok, _finished} ->
        sentence = unknown_sentence(proposal.tool)
        announce({:resolved, resolved(proposal, "confirmed", sentence, "unknown")}, repo_opts)

      {:error, reason} ->
        Logger.error("Proposal #{proposal.id} unknown outcome not recorded: #{inspect(reason)}")
    end
  end

  defp release(proposal, reason, repo_opts) do
    Logger.warning("Proposal #{proposal.id} unknown-outcome report not sent: #{inspect(reason)}")

    case Repo.cues_call(CuesMandateSql, {:release_report, proposal.id}, repo_opts) do
      {:ok, :ok} ->
        :ok

      {:error, release_error} ->
        Logger.error("Proposal #{proposal.id}: #{inspect(release_error)}")
    end
  end

  # --- helpers -------------------------------------------------------------------------

  defp lifecycle(phase, proposal, extra) do
    case Map.get(proposal, :session_id) do
      session_id when is_binary(session_id) ->
        Telemetry.lifecycle(
          phase,
          %{},
          Map.merge(
            %{
              session_id: session_id,
              proposal_id: proposal.id,
              mandate_call_id: Map.get(proposal, :mandate_call_id),
              job_id: proposal.job_id,
              run_id: proposal.run_id,
              delivery_id: proposal.delivery_id,
              watcher_id: proposal.watcher_id,
              mandate: proposal.mandate,
              tool: proposal.tool
            },
            extra
          )
        )

      nil ->
        Logger.warning("Proposal #{proposal.id} #{phase}: its run's session is gone")
    end
  end

  # Every app surface hears it through the listener the channels application
  # registered (none in core alone). A listener that raises is logged: the
  # decision it reports is already recorded, and an app reads it again at its
  # next connect.
  defp announce(event, opts) do
    case Keyword.get_lazy(opts, :proposal_listener, &registered_listener/0) do
      nil -> :ok
      listener when is_function(listener, 1) -> guarded_announce(listener, event)
    end
  end

  defp registered_listener do
    case Application.get_env(:fermix_core, :cue_proposal_listener) do
      nil -> nil
      module when is_atom(module) -> &module.proposal_event/1
    end
  end

  defp guarded_announce(listener, event) do
    _ = listener.(event)
    :ok
  catch
    kind, reason ->
      formatted = kind |> Exception.format(reason, __STACKTRACE__) |> String.slice(0, 2_000)
      Logger.error("The proposal listener crashed: " <> formatted)
  end

  defp list_request(:waiting, now), do: {:proposal_cards, :waiting, now, @max_waiting}

  defp list_request(:recent, now),
    do: {:proposal_cards, {:since, DateTime.add(now, -@recent_days, :day)}, @max_recent}

  defp read(request, opts) do
    case repo_call(request, opts) do
      {:error, :disabled} -> {:error, :memory_off}
      result -> result
    end
  end

  defp digest(token), do: :sha256 |> :crypto.hash(token) |> Base.encode16(case: :lower)

  defp bounded(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max) <> "…", else: text
  end

  defp now(opts), do: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

  defp repo_call(request, opts),
    do: Repo.cues_call(CuesMandateSql, request, server: Keyword.get(opts, :repo, Repo))
end
