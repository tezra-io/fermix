defmodule FermixChannels.Mobile.Peers do
  @moduledoc """
  Who may send what on the mobile wire (M75 §5.3): the one table of session
  kind × event.

  A session's kind is what its handshake proved: `phone` and `desktop` are a
  paired device's (Noise `IK`, read from the device's row), `enrollment` is a
  candidate primary, or a computer joining the home (M97 §3.1), on an
  enrollment window (`FXM1 0x03`), `move` is the
  source of a move on its candidate (`FXM1 0x04`). The pairing session itself
  (`IKpsk2`, before the owner approved) takes only `pair_request` and `ping`,
  and `Mobile.Session` keeps that rule.

  A client event the codec knows that the session's kind may not send is
  refused with `error{code:"unsupported_event"}` and the connection stays open.
  A server event a kind may not receive is never sent to it: a session drops
  it as an event it cannot encode is dropped.

  A phone's call channel (M87, `call_*`) is the owner's voice on the phone,
  and a computer's whose home moved (M97 §9.2): its app's voice reaches its
  own computer's socket, and its engine carries the call to the server on the
  same channel, without the camera (`call_frame`), which a computer's call
  never takes (D21). So is the phone's upload (`attach_*`), which a computer
  drives for the files its app attaches (§9.3, D22). A computer sends either
  only to a server whose `hello_ack` takes it (`caps.computer`).

  A computer's own record (M97 §3.2) is a desktop's alone: what it offers
  (`offers`) and the path its session runs (`link_path`), each sent only to
  a server whose `hello_ack` says it takes them (`caps.computer`). So is
  the invocation (M97 §6.1, `invoke_*`), which a desktop and its server
  each send the other: the server asking one of the computer's
  capabilities, the computer one of the home's services.

  A phone's list channel (M85 E4) is the companion family's `companion_open`,
  `companion_line` and `companion_close`, which a desktop sends too: one
  channel, carrying the owner's lists only (`Desktop.Companion`). The family's
  other events (`manage`, the loopback forward, the snapshots) stay a
  desktop's.

  Pure.
  """

  @phone_client ~w(
    hello msg attach_begin attach_chunk attach_end command cancel history_pull media_fetch
    push_register push_unregister push_subscribe ack read_state request_status unpair ping
    call_open call_line call_audio call_frame call_close
    companion_open companion_line companion_close
  )
  @desktop_client ~w(
    hello ping media_fetch ack companion_open companion_line companion_close manage
    loopback_request loopback_failed snapshot_stored snapshot_refused offers link_path
    invoke_open invoke_part invoke_cancel invoke_result invoke_status invoke_restarted
    call_open call_line call_audio call_close attach_begin attach_chunk attach_end
  )
  @phone_server ~w(
    hello_ack accepted attach_status turn_started text_delta tool_event text_done turn_done
    media_begin media_chunk media_end turn_error row reaction approval approval_resolved
    link_preview read_state history_page request_status_page notice error pong event_part
    call_attached call_line call_audio call_close companion_line companion_close
  )
  @desktop_server ~w(
    hello_ack error pong event_part media_begin media_chunk media_end companion_line
    companion_close manage_result loopback_open loopback_response loopback_close
    snapshot_begin snapshot_chunk snapshot_end
    invoke_open invoke_part invoke_cancel invoke_result invoke_status
    call_attached call_line call_audio call_close attach_status
  )

  @client %{
    phone: @phone_client,
    desktop: @desktop_client,
    enrollment: ~w(enroll_request join_request ping),
    move: ~w(move_offer move_chunk move_end move_commit move_resume ping)
  }
  @server %{
    phone: @phone_server,
    desktop: @desktop_server,
    enrollment: ~w(enroll_accepted join_approved join_denied error pong),
    move: ~w(move_accept move_ready move_done error pong)
  }
  @kinds [:phone, :desktop, :enrollment, :move]

  @type kind :: :phone | :desktop | :enrollment | :move

  @doc "Every session kind the table names."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "The client events a session of `kind` may send, in table order."
  @spec client_events(kind()) :: [String.t()]
  def client_events(kind) when kind in @kinds, do: Map.fetch!(@client, kind)

  @doc "The server events a session of `kind` may be sent, in table order."
  @spec server_events(kind()) :: [String.t()]
  def server_events(kind) when kind in @kinds, do: Map.fetch!(@server, kind)

  @doc "Whether a session of `kind` may send the client event `type`."
  @spec client_event?(kind(), String.t()) :: boolean()
  def client_event?(kind, type) when kind in @kinds and is_binary(type),
    do: type in Map.fetch!(@client, kind)

  @doc "Whether a session of `kind` may be sent the server event `type`."
  @spec server_event?(kind(), String.t()) :: boolean()
  def server_event?(kind, type) when kind in @kinds and is_binary(type),
    do: type in Map.fetch!(@server, kind)

  @doc """
  Admits a client event from a session of `kind`: `:ok`, or the refusal the
  session answers with `error{code:"unsupported_event"}`, open.
  """
  @spec authorize(kind(), String.t()) :: :ok | {:error, {:unsupported_event, String.t()}}
  def authorize(kind, type) do
    if client_event?(kind, type), do: :ok, else: {:error, {:unsupported_event, type}}
  end
end
