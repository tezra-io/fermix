defmodule FermixCore.Realtime.VoiceBridge do
  @moduledoc """
  The seam between a Live voice session and the Fermix agent that answers for it.

  Under the `openai_live` engine the provider speaks but never runs a tool: every
  piece of work is delegated back to Core through this behaviour, which
  `fermix_channels` implements and registers at boot
  (`Application.put_env(:fermix_core, :voice_bridge, FermixChannels.Voice.Bridge)`,
  the same pattern as `:queue_status_provider`). Core therefore never names a
  Channels module; it resolves one, and refuses loudly when none is registered.

  A `call_handle` is opaque to the session: it is whatever the implementation
  needs to route a turn (conversation store, owner pid, call id). One handle
  lives for one call; one `task_ref` for one delegation.

  `cancel/2` and `close_call/1` return once the work is stopped. They carry no
  deadline of their own and must stay bounded: the session runs them inside
  calls its own callers wait on with no timeout (`SessionControl`).

  `conversation_window/1` is not call-scoped: a call in the chat's
  conversation reads it before `session.start`, when no handle exists yet, so
  it is a plain function of the module (M56 §4.3). A private call never calls
  it. Nor are `call_active?/0` and `chat_call/1`, which Core asks for a turn
  that is not the call's own (M56 §4.4): whether a call in the chat is up (for
  `voice_call_context`), and how a turn of the chat is told of it. Channels
  answers both, because the chat is its to name and the clients attached to it
  are its to count; a private call is no call in the chat.

  Nor is `show/2` (M56 §4.2, §4.5): it writes a row of the call to the chat's
  timeline, announced to the Mac and the phones, and answers the row's
  `server_seq`. The timeline's writer is the companion channel, which Core
  never names, so a result the voice cannot say, and the call's one row when
  it ends, reach the chat through here; the latter from a task the session
  spawned, or at boot, after the session is gone.

  `detach/3` hands a running task over as a call in the chat ends (M56 §4.6):
  the bridge gives it to an owner that outlives the session, which takes the
  task's reply route before the session's own is released, and answers a
  function the session forwards the task's events with, for the ones that
  reached it while it settled. Only a call in the chat detaches; a private
  call's tasks are cancelled as before.

  A running turn reports one fact besides its progress and its result:
  `history_tainted`, before the result, when the turn read Computer History
  content and its reply will carry the stamp (M56 §9), so the session never
  gives that reply to a voice provider that may not carry it.
  """

  @typedoc """
  One voice call, opened once per `call_start` and closed once per `call_stop`.
  `call_uuid` is its durable identity; `conversation` (`"chat"` or `"private"`,
  M56 §5) says whether its hand-offs run in the chat's conversation or in one of
  the call's own.
  """
  @type call :: %{
          call_id: String.t(),
          call_uuid: String.t(),
          conversation: String.t(),
          device_id: String.t(),
          persist?: boolean(),
          session_scope: String.t()
        }

  @typedoc """
  One delegation of a call. `turn_session_id` is minted by the SESSION (as
  `voice_delegation_<n>`) so the agent turn it produces is correlatable, and
  `revision` fences a re-asked task against a late answer to the earlier one.
  """
  @type request :: %{
          call_id: String.t(),
          delegation_id: String.t(),
          revision: pos_integer(),
          turn_session_id: String.t(),
          text: String.t(),
          screen_frame: nil | %{mime_type: String.t(), data: binary()}
        }

  @typedoc """
  How the running turn reports back. Each is called from the bridge's process,
  so an implementation must not block in them: the session's closures only
  forward the event to the session's own mailbox.
  """
  @type callbacks :: %{
          progress: (String.t() -> :ok),
          activity: (term() -> :ok),
          history_tainted: (-> :ok),
          result: ({:ok, String.t()} | {:cancelled} | {:error, String.t()} -> :ok)
        }

  @typedoc """
  The `call` map of a row a Live call writes to the chat (M56 §6), string
  keyed as the timeline stores it in the row's `metadata`;
  `FermixCore.Companion.Protocol.validate_call_metadata/1` holds its shape. A
  result shown during the call is `%{"uuid", "event" => "shared", "task_id",
  "revision"}`; the call's one row when it ends (M56 §4.2) is
  `%{"uuid", "event" => "ended", "engine", "duration_s", "voice_cost_cents",
  "accounting", "gist_status"}`, as `Realtime.CallRow` renders it.
  """
  @type shown_call :: %{required(String.t()) => String.t() | pos_integer()}

  @typedoc """
  A running task a call in the chat hands over as it ends (M56 §4.6): its ids,
  the request it ran with, its turn's session id, how long it had run, and the
  Repo options of the call's record, which its new owner writes its end to.
  """
  @type detached_task :: %{
          delegation_id: String.t(),
          revision: pos_integer(),
          request: String.t(),
          turn_session_id: String.t(),
          elapsed_ms: non_neg_integer(),
          record_opts: keyword()
        }

  @typedoc """
  What forwards a detached task's event, as the session's own callbacks were
  given it (`{:result, result}`, `:history_tainted`, `{:progress, text}`,
  `{:activity, event}`), to its new owner.
  """
  @type forward :: (term() -> :ok)

  @typedoc "How much of the chat a call starts with (`LiveChat.window_bounds/0`)."
  @type window_bounds :: %{messages: pos_integer(), gists: non_neg_integer()}

  @typedoc """
  The chat as a call starts with it (M56 §4.3, D6): the chat's newest user and
  assistant messages, at most `messages`, oldest first, as the conversation
  store holds them (a Computer History taint marker included, for Core to mask
  against the voice provider), and the gists of the newest earlier calls, at
  most `gists`, newest first, as `CallRecord.recent_gists/2` reads them (their
  own mark included). Never a tool result, a checkpoint summary or any other
  system message.
  """
  @type conversation_window :: %{
          messages: [map()],
          gists: [FermixCore.Realtime.CallRecord.gist()]
        }

  @typedoc """
  A call in the chat, as a turn of the chat is told of it (M56 §4.4): when it
  started, and whether that turn may end with no reply, which it may only
  while every companion client attached reads a turn that ends that way
  (companion protocol 2).
  """
  @type chat_call :: %{started_at: DateTime.t(), silence_allowed?: boolean()}

  @callback conversation_window(window_bounds()) ::
              {:ok, conversation_window()} | {:error, term()}
  @callback call_active?() :: boolean()
  @callback chat_call(FermixCore.Agents.ConversationKey.t()) :: {:ok, chat_call()} | :none
  @callback show(shown_call(), String.t()) ::
              {:ok, server_seq :: pos_integer()} | {:error, term()}
  @callback open_call(call()) :: {:ok, call_handle :: term()} | {:error, term()}
  @callback submit(call_handle :: term(), request(), callbacks()) ::
              {:ok, task_ref :: term()} | {:error, term()}
  @callback cancel(call_handle :: term(), task_ref :: term()) :: :ok | {:error, term()}
  @callback detach(call_handle :: term(), task_ref :: term(), detached_task()) ::
              {:ok, forward()} | {:error, term()}
  @callback close_call(call_handle :: term()) :: :ok

  @doc """
  The registered bridge implementation.

  `{:error, :voice_bridge_unavailable}` means no channel application registered
  one — a Live call refuses at `call_start` rather than starting a session that
  can never answer. A registered value that is not a module is a configuration
  error and raises.
  """
  @spec resolve() :: {:ok, module()} | {:error, :voice_bridge_unavailable}
  def resolve do
    case Application.get_env(:fermix_core, :voice_bridge) do
      nil ->
        {:error, :voice_bridge_unavailable}

      module when is_atom(module) ->
        {:ok, module}

      other ->
        raise ArgumentError,
              ":voice_bridge must be a module, got: #{inspect(other)}"
    end
  end
end
