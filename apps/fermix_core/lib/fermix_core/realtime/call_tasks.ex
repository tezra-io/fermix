defmodule FermixCore.Realtime.CallTasks do
  @moduledoc """
  The tasks of one voice call that hands its work to the Fermix agent, and what
  the call leaves behind (M70 §03): one copy for both task engines, GPT Live
  (`LiveSessionServer`) and Grok (`GrokSessionServer`).

  Each engine speaks its own provider wire and reads its own turns; neither
  runs a tool. Every piece of work is a task of the call, submitted through
  `FermixCore.Realtime.VoiceBridge` to an ordinary agent turn. What is the same
  on both wires lives here:

    * **The two slots.** `LiveDelegation` holds one running task and one
      waiting; a third is refused, out loud, as `{:busy, id}`.
    * **The request.** What a task runs with is built from the call's own
      transcript, never from the voice model's word alone: the exchange since
      the previous hand-off in a call in the chat (M56 §4.1), the 30-second
      window in a private call. A task with no owner speech behind it waits
      once for the words that explain it, then asks again rather than act on a
      partial sentence. What the voice model itself said the task was (Grok's
      function argument) rides beside the words, labelled as its own.
    * **The result.** A reply is said as one line, and in a call in the chat
      what cannot be said (a link, code, a table, a long answer) is shown in the
      chat first, the voice told so only once the row is written (M56 §4.5). A
      reply drawn from Computer History reaches the voice only when its
      provider may carry it (M56 §9, `LiveChat.history_permitted?/1`); a private
      call shows nothing.
    * **The end.** A private call cancels its tasks; a call in the chat hands
      the running one over to finish into the chat (M56 §4.6). The call's
      record, its gist and its one chat row are settled once (M56 §4.2).

  The functions that move a task answer `{tasks, told}`: `told` is what the
  call must say, in order, as `t:told/0` — what its voice is told, then the
  companion's `task` frames. Each engine says the first on its own wire (GPT
  Live as a spoken commentary or a quiet thinking line, Grok as the output of
  the function call that asked) and sends the frames as they are; nothing here
  knows either wire or the socket.

  Not pure: this runs in the session's own process and owns the effects a task
  has inside Fermix — the bridge, the call's record, the delegation telemetry
  and the one bounded context wait — each named at its call site. The session
  passes its transcript to every function that reads the words.
  """

  alias FermixCore.Capabilities.AccessGate
  alias FermixCore.Capabilities.AccessGate.Pending, as: AccessPending
  alias FermixCore.Realtime.CallGist
  alias FermixCore.Realtime.CallRecord
  alias FermixCore.Realtime.CallSpeech
  alias FermixCore.Realtime.LiveChat
  alias FermixCore.Realtime.LiveDelegation
  alias FermixCore.Realtime.LiveFrames
  alias FermixCore.Realtime.LiveTelemetry
  alias FermixCore.Realtime.LiveText
  alias FermixCore.Realtime.LiveTranscript
  alias FermixCore.Realtime.VoiceBridge

  require Logger

  # A task arrives a moment before the transcript that explains it, so it waits
  # once, this long, for the words (M41 §5.1).
  @context_wait_ms 1_000

  # How far back a task's request reads. Long enough for a correction and a
  # confirmation, short enough that an unrelated earlier topic cannot be
  # mistaken for the current request. A private call's request is this window;
  # every call's sufficiency check reads it.
  @context_window_ms 30_000

  # The bound on a hand-off's request in the chat's conversation (M56 §4.1):
  # the exchange since the previous hand-off, cut from the front, since its end
  # is the ask.
  @exchange_max_bytes 4_096

  # What a voice says of a result: a line, not a document. GPT Live caps an
  # append at 500 tokens, and these bytes sit under that with room for
  # multibyte text; Grok is held to the same line.
  @spoken_max_bytes 1_500
  # The wire's own bound on `task.summary` (protocol v2).
  @summary_max_chars 240
  @tool_progress_interval_ms 2_000

  # What the voice is told about a result shown in the chat (M56 §4.5), after
  # the line it says, only once the row is written.
  @in_chat_line "The full result is in the chat."
  # What it says instead of a reply drawn from Computer History it may not
  # carry (M56 §9): the product's own words, never the reply's.
  @withheld_shown_line "The result is in the chat."
  @withheld_unshown_line "The result could not be put in the chat."
  @withheld_private_line "That result draws on your computer history, so it cannot be said on this call."

  # A task that outlives its call (M56 §4.6): what its frame and record say,
  # and why a waiting task, or one its new owner will not take, ended with the
  # call.
  @detached_summary "The result will be in the chat."
  @dropped_summary "Dropped when the call ended: its words were not heard."
  @not_kept_full_summary "Not kept after the call: too many tasks were still running."
  @not_kept_summary "Not kept after the call: it could not be handed over."

  # A task the voice model revised before it ran to its end (Grok): the
  # earlier revision's record and frame.
  @superseded_summary "Replaced by a newer request."

  @typedoc """
  What a call's voice is told, for one engine to say on its own wire:

    * `{:clarify, record}` — the task had no owner speech behind it after the
      one wait, and was dropped;
    * `{:submit_failed, record}` — the bridge would not start it;
    * `{:progress, record, text}` — the running turn's own progress line,
      unbounded (the wire bounds it);
    * `{:tool_started, record, name}` — the running turn started a tool,
      already throttled to one every two seconds;
    * `{:completed, record, spoken}` — the line to say, bounded, ending with
      "The full result is in the chat." when a row was written;
    * `{:cancelled, record}`, `{:failed, record, sentence}` — the task ended
      without a result; the sentence is bounded;
    * `{:busy, id}` — a third task was refused while two are in flight;
    * `:handed_over` — as the call ends, at least one task goes on into the chat;
    * `{:frame, frame}` — a `task` frame for the companion (`LiveFrames.task/7`),
      always after what the voice is told by the same step.
  """
  @type told ::
          {:clarify, LiveDelegation.record()}
          | {:submit_failed, LiveDelegation.record()}
          | {:progress, LiveDelegation.record(), String.t()}
          | {:tool_started, LiveDelegation.record(), String.t()}
          | {:completed, LiveDelegation.record(), String.t()}
          | {:cancelled, LiveDelegation.record()}
          | {:failed, LiveDelegation.record(), String.t()}
          | {:busy, String.t()}
          | :handed_over
          | {:frame, map()}

  @type t :: %__MODULE__{
          call_id: String.t(),
          call_uuid: String.t(),
          conversation: String.t(),
          device_id: String.t(),
          voice_provider: atom(),
          persist?: boolean(),
          meta: map(),
          clock: (-> integer()),
          context_wait_ms: pos_integer(),
          record_opts: keyword(),
          record: CallRecord.t() | nil,
          bridge: module() | nil,
          handle: term() | nil,
          delegations: LiveDelegation.t(),
          voice_requests: %{String.t() => String.t()},
          turn_sessions: %{String.t() => String.t()},
          history_tainted: MapSet.t(String.t()),
          tainted?: boolean(),
          outside_sources: MapSet.t(),
          last_activity_ms: %{String.t() => integer()},
          context_timers: %{String.t() => {reference(), pos_integer()}},
          exchange_since_ms: non_neg_integer() | nil,
          access_window: {String.t(), non_neg_integer()} | nil,
          access_confirms: %{reference() => {String.t(), pos_integer()}},
          detached: %{String.t() => {pos_integer(), VoiceBridge.forward()}},
          outbox: [map()]
        }

  @enforce_keys [
    :call_id,
    :call_uuid,
    :conversation,
    :device_id,
    :voice_provider,
    :meta,
    :clock,
    :record_opts
  ]
  defstruct [
    :call_id,
    :call_uuid,
    :conversation,
    :device_id,
    :voice_provider,
    :meta,
    :clock,
    :record_opts,
    :delegations,
    :history_tainted,
    persist?: false,
    context_wait_ms: @context_wait_ms,
    record: nil,
    bridge: nil,
    handle: nil,
    # What the voice model said each task was, by task id (Grok's function
    # argument); GPT Live raises a task with no words of its own.
    voice_requests: %{},
    turn_sessions: %{},
    # Whether anything drawn from Computer History reached this call: what it
    # started with, a mirrored answer, a task's reply (M56 §9). Never
    # forgotten: the call's gist inherits it.
    tainted?: false,
    # What the call's hand-offs read that someone else could have written, as
    # each turn told it. The voice model heard their replies, so every later
    # hand-off starts with it; never forgotten while the call lasts.
    outside_sources: MapSet.new(),
    last_activity_ms: %{},
    context_timers: %{},
    # Where the next hand-off's exchange starts (M56 §4.1): the end of the
    # newest speech when the previous request was handed to the bridge, `nil`
    # until then (the exchange since the call started).
    exchange_since_ms: nil,
    # `{intent_id, since_ms}`: the parked access-sensitive command the last
    # settled task's OWN turn asked the owner about, and when the owner had
    # last stopped speaking as that reply was delivered. Only speech after it
    # answers (`Capabilities.AccessGate`'s spoken yes); `nil` otherwise.
    access_window: nil,
    # Confirmed access-sensitive runs in flight: task ref -> the task id and
    # the revision it answers.
    access_confirms: %{},
    # Tasks handed over as the call ended (M56 §4.6): task id -> the revision
    # handed over and the forward to its new owner.
    detached: %{},
    # The `task` frames of the step in progress, newest first, handed to the
    # session behind what the voice is told (`emit/2`).
    outbox: []
  ]

  @doc """
  The tasks of a call that has none yet.

  Required: `call_id` (the trace session id), `call_uuid`, `conversation`
  (`"chat"` or `"private"`), `device_id`, `voice_provider` (the atom the Computer
  History gate reads for the voice, `:openai` or `:xai`), `meta` (the call's
  `LiveTelemetry` metadata, `engine` and `provider` included), `clock`
  (monotonic milliseconds) and `record_opts`. Optional: `persist?` and
  `context_wait_ms`.
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    conversation = Keyword.fetch!(opts, :conversation)

    unless conversation in ["chat", "private"] do
      raise ArgumentError, "conversation must be chat or private, got: #{inspect(conversation)}"
    end

    struct!(
      __MODULE__,
      opts
      |> Keyword.take([
        :call_id,
        :call_uuid,
        :conversation,
        :device_id,
        :voice_provider,
        :meta,
        :clock,
        :record_opts,
        :persist?,
        :context_wait_ms
      ])
      |> Keyword.merge(delegations: LiveDelegation.new(), history_tainted: MapSet.new())
    )
  end

  @doc "Merges `fields` into the call's telemetry metadata (a provider session id, once known)."
  @spec put_meta(t(), map()) :: t()
  def put_meta(%__MODULE__{} = tasks, fields) when is_map(fields),
    do: %{tasks | meta: Map.merge(tasks.meta, fields)}

  @doc "Names the bridge the call's tasks are submitted through, before its call is opened."
  @spec put_bridge(t(), module()) :: t()
  def put_bridge(%__MODULE__{} = tasks, bridge) when is_atom(bridge) and not is_nil(bridge),
    do: %{tasks | bridge: bridge}

  @doc "Marks the call as having heard something drawn from Computer History (M56 §9)."
  @spec mark_tainted(t()) :: t()
  def mark_tainted(%__MODULE__{} = tasks), do: %{tasks | tainted?: true}

  @doc "Whether anything drawn from Computer History reached the call."
  @spec tainted?(t()) :: boolean()
  def tainted?(%__MODULE__{tainted?: tainted?}), do: tainted?

  @doc "The tasks as the call's record holds them, newest first; `[]` before it opens."
  @spec recorded_tasks(t()) :: [CallRecord.task()]
  def recorded_tasks(%__MODULE__{record: nil}), do: []
  def recorded_tasks(%__MODULE__{record: %CallRecord{tasks: tasks}}), do: tasks

  @doc "A task still in flight (running or waiting), by id."
  @spec fetch(t(), String.t()) :: {:ok, LiveDelegation.record()} | :error
  def fetch(%__MODULE__{} = tasks, id) when is_binary(id),
    do: LiveDelegation.fetch(tasks.delegations, id)

  ## The call's record and bridge call

  @doc """
  Opens the call's durable record as the call starts, before any task can
  exist. A write that fails is logged and the call goes on: the record is what
  a call leaves behind, and a database hiccup must not end the conversation it
  records.
  """
  @spec open_record(t(), String.t(), DateTime.t()) :: t()
  def open_record(%__MODULE__{} = tasks, engine, %DateTime{} = started_at)
      when is_binary(engine) do
    record = CallRecord.new(tasks.call_uuid, engine)
    report_record(CallRecord.open(record, started_at, tasks.record_opts), "open")
    %{tasks | record: record}
  end

  @doc "Opens the call on the bridge, once the provider session is up."
  @spec open_bridge_call(t()) :: {:ok, t()} | {:error, term()}
  def open_bridge_call(%__MODULE__{bridge: bridge} = tasks) when not is_nil(bridge) do
    call = %{
      call_id: tasks.call_id,
      call_uuid: tasks.call_uuid,
      conversation: tasks.conversation,
      device_id: tasks.device_id,
      persist?: tasks.persist?,
      session_scope: tasks.call_id
    }

    with {:ok, handle} <- bridge.open_call(call) do
      {:ok, %{tasks | handle: handle}}
    end
  end

  @doc "Closes the call on the bridge. A close that failed is logged; the call ends anyway."
  @spec close_bridge_call(t()) :: t()
  def close_bridge_call(%__MODULE__{handle: nil} = tasks), do: tasks

  def close_bridge_call(%__MODULE__{} = tasks) do
    case bridge_call(fn -> tasks.bridge.close_call(tasks.handle) end) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("voice call: the bridge left the call open: #{inspect(reason)}")
    end

    %{tasks | handle: nil}
  end

  ## Tasks

  @typedoc """
  How a task was asked for: `voice_request`, what the voice model said the
  task was (Grok's function argument; GPT Live raises a task with no words of
  its own), and `await_words`, true when the owner's latest words are still
  being transcribed, so the task waits its one bounded wait for them however
  much earlier speech the transcript holds.
  """
  @type ask :: [voice_request: String.t(), await_words: boolean()]

  @doc """
  The voice raised a task: `id` is Fermix's own, `offset_ms` the moment on the
  transcript's clock it arrived, and `ask` how it was asked for. Answers
  whether it took a slot (`:ok`), was a repeat of one already known
  (`:duplicate`, nothing done), or was refused because two are in flight
  (`:busy`).
  """
  @spec create(t(), String.t(), non_neg_integer(), LiveTranscript.t(), ask()) ::
          {:ok | :duplicate | :busy, t(), [told()]}
  def create(%__MODULE__{} = tasks, id, offset_ms, transcript, ask \\ [])
      when is_binary(id) and is_integer(offset_ms) and is_list(ask) do
    case LiveDelegation.create(tasks.delegations, id, offset_ms, now(tasks)) do
      {:ok, delegations} ->
        tasks = put_voice_request(%{tasks | delegations: delegations}, id, ask[:voice_request])
        {tasks, told} = tasks |> admit(id, transcript, ask[:await_words] == true) |> emit()
        {:ok, tasks, told}

      {:duplicate, _delegations} ->
        Logger.debug("voice call: ignored duplicate task #{id}")
        {:duplicate, tasks, []}

      {:rejected, :too_many_pending, _delegations} ->
        {tasks, told} = emit({refuse(tasks, id), [{:busy, id}]})
        {:busy, tasks, told}
    end
  end

  @doc """
  The voice model asked again for a task still in flight, in new words (Grok):
  the task keeps its id and takes the next revision. A running revision is
  cancelled on the bridge first and its record and frame say it was replaced,
  so its late answer can never speak or write success; a waiting one is
  simply replaced. The caller answers whoever asked for the earlier revision.
  """
  @spec revise(t(), String.t(), non_neg_integer(), LiveTranscript.t(), ask()) ::
          {:ok, t(), [told()]} | {:error, :unknown_delegation}
  def revise(%__MODULE__{} = tasks, id, offset_ms, transcript, ask)
      when is_binary(id) and is_integer(offset_ms) and is_list(ask) do
    case fetch(tasks, id) do
      {:ok, record} ->
        cancel_on_bridge(tasks, record)
        tasks = settle_superseded(tasks, record)

        {:ok, delegations} =
          LiveDelegation.revise(tasks.delegations, id, offset_ms, now(tasks))

        tasks = put_voice_request(%{tasks | delegations: delegations}, id, ask[:voice_request])
        {tasks, told} = tasks |> admit(id, transcript, ask[:await_words] == true) |> emit()
        {:ok, tasks, told}

      :error ->
        {:error, :unknown_delegation}
    end
  end

  @doc """
  The one bounded wait for a task's words is over,
  `{:context_wait_expired, id, revision}`: it is submitted, or dropped. A wait
  of a revision the task has moved past, or of one already started, is stale
  and does nothing.
  """
  @spec context_wait_expired(t(), String.t(), pos_integer(), LiveTranscript.t()) ::
          {t(), [told()]}
  def context_wait_expired(%__MODULE__{} = tasks, id, revision, transcript)
      when is_binary(id) and is_integer(revision) do
    case {fetch(tasks, id), Map.get(tasks.context_timers, id)} do
      {{:ok, %{revision: ^revision, status: status} = record}, {_timer, ^revision}}
      when status != :running ->
        tasks = %{tasks | context_timers: Map.delete(tasks.context_timers, id)}
        emit(submit_or_clarify(tasks, record, transcript))

      _stale ->
        {tasks, []}
    end
  end

  @doc """
  One event from a running task's turn, as its callbacks forwarded it to the
  session, `{:delegation_event, id, revision, event}` (`{:progress, text}`,
  `{:activity, event}`, `:history_tainted`, `{:result, result}`). An event of a
  task no longer in flight, or of a revision the task has moved past, is
  dropped: a superseded turn's late answer never speaks.
  """
  @spec delegation_event(t(), String.t(), pos_integer(), term(), LiveTranscript.t()) ::
          {t(), [told()]}
  def delegation_event(%__MODULE__{} = tasks, id, revision, event, transcript)
      when is_binary(id) and is_integer(revision) do
    case fetch(tasks, id) do
      {:ok, %{revision: ^revision} = record} ->
        emit(event(event, record, tasks, transcript))

      _gone_or_superseded ->
        Logger.debug("voice call: dropped stale event for task #{id} revision #{revision}")
        {tasks, []}
    end
  end

  @doc """
  A message for a confirmed access-sensitive run, `{ref, {status, outcome}}`
  or its `:DOWN`: its outcome answers the task that carried the owner's yes.
  `:unknown` for a message that is not one.
  """
  @spec access_message(t(), term(), LiveTranscript.t()) :: {:ok, t(), [told()]} | :unknown
  def access_message(%__MODULE__{access_confirms: confirms} = tasks, message, transcript) do
    case access_outcome(message, confirms) do
      {:ok, ref, result} ->
        {task, confirms} = Map.pop(confirms, ref)

        {tasks, told} =
          emit(access_result(%{tasks | access_confirms: confirms}, task, result, transcript))

        {:ok, tasks, told}

      :unknown ->
        :unknown
    end
  end

  @doc "Cancels one task in flight, then starts the waiting one, if any."
  @spec cancel(t(), String.t(), LiveTranscript.t()) ::
          {:ok, t(), [told()]} | {:error, :unknown_delegation}
  def cancel(%__MODULE__{} = tasks, id, transcript) when is_binary(id) do
    case fetch(tasks, id) do
      {:ok, record} ->
        {tasks, told} = emit(start_next(cancel_delegation(tasks, record), transcript))
        {:ok, tasks, told}

      :error ->
        {:error, :unknown_delegation}
    end
  end

  @doc """
  The call is ending: a private call cancels its tasks, and a call in the
  chat hands its running one over, and the waiting one behind it when its
  words were heard (M56 §4.6).
  """
  @spec leave(t(), LiveTranscript.t()) :: {t(), [told()]}
  def leave(%__MODULE__{conversation: "private"} = tasks, _transcript) do
    tasks =
      tasks.delegations
      |> LiveDelegation.in_flight()
      |> Enum.reduce(tasks, &cancel_delegation(&2, &1))

    emit({tasks, []})
  end

  def leave(%__MODULE__{conversation: "chat"} = tasks, transcript) do
    tasks =
      tasks.delegations
      |> LiveDelegation.in_flight()
      |> Enum.reduce(tasks, &hand_over(&1, &2, transcript))

    emit({tasks, if(tasks.detached == %{}, do: [], else: [:handed_over])})
  end

  @doc "Cancels the one bounded context wait of every task."
  @spec cancel_timers(t()) :: t()
  def cancel_timers(%__MODULE__{} = tasks) do
    Enum.each(Map.values(tasks.context_timers), fn {timer, _revision} ->
      Process.cancel_timer(timer)
    end)

    %{tasks | context_timers: %{}}
  end

  @doc """
  Each event of a handed-over task that reached the session before its route
  was released goes to its new owner, in the order it came, at most `left` of
  them and none waited for.
  """
  @spec forward_detached(t(), non_neg_integer()) :: :ok
  def forward_detached(%__MODULE__{detached: detached} = tasks, left)
      when map_size(detached) > 0 and left > 0 do
    receive do
      {:delegation_event, id, revision, event} when is_map_key(detached, id) ->
        forward_one(Map.fetch!(detached, id), revision, event)
        forward_detached(tasks, left - 1)
    after
      0 -> :ok
    end
  end

  def forward_detached(%__MODULE__{}, _left), do: :ok

  # Only the revision that was handed over has a new owner; an earlier one's
  # late event is dropped, as it would have been on the call.
  defp forward_one({revision, forward}, revision, event), do: :ok = forward.(event)
  defp forward_one({_handed_over, _forward}, _stale_revision, _event), do: :ok

  ## Settling the call

  @typedoc """
  What closing a call reads besides its tasks: why it ended, its settled
  `usage` payload, the whole call's speech, when the call started, whether its
  provider session ever started, and the gist's summariser seams.
  """
  @type ending :: %{
          reason: atom(),
          usage: map(),
          speech: CallSpeech.t(),
          started_at: DateTime.t(),
          provider_started?: boolean(),
          gist_opts: keyword()
        }

  @doc """
  Closes the call's record with its settled usage and answers what the call
  owes the chat (M56 §4.2): `:gist` when a call in the chat said or handed off
  anything, `:row` when it did not, and `:nothing` for a private call, one
  whose provider session never started, and one whose record could not be
  closed. Written before the call's final `usage` frame, from the same
  settled ledger, so the record is the source that frame agrees with.
  """
  @spec close_record(t(), ending()) :: :gist | :row | :nothing
  def close_record(%__MODULE__{record: nil}, _ending), do: :nothing

  def close_record(%__MODULE__{} = tasks, %{reason: reason, usage: usage} = ending)
      when is_atom(reason) and is_map(usage) do
    owes = owes(tasks, ending)

    tasks.record
    |> CallRecord.close(reason, usage, DateTime.utc_now(), tasks.record_opts, owes)
    |> owed_once_closed(owes)
  end

  @doc """
  Leaves the gist and the row a closed call owes to a task under the task
  supervisor, from a snapshot: the session is going, and its stop callers wait
  on it with no timeout. Never waits on the gist. A task that cannot start
  leaves both owed, for the next boot.
  """
  @spec leave_for_chat(t(), ending(), :gist | :row | :nothing) :: :ok
  def leave_for_chat(%__MODULE__{}, _ending, :nothing), do: :ok

  def leave_for_chat(%__MODULE__{} = tasks, ending, owes) when owes in [:gist, :row] do
    case CallGist.start(gist_job(tasks, ending, owes), ending.gist_opts) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "voice call: the gist of call #{tasks.call_uuid} could not be started " <>
            "(#{inspect(reason)}); the next boot writes its row"
        )
    end
  end

  ## Admission and submission

  # A new task, or a revised one, runs now when it holds the running slot, and
  # waits behind it otherwise.
  defp admit(tasks, id, transcript, await_words?) do
    {:ok, record} = fetch(tasks, id)
    tasks = record_task(tasks, record, "created")

    case LiveDelegation.active(tasks.delegations) do
      %{id: ^id} when await_words? -> {arm_context_wait(tasks, record), []}
      %{id: ^id} -> submit_or_wait(tasks, record, transcript)
      _other -> {notify_task(tasks, record, "pending", nil), []}
    end
  end

  defp submit_or_wait(tasks, record, transcript) do
    if LiveTranscript.sufficient?(transcript, record.offset_ms, @context_window_ms) do
      submit_delegation(tasks, record, transcript)
    else
      {arm_context_wait(tasks, record), []}
    end
  end

  # The ONE bounded wait. A task arrives a moment before the transcript delta
  # that explains it, so waiting once is right — waiting twice, or guessing, is
  # how a partial sentence becomes a consequential action.
  defp submit_or_clarify(tasks, record, transcript) do
    if LiveTranscript.sufficient?(transcript, record.offset_ms, @context_window_ms) do
      submit_delegation(tasks, record, transcript)
    else
      tasks = settle_delegation(tasks, record, :failed, "insufficient_context")
      then_next(tasks, [{:clarify, record}], transcript)
    end
  end

  defp submit_delegation(tasks, record, transcript) do
    case access_answer(tasks, record, transcript) do
      {:confirmed, intent_id} ->
        {confirm_access(%{tasks | access_window: nil}, record, intent_id, transcript), []}

      :declined ->
        submit_to_bridge(%{tasks | access_window: nil}, record, transcript)

      _no_window_or_no_answer ->
        submit_to_bridge(tasks, record, transcript)
    end
  end

  defp submit_to_bridge(tasks, record, transcript) do
    case submit(tasks, record, transcript) do
      {:ok, tasks} ->
        {tasks, []}

      {:error, tasks} ->
        tasks = settle_delegation(tasks, record, :failed, "submit_failed")
        then_next(tasks, [{:submit_failed, record}], transcript)
    end
  end

  # The text is built once: what the bridge is given is what the turn persists
  # and what the record keeps (M56 §4.1).
  defp submit(tasks, record, transcript) do
    turn_session_id = mint_turn_session_id()
    text = request_text(tasks, record, transcript)
    request = delegation_request(tasks, record, turn_session_id, text)
    tasks = %{tasks | turn_sessions: Map.put(tasks.turn_sessions, record.id, turn_session_id)}

    callbacks = delegation_callbacks(record.id, record.revision)

    case tasks.bridge.submit(tasks.handle, request, callbacks) do
      {:ok, task_ref} ->
        {:ok, tasks |> close_exchange(transcript) |> run_delegation(record, task_ref, text)}

      {:error, reason} ->
        Logger.warning("voice call: the bridge refused task #{record.id}: #{inspect(reason)}")
        {:error, tasks}
    end
  end

  # A task raised after a settled task's reply asked the owner to confirm the
  # command that task's own turn parked is read against what the owner said
  # since (`Capabilities.AccessGate`). A whole-utterance yes runs the recorded
  # command here, with no Fermix turn that could issue it again; anything else
  # drops the command and the task goes to Fermix as usual. A task with no owner
  # speech behind it (raised before the question) is no answer, and the command
  # waits.
  defp access_answer(
         %{access_window: {intent_id, since}},
         %{offset_ms: offset_ms},
         transcript
       )
       when offset_ms > since do
    case LiveTranscript.user_text_since(transcript, since) do
      "" -> :no_answer
      text -> AccessGate.answer_spoken(intent_id, text)
    end
  end

  defp access_answer(_tasks, _record, _transcript), do: :no_window

  # Every settle decides the answer window afresh. Only a task that completed,
  # and whose own turn parked a command still waiting, opens one: its reply is
  # what asked the owner. A failed or cancelled one (its reply, if any, asked
  # nothing) and a reply from a turn that parked nothing close it, so a yes the
  # owner said to something else can never confirm the command.
  defp settle_access_window(tasks, record, :completed, transcript),
    do: %{tasks | access_window: parked_by(tasks, record, transcript)}

  defp settle_access_window(tasks, _record, _failed_or_cancelled, _transcript),
    do: %{tasks | access_window: nil}

  defp parked_by(tasks, record, transcript) do
    with {:ok, turn_session_id} <- Map.fetch(tasks.turn_sessions, record.id),
         {:ok, intent_id} <- AccessPending.pending_from(turn_session_id),
         since when is_integer(since) <- LiveTranscript.latest_user_end_ms(transcript) do
      {intent_id, since}
    else
      _nothing_parked -> nil
    end
  end

  # The same bookkeeping and bookends as a submitted task. No bridge task backs
  # it (`bridge_ref: nil`), so cancelling it makes no bridge call.
  defp confirm_access(tasks, record, intent_id, transcript) do
    task =
      Task.Supervisor.async_nolink(FermixCore.TaskSupervisor, fn ->
        AccessGate.confirm(intent_id)
      end)

    confirms = Map.put(tasks.access_confirms, task.ref, {record.id, record.revision})

    run_delegation(
      %{tasks | access_confirms: confirms},
      record,
      nil,
      request_text(tasks, record, transcript)
    )
  end

  defp access_outcome({ref, {status, outcome}}, confirms)
       when is_reference(ref) and is_map_key(confirms, ref) and status in [:ok, :error] and
              is_binary(outcome) do
    Process.demonitor(ref, [:flush])
    {:ok, ref, spoken(status, outcome)}
  end

  defp access_outcome({:DOWN, ref, :process, _pid, reason}, confirms)
       when is_map_key(confirms, ref) do
    Logger.error("voice call: a confirmed access-sensitive command crashed: #{inspect(reason)}")
    {:ok, ref, {:error, AccessGate.outcome_unknown_text()}}
  end

  defp access_outcome(_message, _confirms), do: :unknown

  defp spoken(:ok, outcome), do: {:ok, "The owner said yes. " <> outcome}
  defp spoken(:error, outcome), do: {:error, outcome}

  # A cancelled or superseded task is already settled; its late outcome is
  # dropped.
  defp access_result(tasks, {id, revision}, result, transcript) do
    case fetch(tasks, id) do
      {:ok, %{revision: ^revision} = record} ->
        event({:result, result}, record, tasks, transcript)

      _gone_or_superseded ->
        {tasks, []}
    end
  end

  defp delegation_request(tasks, record, turn_session_id, text) do
    %{
      call_id: tasks.call_id,
      delegation_id: record.id,
      revision: record.revision,
      turn_session_id: turn_session_id,
      text: text,
      screen_frame: nil,
      outside_sources: tasks.outside_sources
    }
  end

  # In the chat's conversation a hand-off's request is the exchange since the
  # previous one, speaker labelled and bounded (M56 §4.1): it is persisted in
  # the chat's history, where the overlapping window would store the same words
  # twice. A private call keeps the window it always had. What the voice model
  # said the task was follows the owner's words, labelled as its own.
  defp request_text(tasks, record, transcript) do
    words =
      case tasks.conversation do
        "chat" -> LiveText.tail(exchange_text(tasks, record, transcript), @exchange_max_bytes)
        "private" -> window_text(record, transcript)
      end

    with_voice_request(words, Map.get(tasks.voice_requests, record.id))
  end

  defp with_voice_request(words, nil), do: words

  defp with_voice_request(words, voice_request),
    do: words <> "\n" <> "voice model's summary of the request: " <> voice_request

  defp exchange_text(%{exchange_since_ms: nil}, _record, transcript),
    do: LiveTranscript.exchange_since(transcript, nil)

  # A voice can raise two tasks from one sentence, and the second then has no
  # word of the owner's after the first went out. A request without the words
  # that asked for it is no request, so it is sent the window, the sentence
  # included, as a private call's would be.
  defp exchange_text(tasks, record, transcript) do
    case LiveTranscript.user_text_since(transcript, tasks.exchange_since_ms) do
      "" -> window_text(record, transcript)
      _new_words -> LiveTranscript.exchange_since(transcript, tasks.exchange_since_ms)
    end
  end

  defp window_text(record, transcript),
    do: LiveTranscript.context_since(transcript, record.offset_ms, @context_window_ms)

  # The request is with the bridge: the next one starts after what it carried.
  defp close_exchange(tasks, transcript) do
    case LiveTranscript.latest_end_ms(transcript) do
      nil -> tasks
      end_ms -> %{tasks | exchange_since_ms: end_ms}
    end
  end

  # The record keeps the words the task ran with: what was submitted to the
  # bridge, or, for a confirmed command, what the owner said around the yes. A
  # private call is kept apart from the chat, and its record keeps none.
  defp run_delegation(tasks, record, task_ref, text) do
    {:ok, delegations} =
      LiveDelegation.start(tasks.delegations, record.id, task_ref, record.revision)

    tasks = %{tasks | delegations: delegations}
    LiveTelemetry.delegation_start(tasks.meta, delegation_meta(tasks, record))

    tasks
    |> record_task(record, "running", recorded_request(tasks, text))
    |> notify_task(record, "running", nil)
  end

  defp recorded_request(%{conversation: "chat"}, text), do: %{request: text}
  defp recorded_request(%{conversation: "private"}, _text), do: %{}

  # The closures run in the BRIDGE's process, so they do exactly one thing:
  # forward to this session's mailbox, naming the revision they belong to.
  # Anything heavier would run a voice call's work inside an agent turn's
  # process.
  defp delegation_callbacks(id, revision) do
    session = self()
    forward = fn event -> send(session, {:delegation_event, id, revision, event}) end

    %{
      progress: fn text -> forward.({:progress, text}) end,
      activity: fn event -> forward.({:activity, event}) end,
      history_tainted: fn -> forward.(:history_tainted) end,
      outside_sources: fn sources -> forward.({:outside_sources, sources}) end,
      result: fn result -> forward.({:result, result}) end
    }
  end

  ## A running task's events

  defp event({:progress, text}, record, tasks, _transcript) when is_binary(text),
    do: {tasks, [{:progress, record, text}]}

  defp event({:activity, {:tool_start, name}}, record, tasks, _transcript) when is_binary(name) do
    if throttled?(tasks, record.id) do
      {tasks, []}
    else
      last = Map.put(tasks.last_activity_ms, record.id, now(tasks))
      {%{tasks | last_activity_ms: last}, [{:tool_started, record, name}]}
    end
  end

  defp event({:activity, _event}, _record, tasks, _transcript), do: {tasks, []}

  # Sent by the turn's own process before its reply, so it is here first. The
  # call keeps the mark after the task settles: its gist inherits it.
  defp event(:history_tainted, record, tasks, _transcript) do
    tainted = MapSet.put(tasks.history_tainted, record.id)
    {%{tasks | history_tainted: tainted, tainted?: true}, []}
  end

  # Sent by the turn's own process before its reply, as the mark above is. The
  # call keeps it for every later hand-off. A revision the task moved past has
  # its event dropped with the rest (`delegation_event/5`), which holds only
  # while nothing of a replaced revision reaches the voice model: relaying its
  # progress text would have to carry what it read too.
  defp event({:outside_sources, %MapSet{} = sources}, _record, tasks, _transcript),
    do: {%{tasks | outside_sources: MapSet.union(tasks.outside_sources, sources)}, []}

  defp event({:result, {:ok, text}}, record, tasks, transcript) when is_binary(text) do
    answer = answer(tasks, record, text)
    tasks = settle_delegation(tasks, record, :completed, answer.summary, answer.shown, transcript)
    then_next(tasks, [{:completed, record, answer.spoken}], transcript)
  end

  defp event({:result, {:cancelled}}, record, tasks, transcript) do
    tasks = settle_delegation(tasks, record, :cancelled, "cancelled")
    then_next(tasks, [{:cancelled, record}], transcript)
  end

  defp event({:result, {:error, reason}}, record, tasks, transcript) do
    text = reason_text(reason)
    tasks = settle_delegation(tasks, record, :failed, LiveText.summary(text, @summary_max_chars))
    then_next(tasks, [{:failed, record, LiveText.sentence(text, @spoken_max_bytes)}], transcript)
  end

  defp event(event, record, tasks, _transcript) do
    Logger.debug("voice call: unhandled task event #{inspect(event)} for #{record.id}")
    {tasks, []}
  end

  defp then_next(tasks, told, transcript) do
    {tasks, next_told} = start_next(tasks, transcript)
    {tasks, told ++ next_told}
  end

  defp start_next(tasks, transcript) do
    case LiveDelegation.next_to_start(tasks.delegations) do
      {:ok, record, delegations} ->
        submit_or_wait(%{tasks | delegations: delegations}, record, transcript)

      :none ->
        {tasks, []}
    end
  end

  defp throttled?(tasks, id) do
    case Map.get(tasks.last_activity_ms, id) do
      nil -> false
      last -> now(tasks) - last < @tool_progress_interval_ms
    end
  end

  ## A task's reply: what is said and what is shown

  # M56 §4.5 and §9: what of a task's reply the voice is given to say, the
  # summary its task frame carries, and the chat row its result was shown at.
  # A reply drawn from Computer History reaches the voice only when its
  # provider may carry it, and a private call shows nothing.
  defp answer(tasks, record, text) do
    parts = LiveText.split(text, @spoken_max_bytes)

    case {tasks.conversation, voice_may_carry?(tasks, record)} do
      {"private", true} -> said(text)
      {"private", false} -> withheld(@withheld_private_line, nil)
      {"chat", true} -> said_and_shown(tasks, record, parts)
      {"chat", false} -> shown_only(tasks, record, parts)
    end
  end

  defp voice_may_carry?(tasks, record),
    do:
      not MapSet.member?(tasks.history_tainted, record.id) or
        LiveChat.history_permitted?(tasks.voice_provider)

  # Every result of a private call, as every result was before: the reply cut
  # to a sentence, nothing shown.
  defp said(text) do
    %{
      spoken: LiveText.sentence(text, @spoken_max_bytes),
      summary: LiveText.summary(text, @summary_max_chars),
      shown: nil
    }
  end

  defp said_and_shown(_tasks, _record, {spoken, nil}), do: said(spoken)

  # The voice is told the rest is in the chat only once it is: a write that
  # failed leaves the line it says as it was.
  defp said_and_shown(tasks, record, {spoken, shown}) do
    case show(tasks, record, shown) do
      {:ok, row} ->
        budget = @spoken_max_bytes - byte_size(@in_chat_line) - 1

        %{
          spoken: LiveText.sentence(spoken, budget) <> " " <> @in_chat_line,
          summary: LiveText.summary(spoken, @summary_max_chars),
          shown: row
        }

      :error ->
        said(spoken)
    end
  end

  # The whole reply is shown (the chat is local) and none of it is said.
  defp shown_only(tasks, record, parts) do
    case show(tasks, record, whole(parts)) do
      {:ok, row} -> withheld(@withheld_shown_line, row)
      :error -> withheld(@withheld_unshown_line, nil)
    end
  end

  defp withheld(line, shown), do: %{spoken: line, summary: line, shown: shown}

  # The reply as written, its delimiter line aside.
  defp whole({spoken, nil}), do: spoken
  defp whole({spoken, spoken}), do: spoken
  defp whole({spoken, shown}), do: spoken <> "\n\n" <> shown

  # One row per task revision, written through the bridge, which answers the
  # row's `server_seq`. A write that fails is logged and the call goes on.
  defp show(tasks, record, text) do
    call = %{
      "uuid" => tasks.call_uuid,
      "event" => "shared",
      "task_id" => record.id,
      "revision" => record.revision
    }

    case bridge_call(fn -> tasks.bridge.show(call, text) end) do
      {:ok, server_seq} when is_integer(server_seq) and server_seq > 0 ->
        {:ok, %{server_seq: server_seq, bytes: byte_size(text)}}

      {:error, reason} ->
        Logger.error(
          "voice call: the result of #{record.id} could not be shown in the chat: " <>
            inspect(reason)
        )

        :error
    end
  end

  # The third task. The companion gets the refusal as a task frame rather than
  # nothing at all; the voice is told by the caller.
  defp refuse(tasks, id) do
    refused = %{id: id, revision: 1}

    tasks
    |> record_task(refused, "failed", %{summary: "busy"})
    |> notify_task(refused, "failed", "busy")
  end

  defp cancel_delegation(tasks, record) do
    cancel_on_bridge(tasks, record)
    settle_delegation(tasks, record, :cancelled, "cancelled")
  end

  defp cancel_on_bridge(%{handle: nil}, _record), do: :ok
  defp cancel_on_bridge(_tasks, %{bridge_ref: nil}), do: :ok

  defp cancel_on_bridge(tasks, record) do
    case bridge_call(fn -> tasks.bridge.cancel(tasks.handle, record.bridge_ref) end) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("voice call: cancel of #{record.id} failed: #{inspect(reason)}")
        :ok
    end
  end

  # `shown` is the chat row a completed result was shown at, `nil` when nothing
  # was shown (M56 §4.5). Only a completion reads the transcript: it decides
  # whether its reply opened an access window.
  defp settle_delegation(tasks, record, status, summary, shown \\ nil, transcript \\ nil) do
    meta = delegation_meta(tasks, record)

    tasks =
      case terminal(tasks.delegations, record.id, status, summary) do
        {:ok, finished, delegations} ->
          LiveTelemetry.delegation_stop(
            tasks.meta,
            meta,
            Atom.to_string(status),
            duration_ms(tasks, record),
            shown
          )

          %{tasks | delegations: delegations}
          |> record_task(finished, Atom.to_string(status), %{summary: summary})
          |> notify_task(finished, Atom.to_string(status), summary, shown_seq(shown))

        {:error, :unknown_delegation} ->
          tasks
      end

    tasks
    |> settle_access_window(record, status, transcript)
    |> forget_delegation(record.id)
  end

  # The earlier revision of a task the voice asked again for: its record and
  # frame say it was replaced, and its slot stays the task's.
  defp settle_superseded(tasks, record) do
    LiveTelemetry.delegation_stop(
      tasks.meta,
      delegation_meta(tasks, record),
      "cancelled",
      duration_ms(tasks, record),
      nil
    )

    tasks
    |> record_task(record, "cancelled", %{summary: @superseded_summary})
    |> notify_task(record, "cancelled", @superseded_summary)
    |> forget_revision(record.id)
  end

  defp terminal(delegations, id, :completed, summary),
    do: LiveDelegation.complete(delegations, id, summary)

  defp terminal(delegations, id, :failed, summary),
    do: LiveDelegation.fail(delegations, id, summary)

  defp terminal(delegations, id, :cancelled, _summary), do: LiveDelegation.cancel(delegations, id)

  defp shown_seq(nil), do: nil
  defp shown_seq(%{server_seq: server_seq}), do: server_seq

  defp forget_delegation(tasks, id) do
    %{
      forget_revision(tasks, id)
      | history_tainted: MapSet.delete(tasks.history_tainted, id),
        voice_requests: Map.delete(tasks.voice_requests, id)
    }
  end

  # What one revision of a task held: its turn, its activity clock and its
  # context wait. The task's taint and the voice's words outlive a revision.
  defp forget_revision(tasks, id) do
    %{
      tasks
      | turn_sessions: Map.delete(tasks.turn_sessions, id),
        last_activity_ms: Map.delete(tasks.last_activity_ms, id),
        context_timers: cancel_context_timer(tasks.context_timers, id)
    }
  end

  defp put_voice_request(tasks, _id, nil), do: tasks

  defp put_voice_request(tasks, id, voice_request),
    do: %{tasks | voice_requests: Map.put(tasks.voice_requests, id, voice_request)}

  ## A task that outlives its call (M56 §4.6)

  # A confirmed access-sensitive command has no turn to hand over, and is
  # cancelled as before; a task not yet submitted is started now when its
  # words were heard, and dropped otherwise.
  defp hand_over(%{status: :running, bridge_ref: nil} = record, tasks, _transcript),
    do: cancel_delegation(tasks, record)

  defp hand_over(%{status: :running} = record, tasks, _transcript),
    do: detach_delegation(tasks, record)

  defp hand_over(record, tasks, transcript) do
    if LiveTranscript.sufficient?(transcript, record.offset_ms, @context_window_ms),
      do: submit_at_end(tasks, record, transcript),
      else: settle_delegation(tasks, record, :failed, @dropped_summary)
  end

  defp submit_at_end(tasks, record, transcript) do
    case submit(tasks, record, transcript) do
      {:ok, tasks} ->
        {:ok, running} = fetch(tasks, record.id)
        detach_delegation(tasks, running)

      {:error, tasks} ->
        settle_delegation(tasks, record, :failed, "submit_failed")
    end
  end

  # The ordered transfer: (1) the record says the task is detached, its result
  # going to the chat; (2) the bridge's owner registers the task's route and
  # (3) the session's own is released; the call closes after. A reply finds
  # one route or the other throughout (`VoiceBridge.detach/3`). A task the
  # owner will not take stays this call's, and is cancelled.
  defp detach_delegation(tasks, record) do
    tasks =
      record_task(tasks, record, "detached", %{summary: @detached_summary, destination: "chat"})

    handover = fn ->
      tasks.bridge.detach(tasks.handle, record.bridge_ref, detached_task(tasks, record))
    end

    case bridge_call(handover) do
      {:ok, forward} when is_function(forward, 1) -> detached(tasks, record, forward)
      {:error, reason} -> not_kept(tasks, record, reason)
    end
  end

  defp detached(tasks, record, forward) do
    {:ok, _detached, delegations} = LiveDelegation.detach(tasks.delegations, record.id)

    detached = Map.put(tasks.detached, record.id, {record.revision, forward})

    %{tasks | delegations: delegations, detached: detached}
    |> notify_task(record, "running", @detached_summary, nil, true)
    |> forget_delegation(record.id)
  end

  defp not_kept(tasks, record, reason) do
    Logger.warning(
      "voice call: #{record.id} could not be handed over as the call ended " <>
        "(#{inspect(reason)}); it is cancelled"
    )

    cancel_on_bridge(tasks, record)
    settle_delegation(tasks, record, :cancelled, not_kept_summary(reason))
  end

  defp not_kept_summary(:full), do: @not_kept_full_summary
  defp not_kept_summary(_reason), do: @not_kept_summary

  defp detached_task(tasks, record) do
    %{
      delegation_id: record.id,
      revision: record.revision,
      request: task_request(tasks.record, record),
      turn_session_id: Map.fetch!(tasks.turn_sessions, record.id),
      elapsed_ms: duration_ms(tasks, record),
      record_opts: tasks.record_opts,
      engine: Map.fetch!(tasks.meta, :engine),
      provider: Map.fetch!(tasks.meta, :provider)
    }
  end

  # The words the task ran with, as its record keeps them. A task the record
  # no longer holds (past its newest 64) has none to show.
  defp task_request(%CallRecord{tasks: tasks}, record) do
    Enum.find_value(tasks, "", fn task ->
      if task["task_id"] == record.id and task["revision"] == record.revision,
        do: task["request"] || ""
    end)
  end

  # Teardown has to finish even when the bridge process is already gone: the
  # ledger, the `call_stop` telemetry and the companion's final frames are what
  # is left of the call, and losing them to a dead peer is a worse outcome than
  # a logged close failure. A result shown in the chat is the same: a write
  # that raised or exited is a write that failed, and the call goes on.
  # Reported, never silent.
  defp bridge_call(fun) do
    fun.()
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  ## The call record

  # Every task state is written as it happens, so a crash loses nothing the
  # call had already done.
  defp record_task(tasks, record, task_state, fields \\ %{}) do
    call_record =
      CallRecord.put_task(tasks.record, record.id, record.revision, task_state, fields)

    report_record(CallRecord.write_tasks(call_record, tasks.record_opts), "write")
    %{tasks | record: call_record}
  end

  # M56 §4.2: a call in the chat owes the chat its row, and its gist when it
  # said or handed off anything; a private call (M56 §5), and one whose
  # provider session never started, owe nothing.
  defp owes(_tasks, %{provider_started?: false}), do: :nothing
  defp owes(%{conversation: "private"}, _ending), do: :nothing

  defp owes(tasks, ending),
    do: if(said_anything?(tasks, ending), do: :gist, else: :row)

  defp said_anything?(tasks, ending),
    do: not CallSpeech.empty?(ending.speech) or recorded_tasks(tasks) != []

  # A close that failed leaves no record to settle a gist or a row against.
  defp owed_once_closed(:ok, owes), do: owes

  defp owed_once_closed(failed, _owes) do
    report_record(failed, "close")
    :nothing
  end

  defp gist_job(tasks, ending, owes) do
    bridge = tasks.bridge

    %{
      call_uuid: tasks.call_uuid,
      speech: ending.speech,
      tasks: recorded_tasks(tasks),
      tainted?: tasks.tainted?,
      duration_s: max(0, DateTime.diff(DateTime.utc_now(), ending.started_at)),
      gist?: owes == :gist,
      write_row: &bridge.show/2,
      repo_opts: tasks.record_opts
    }
  end

  defp report_record(:ok, _action), do: :ok

  # Memory off is a configuration: there is no table to write.
  defp report_record({:error, :disabled}, _action), do: :ok

  defp report_record({:error, reason}, action) do
    Logger.error("voice call: could not #{action} the call record: #{inspect(reason)}")
  end

  ## Frames, timers, telemetry

  defp notify_task(tasks, record, status, summary, server_seq \\ nil, detached? \\ false) do
    frame =
      LiveFrames.task(
        tasks.call_uuid,
        record.id,
        record.revision,
        status,
        summary,
        server_seq,
        detached?
      )

    %{tasks | outbox: [frame | tasks.outbox]}
  end

  # The step's frames go after what the voice is told, in the order they were
  # made, and the outbox starts the next step empty.
  defp emit({tasks, told}) do
    frames = tasks.outbox |> Enum.reverse() |> Enum.map(&{:frame, &1})
    {%{tasks | outbox: []}, told ++ frames}
  end

  defp arm_context_wait(tasks, record) do
    tasks = %{tasks | context_timers: cancel_context_timer(tasks.context_timers, record.id)}
    message = {:context_wait_expired, record.id, record.revision}
    timer = Process.send_after(self(), message, tasks.context_wait_ms)
    %{tasks | context_timers: Map.put(tasks.context_timers, record.id, {timer, record.revision})}
  end

  defp cancel_context_timer(timers, id) do
    case Map.pop(timers, id) do
      {nil, timers} ->
        timers

      {{timer, _revision}, timers} ->
        Process.cancel_timer(timer)
        timers
    end
  end

  defp delegation_meta(tasks, record) do
    %{
      delegation_id: record.id,
      revision: record.revision,
      turn_session_id: Map.get(tasks.turn_sessions, record.id, "voice_delegation_unstarted")
    }
  end

  defp duration_ms(tasks, record), do: max(0, now(tasks) - record.created_at_ms)

  defp mint_turn_session_id do
    "voice_delegation_" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason), do: inspect(reason)

  defp now(tasks), do: tasks.clock.()
end
