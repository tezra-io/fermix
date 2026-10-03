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

  `conversation_window/1` is the one callback that is not call-scoped: a call
  in the chat's conversation reads it before `session.start`, when no handle
  exists yet, so it is a plain function of the module (M56 §4.3). A private
  call never calls it.
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
          result: ({:ok, String.t()} | {:cancelled} | {:error, String.t()} -> :ok)
        }

  @typedoc "How much of the chat a call starts with (`LiveChat.window_bounds/0`)."
  @type window_bounds :: %{messages: pos_integer(), gists: non_neg_integer()}

  @typedoc """
  The chat as a call starts with it (M56 §4.3, D6): the chat's newest user and
  assistant messages, at most `messages`, oldest first, as the conversation
  store holds them (a Computer History taint marker included, for Core to mask
  against the voice provider), and the gists of the newest earlier calls, at
  most `gists`, newest first. Never a tool result, a checkpoint summary or any
  other system message.
  """
  @type conversation_window :: %{messages: [map()], gists: [String.t()]}

  @callback conversation_window(window_bounds()) ::
              {:ok, conversation_window()} | {:error, term()}
  @callback open_call(call()) :: {:ok, call_handle :: term()} | {:error, term()}
  @callback submit(call_handle :: term(), request(), callbacks()) ::
              {:ok, task_ref :: term()} | {:error, term()}
  @callback cancel(call_handle :: term(), task_ref :: term()) :: :ok | {:error, term()}
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
