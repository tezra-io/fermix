defmodule FermixChannels.Desktop.CallBridge do
  @moduledoc """
  A voice call from this computer's app to its server (M97 §9.2, D17): the
  bridge a device-role engine serves the app's `realtime.sock` with
  (`FermixCore.Realtime.SocketBridge`, one per connection, in the
  connection's own handler).

  The app keeps its microphone, speaker, echo cancellation and the socket it
  speaks; the server runs the voice session with its own key, tools and
  memory, on its own voice setting (D19). The call rides this computer's
  desktop session on the phone's call channel (`priv/mobile/PROTOCOL.md`,
  *Calls from the phone*), through `Desktop.Relay`, and the server admits it
  as `computer:<device id>` (D18) under the home's one-call lease.

  ## The mapping

  The app's handshake is answered by the socket at this engine's window. At
  the app's `call_start` the bridge opens a call on the server (`call_open`
  under a call id of its own), sends the call's own `client_hello` at the
  app's version, or the server's newest where the app is newer (a computer
  ahead of its server speaks the server's versions), then the `call_start`
  as the first control line. After it, each Realtime line the app sends is
  one `call_line`, word for word, its controls (`call_start`, `mute`,
  `camera`, `interrupt`, `task_cancel`, `call_stop`) numbered `control_seq`,
  and each `audio_chunk` is one or more `call_audio` frames of raw PCM16,
  at most 100 ms each. Down, each `call_line` is written to the app as the
  line it is, but the server's `server_hello`, which belongs to the call
  and not to the connection, and each `call_audio` becomes `audio_delta`
  with its `playback_id`, which the server gives every engine's audio: the
  app reports `playback_progress` against every playback id it is given,
  and the server takes those reports for its 1 s playback credit.

  A call that ends normally (the app's `call_stop`, or the server's
  `call_ended`, or an end the server started with no error) keeps the
  connection for a fresh `call_start`, as the local socket does; an end
  after an error line, or one with no call left to resume, closes it after
  the error, the way the local socket closes after most errors. A bridge
  refusal carries the engine's `sentence`, which the app shows as it is.

  ## A dropped link

  When the desktop session ends mid-call the server holds the call for 20 s.
  The bridge holds it as long: controls the app sends meanwhile wait, its
  audio and playback reports are dropped (the server settles its credit at
  the resume), and the next session sends `call_open{resume: true}`, then
  the call's `client_hello` again if the server never answered it, then the
  controls past the one the server applied (`call_attached.control_seq`).
  Past the 20 s, or once the server no longer knows this computer, the call
  ends with a sentence and the connection closes. A server that finds the
  link silent ends the call alone (D20), `link_too_slow`.

  ## Bounds

  One call a connection; at most 64 controls kept for a resume, the oldest
  dropped past that; every wait is the server's window.
  """

  @behaviour FermixCore.Realtime.SocketBridge

  require Logger

  alias FermixChannels.Desktop.Relay

  # The server holds a call 20 s across a session that closed (M87): the
  # bridge waits as long for the next one.
  @window_ms 20_000
  # The call channel's microphone frame: 100 ms of 24 kHz mono PCM16.
  @frame_bytes 4_800
  @max_controls 64
  # The playback feedback a bridged call needs for every engine came with
  # version 3; an app below it could report none.
  @min_app_version 3
  @controls ~w(call_start mute camera interrupt task_cancel call_stop)

  @enforce_keys [:write, :emit, :relay, :protocol_version, :mint, :window_ms, :schedule]
  defstruct [:write, :emit, :relay, :protocol_version, :mint, :window_ms, :schedule, call: nil]

  @type t :: %__MODULE__{}

  @impl true
  def open(opts) when is_list(opts) do
    %__MODULE__{
      write: function!(opts, :write, 1),
      emit: function!(opts, :emit, 1),
      relay: Keyword.get(opts, :relay, Relay),
      protocol_version: Keyword.fetch!(opts, :protocol_version),
      mint: Keyword.get(opts, :mint, &mint_call_id/0),
      window_ms: Keyword.get(opts, :window_ms, @window_ms),
      schedule: Keyword.get(opts, :schedule, &Process.send_after(self(), &1, &2))
    }
  end

  # -- the app's events ---------------------------------------------------------

  @impl true
  def event(%__MODULE__{call: nil} = bridge, %{type: "call_start"}), do: start_call(bridge)

  def event(%__MODULE__{call: nil} = bridge, %{type: "call_stop"}) do
    _ = bridge.emit.(%{type: "state", state: "idle"})
    {:cont, bridge}
  end

  def event(%__MODULE__{call: nil} = bridge, %{type: type})
      when type in ["audio_chunk", "playback_progress"],
      do: {:cont, bridge}

  def event(%__MODULE__{call: nil} = bridge, %{type: _control}),
    do: refuse(bridge, %{type: "error", reason: "not_connected"})

  def event(%__MODULE__{} = bridge, %{type: "audio_chunk", payload: %{"audio" => pcm}}),
    do: {:cont, audio_up(bridge, pcm)}

  def event(%__MODULE__{} = bridge, %{type: "playback_progress", payload: payload}),
    do: {:cont, line_up(bridge, line("playback_progress", payload))}

  def event(%__MODULE__{} = bridge, %{type: type, payload: payload}) when type in @controls,
    do: {:cont, control(bridge, line(type, payload))}

  # -- the link's frames and the bridge's own timers -------------------------------

  @impl true
  def info(
        %__MODULE__{call: %{id: id}} = bridge,
        {:relay_call, type, %{"call_id" => id} = f, tail}
      ),
      do: server_frame(bridge, type, f, tail)

  def info(%__MODULE__{call: %{}} = bridge, {:relay_call_link, word, sentence}),
    do: link(bridge, word, sentence)

  # A move back to this computer is starting (`Relay.end_calls/3`): the call
  # is hung up, so the server ends it cleanly and settles it, and once its
  # last frames are through the app hears why. With the link away the
  # server's window ends it there.
  def info(%__MODULE__{call: %{phase: :away}} = bridge, {:call_bridge_end, why}),
    do: say_ended(bridge, why)

  def info(%__MODULE__{call: %{}} = bridge, {:call_bridge_end, why}) do
    bridge = control(bridge, line("call_stop", %{}))
    {:cont, %{bridge | call: %{bridge.call | ended_for: why}}}
  end

  def info(%__MODULE__{call: %{id: id}} = bridge, {:relay_call_busy, id}) do
    say_ended(bridge, "The link to #{bridge.call.server} is too busy to carry this call.")
  end

  def info(%__MODULE__{call: %{window: token}} = bridge, {:call_bridge_window, token}) do
    say_ended(
      bridge,
      "The call ended: Fermix could not reach #{bridge.call.server} again in time."
    )
  end

  def info(%__MODULE__{call: %{relay_monitor: ref}} = bridge, {:DOWN, ref, :process, _, _}) do
    say_ended(bridge, "The call ended: Fermix lost its link to #{bridge.call.server}.")
  end

  def info(%__MODULE__{} = bridge, message) do
    Logger.debug("voice bridge ignored #{inspect(message, limit: 5)}")
    {:cont, bridge}
  end

  @impl true
  def close(%__MODULE__{call: nil}), do: :ok

  # The app went: the server's call ends with it, as a phone's `call_close`
  # ends its call, so no billed session outlives the app.
  def close(%__MODULE__{call: call} = bridge) do
    :ok = Relay.send_call(bridge.relay, call.id, "call_close", %{"reason" => "app_closed"}, <<>>)
    %__MODULE__{call: nil} = forget(bridge)
    :ok
  end

  # -- opening ------------------------------------------------------------------

  defp start_call(%{protocol_version: version} = bridge) when version < @min_app_version do
    refuse(bridge, %{
      type: "error",
      reason: "unsupported_protocol_version",
      kind: "update_required",
      direction: "client_too_old",
      client_version: version,
      min_version: @min_app_version,
      max_version: FermixCore.Realtime.Protocol.protocol_version(),
      sentence: "Update the Fermix app on this computer to call your server from it."
    })
  end

  defp start_call(bridge) do
    call_id = bridge.mint.()

    case Relay.open_call(bridge.relay, call_id) do
      {:ok, %{caps: caps, name: name}} -> open_on_server(bridge, call_id, caps, name)
      {:error, reason} -> refuse(bridge, refusal(reason))
    end
  end

  defp open_on_server(bridge, call_id, caps, name) do
    version = min(bridge.protocol_version, Map.fetch!(caps, "max_version"))
    hello = Jason.encode!(%{"type" => "client_hello", "protocol_version" => version})

    call = %{
      id: call_id,
      server: name,
      phase: :opening,
      seq: 0,
      controls: [],
      hello: hello,
      answered?: false,
      failed?: false,
      ended_for: nil,
      window: nil,
      relay_monitor: monitor(bridge.relay)
    }

    :ok = Relay.send_call(bridge.relay, call_id, "call_open", %{"resume" => false}, <<>>)
    :ok = Relay.send_call(bridge.relay, call_id, "call_line", %{}, hello)
    {:cont, control(%{bridge | call: call}, line("call_start", %{}))}
  end

  defp monitor(relay) do
    case GenServer.whereis(relay) do
      pid when is_pid(pid) -> Process.monitor(pid)
      nil -> nil
    end
  end

  # The relay's refusal, in the words the app shows.
  defp refusal({:unreachable, sentence}),
    do: %{type: "error", reason: "server_unreachable", sentence: sentence}

  defp refusal({:revoked, sentence}),
    do: %{type: "error", reason: "desktop_revoked", sentence: sentence}

  defp refusal(:not_taken),
    do: %{
      type: "error",
      reason: "server_too_old",
      sentence:
        "Your server runs an older Fermix that takes no voice calls from this computer. " <>
          "It updates itself; call again once it has."
    }

  defp refusal(:busy),
    do: %{
      type: "error",
      reason: "busy",
      sentence: "This computer already carries as many calls to your server as it can."
    }

  # -- up -----------------------------------------------------------------------

  # A control is numbered and kept for a resume; while the link is away it
  # waits, and goes once the server says which it applied.
  defp control(%{call: call} = bridge, json) do
    seq = call.seq + 1
    call = %{call | seq: seq, controls: Enum.take([{seq, json} | call.controls], @max_controls)}
    if call.phase != :away, do: send_control(bridge, call.id, seq, json)
    %{bridge | call: call}
  end

  defp send_control(bridge, call_id, seq, json),
    do: :ok = Relay.send_call(bridge.relay, call_id, "call_line", %{"control_seq" => seq}, json)

  defp line_up(%{call: %{phase: :away}} = bridge, _json), do: bridge

  defp line_up(%{call: call} = bridge, json) do
    :ok = Relay.send_call(bridge.relay, call.id, "call_line", %{}, json)
    bridge
  end

  # The microphone in call-channel frames, whole samples, at most 100 ms each.
  defp audio_up(%{call: %{phase: :away}} = bridge, _pcm), do: bridge

  defp audio_up(%{call: call} = bridge, pcm) do
    whole = binary_part(pcm, 0, div(byte_size(pcm), 2) * 2)

    for frame <- frames(whole, []),
        do: :ok = Relay.send_call(bridge.relay, call.id, "call_audio", %{}, frame)

    bridge
  end

  defp frames(<<>>, acc), do: Enum.reverse(acc)

  defp frames(<<frame::binary-size(@frame_bytes), rest::binary>>, acc),
    do: frames(rest, [frame | acc])

  defp frames(frame, acc), do: Enum.reverse([frame | acc])

  defp line(type, payload), do: payload |> Map.put("type", type) |> Jason.encode!()

  # -- down ---------------------------------------------------------------------

  defp server_frame(bridge, "call_attached", fields, _tail), do: attached(bridge, fields)

  defp server_frame(bridge, "call_line", _fields, json), do: server_line(bridge, json)

  defp server_frame(bridge, "call_audio", %{"playback_id" => playback_id}, pcm) do
    delta = %{
      "type" => "audio_delta",
      "audio" => Base.encode64(pcm),
      "playback_id" => playback_id
    }

    written(bridge, Jason.encode!(delta))
  end

  defp server_frame(bridge, "call_close", %{"reason" => reason}, _tail),
    do: closed(bridge, reason)

  # The server carries the call on this session now; after a resume it gets
  # the call's hello again if it never answered it, and every control past
  # the one it applied.
  defp attached(%{call: call} = bridge, %{"resumed" => resumed?, "control_seq" => applied}) do
    bridge = %{bridge | call: %{cancel_window(call) | phase: :attached}}
    if resumed?, do: catch_up(bridge, applied)
    {:cont, bridge}
  end

  defp catch_up(%{call: call} = bridge, applied) do
    unless call.answered?,
      do: :ok = Relay.send_call(bridge.relay, call.id, "call_line", %{}, call.hello)

    for {seq, json} <- Enum.reverse(call.controls),
        seq > applied,
        do: send_control(bridge, call.id, seq, json)

    :ok
  end

  defp server_line(%{call: call} = bridge, json) do
    case Jason.decode(json) do
      {:ok, %{"type" => "server_hello"}} ->
        {:cont, %{bridge | call: %{call | answered?: true}}}

      {:ok, %{"type" => "error", "reason" => "camera_off"}} ->
        written(bridge, json)

      {:ok, %{"type" => "error"}} ->
        written(%{bridge | call: %{call | failed?: true}}, json)

      _other ->
        written(bridge, json)
    end
  end

  defp written(bridge, json) do
    case bridge.write.(json) do
      :ok -> {:cont, bridge}
      {:error, _reason} -> {:stop, bridge}
    end
  end

  # The call is over. A normal end keeps the connection for a fresh call; an
  # end after an error closes it, as the local socket closes after most
  # errors; a call the server no longer holds is said, then closes it.
  defp closed(%{call: call} = bridge, reason) do
    bridge = forget(bridge)

    cond do
      call.ended_for != nil ->
        refuse(bridge, ended_error(call.ended_for))

      reason in ["unknown_call", "lost"] ->
        refuse(bridge, ended_error("The call ended: #{call.server} no longer held it."))

      call.failed? or reason != "ended" ->
        {:stop, bridge}

      true ->
        {:cont, bridge}
    end
  end

  # -- the link -----------------------------------------------------------------

  defp link(%{call: %{phase: :away}} = bridge, :down, _sentence), do: {:cont, bridge}

  defp link(%{call: call} = bridge, :down, _sentence) do
    token = make_ref()
    _timer = bridge.schedule.({:call_bridge_window, token}, bridge.window_ms)
    {:cont, %{bridge | call: %{call | phase: :away, window: token}}}
  end

  defp link(%{call: %{phase: :away} = call} = bridge, :up, _sentence) do
    :ok = Relay.send_call(bridge.relay, call.id, "call_open", %{"resume" => true}, <<>>)
    {:cont, %{bridge | call: %{call | phase: :opening}}}
  end

  defp link(bridge, :up, _sentence), do: {:cont, bridge}
  defp link(bridge, :revoked, sentence), do: say_ended(bridge, sentence)

  defp cancel_window(call), do: %{call | window: nil}

  # -- ending -------------------------------------------------------------------

  # An end the bridge says itself: the server is told the call is over (best
  # effort: a link that is down cannot carry it, and the server's window ends
  # the call there), and the app hears why.
  defp say_ended(%{call: call} = bridge, sentence) do
    :ok =
      Relay.send_call(bridge.relay, call.id, "call_close", %{"reason" => "bridge_ended"}, <<>>)

    refuse(forget(bridge), ended_error(sentence))
  end

  defp ended_error(sentence), do: %{type: "error", reason: "call_ended", sentence: sentence}

  defp forget(%{call: call} = bridge) do
    :ok = Relay.close_call(bridge.relay, call.id)
    if call.relay_monitor, do: Process.demonitor(call.relay_monitor, [:flush])
    %{bridge | call: nil}
  end

  defp refuse(bridge, frame) do
    _ = bridge.emit.(frame)
    {:stop, bridge}
  end

  defp mint_call_id, do: "call-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  defp function!(opts, key, arity) do
    case Keyword.fetch!(opts, key) do
      fun when is_function(fun, arity) ->
        fun

      other ->
        raise ArgumentError,
              "#{inspect(key)} must be a #{arity}-arity function: #{inspect(other)}"
    end
  end
end
