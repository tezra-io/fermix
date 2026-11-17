defmodule FermixCore.PhoneCalls.OpenAILive.Sideband do
  @moduledoc """
  The sideband WebSocket of one GPT-Live SIP call: attached to the session
  `OpenAILive.create_session/2` returned, never starting one.

  `wss://api.openai.com/v1/live/sessions/{session_id}/attach`, with the same
  bearer header as the local voice client and its peer verification
  (`Realtime.OpenAILiveClient.start_options/2`). The telephone audio runs
  between the carrier and OpenAI; this socket carries control and events only.
  It refuses to send `session.start` (the session already started when the
  call was created) and `session.input_audio.append` (the call carries the
  media), and it discards the reflected audio the vendor mirrors here.

  ## Lifetime

  `start_link/1` links the sideband to its caller, the owner, and returns at
  once: the connection opens inside the sideband, so the owner keeps answering
  its own calls meanwhile. The TCP and TLS connect is bounded by
  `Limits.sideband_connect_ms/0` and each read of the upgrade response by
  `Limits.sideband_handshake_read_ms/0`. Those are per step; the owner bounds
  the whole attach with its own timer (`attach_deadline_ms/0` is their sum)
  and stops a sideband that has not reported `:attached` by then with
  `stop/1`.

  The sideband never reconnects. The vendor replays only the last 3 seconds on
  an attach (OpenAI, *Telephony and SIP*), so a second attach is not a resume,
  and whether to make one is not this module's decision.

  ## Messages to the owner

  Every message is `{:phone_sideband, sideband_pid, payload}`, its payload
  passed whole through `OpenAILive.scrubber/1` over the call's API key and
  the further `:secrets` it was started with (its trunk password): no word
  the vendor sends (an error's message, a failure's, a close reason, an
  event of a type this module does not know, raw or not) reaches the owner
  holding either. The sideband keeps that function, never the secrets.

    * `:attached` — the upgrade succeeded. Events follow.
    * `{:attach_failed, reason}` — the attach did not happen. `reason` is
      `{:http_status, status, phrase}` (the vendor refused the upgrade),
      `{:transport, reason}` (connect, DNS, TLS or timeout) or
      `{:handshake, :accept_mismatch}`.
    * `{:event, event}` — one server event, normalized by `Events.normalize/1`,
      delivered once per server `event_id` (`Events.dedupe/2`), in arrival
      order. Reflected audio never arrives.
    * `{:invalid_frame, description}` — a frame that is not a JSON object, with
      a bounded description and never the raw frame.
    * `{:closed, reason}` — the attached socket ended. `reason` is
      `{:remote_close, code, text}`, `:connection_lost` (no close frame),
      `:local_close` (`close/1`) or `{:error, description}`. Whether
      `session.closed` arrived before it is what tells a confirmed finalization
      from an unconfirmed one.

  After `{:attach_failed, _}` or `{:closed, _}` the sideband exits. A close
  with code 1000, from either end, exits `:normal`; every other end (a failed
  attach, another close code, a dropped connection) exits with the WebSockex
  reason, so the owner traps exits (as `Realtime.LiveSessionServer` does) and
  acts on the message, which always arrives before the exit signal.
  """

  use WebSockex

  alias FermixCore.Net.Egress
  alias FermixCore.PhoneCalls.Limits
  alias FermixCore.PhoneCalls.OpenAILive
  alias FermixCore.PhoneCalls.OpenAILive.Controls
  alias FermixCore.PhoneCalls.OpenAILive.Events
  alias FermixCore.Realtime.OpenAILiveClient

  @ws_base_url "wss://api.openai.com"
  @describe_limit 200

  # Never on this socket: the session started at creation, and the call is the
  # media path.
  @forbidden_types ["session.start", "session.input_audio.append"]

  @type reason :: term()
  @type send_result ::
          {:ok, String.t()} | {:error, {:not_sent, reason()} | {:unknown, reason()}}

  @doc "Where the production sideband attaches."
  @spec ws_base_url() :: String.t()
  def ws_base_url, do: @ws_base_url

  @doc "The owner's bound on a whole attach: connect plus one upgrade read."
  @spec attach_deadline_ms() :: pos_integer()
  def attach_deadline_ms, do: Limits.sideband_connect_ms() + Limits.sideband_handshake_read_ms()

  @doc """
  The attach URL for `session_id` under `base_url` (`ws_base_url/0` in
  production). The id is kept unchanged and only percent-encoded for the path.
  """
  @spec attach_url(String.t(), String.t()) :: String.t()
  def attach_url(base_url, session_id)
      when is_binary(base_url) and is_binary(session_id) and session_id != "" do
    encoded = URI.encode(session_id, &URI.char_unreserved?/1)
    String.trim_trailing(base_url, "/") <> "/v1/live/sessions/#{encoded}/attach"
  end

  @doc """
  Attaches to `opts[:session_id]` with `opts[:api_key]`, linked to the caller,
  which receives the messages above.

  `:ws_base_url` (default `ws_base_url/0`; which origin a build's calls use is
  the composition root's decision, handed down through
  `PhoneCalls.CallTransport`) and `:egress` (default `Egress.active/0`). A
  destination the configured proxy would carry is refused
  (`{:error, :proxy_unsupported_transport}`): a WebSocket cannot tunnel, and
  nothing dials around the proxy. A key no request could carry
  (`OpenAILive.sendable_api_key?/1`) is refused before dialing
  (`{:error, {:invalid, :api_key}}`). `:secrets` (default none) are the
  call's other credentials, scrubbed from every message beside the key.
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) when is_list(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    api_key = Keyword.fetch!(opts, :api_key)
    secrets = opts |> Keyword.get(:secrets, []) |> secrets!()
    egress = Keyword.get_lazy(opts, :egress, &Egress.active/0)

    url = attach_url(Keyword.get(opts, :ws_base_url, @ws_base_url), session_id)

    with :ok <- sendable_key(api_key),
         :ok <- Egress.ensure_direct(url, egress),
         {:ok, start_opts} <-
           OpenAILiveClient.start_options(url, OpenAILiveClient.headers(api_key)) do
      state = %{
        owner: self(),
        seen: Events.new_seen(),
        attached?: false,
        scrub: OpenAILive.scrubber([api_key | secrets])
      }

      WebSockex.start_link(url, __MODULE__, state, start_opts ++ connect_options())
    end
  end

  # Never named in the error: each one is a credential.
  defp secrets!(secrets) when is_list(secrets) do
    if Enum.all?(secrets, &is_binary/1),
      do: secrets,
      else: raise(ArgumentError, "a sideband's :secrets must be strings")
  end

  # The upgrade request is written header by header, unchecked: a key with a
  # line break would add a header of its own.
  defp sendable_key(api_key) do
    if OpenAILive.sendable_api_key?(api_key), do: :ok, else: {:error, {:invalid, :api_key}}
  end

  @doc """
  Sends one client event, once. `{:ok, event_id}` means the frame was written
  to the socket; the vendor's acknowledgement (or `error`) arrives as an event.
  `{:error, {:not_sent, _}}` means it provably was not written;
  `{:error, {:unknown, _}}` that it may have been, and must not be sent again.
  """
  @spec send_event(pid(), map()) :: send_result()
  def send_event(sideband, %{type: type}) when is_pid(sideband) and type in @forbidden_types,
    do: {:error, {:not_sent, {:forbidden_on_sideband, type}}}

  def send_event(sideband, %{type: type, event_id: event_id} = event)
      when is_pid(sideband) and is_binary(type) and is_binary(event_id) do
    case Jason.encode(event) do
      {:ok, payload} -> write(sideband, payload, event_id)
      {:error, error} -> {:error, {:not_sent, {:encode_failed, Exception.message(error)}}}
    end
  end

  @doc """
  Presses one keypad key, once, with a fresh correlating `event_id`.
  `{:ok, event_id}` when written; wait for `Controls.dtmf_outcome/2` to read
  `:acknowledged` before the next key, and never resend on a missing one.
  """
  @spec send_dtmf(pid(), String.t()) :: send_result() | {:error, :invalid_dtmf_key}
  def send_dtmf(sideband, key) when is_pid(sideband) and is_binary(key) do
    with {:ok, event} <- Controls.dtmf_event(Controls.new_event_id(), key) do
      send_event(sideband, event)
    end
  end

  @doc "A delegation's result to speak (`delegation_id` as the vendor sent it)."
  @spec send_commentary(pid(), String.t() | nil, String.t()) :: send_result()
  def send_commentary(sideband, delegation_id, content) when is_pid(sideband) do
    send_event(
      sideband,
      Controls.commentary_event(Controls.new_event_id(), delegation_id, content)
    )
  end

  @doc """
  Closes the socket with a normal close frame. The owner receives
  `{:closed, :local_close}` and the sideband exits `:normal`. Closing the
  socket is not ending the call: that is `session.close` or the hangup control.
  """
  @spec close(pid()) :: :ok
  def close(sideband) when is_pid(sideband), do: WebSockex.cast(sideband, :close)

  @doc """
  Stops a sideband at once, for an attach that outlived its deadline. It is
  unlinked first, so the owner gets no exit signal for it; a message it sent
  just before the stop can still be in the owner's mailbox, and the owner
  ignores anything from a sideband it has stopped.
  """
  @spec stop(pid()) :: :ok
  def stop(sideband) when is_pid(sideband) do
    Process.unlink(sideband)
    Process.exit(sideband, :kill)
    :ok
  end

  @impl true
  def handle_connect(_conn, state) do
    notify(state, :attached)
    {:ok, %{state | attached?: true}}
  end

  @impl true
  def handle_frame({:text, payload}, state) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, %{} = event} ->
        {:ok, deliver(event, state)}

      {:ok, other} ->
        notify(state, {:invalid_frame, {:not_an_object, describe(other)}})
        {:ok, state}

      {:error, error} ->
        notify(state, {:invalid_frame, {:decode_failed, Exception.message(error)}})
        {:ok, state}
    end
  end

  def handle_frame({:binary, payload}, state) do
    notify(state, {:invalid_frame, {:binary, byte_size(payload)}})
    {:ok, state}
  end

  @impl true
  def handle_cast(:close, state), do: {:close, state}

  @impl true
  def handle_disconnect(%{reason: reason}, %{attached?: false} = state) do
    notify(state, {:attach_failed, attach_failure(reason)})
    {:ok, state}
  end

  def handle_disconnect(%{reason: reason}, state) do
    notify(state, {:closed, close_reason(reason)})
    {:ok, state}
  end

  defp connect_options do
    [
      async: true,
      handle_initial_conn_failure: true,
      socket_connect_timeout: Limits.sideband_connect_ms(),
      socket_recv_timeout: Limits.sideband_handshake_read_ms()
    ]
  end

  # `WebSockex.send_frame/3` exits `{reason, {WebSockex, :call, [pid, frame]}}`
  # when its call fails. A sideband that is already gone was never written to;
  # one that timed out, or died under the call, may have written the frame. The
  # frame (call content) is never part of what is returned.
  defp write(sideband, payload, event_id) do
    case WebSockex.send_frame(sideband, {:text, payload}, Limits.sideband_send_ms()) do
      :ok -> {:ok, event_id}
      {:error, %WebSockex.NotConnectedError{} = error} -> {:error, {:not_sent, error}}
      {:error, %WebSockex.FrameEncodeError{} = error} -> {:error, {:not_sent, error}}
      {:error, error} -> {:error, {:unknown, error}}
    end
  catch
    :exit, {:noproc, _call} -> {:error, {:not_sent, :sideband_down}}
    :exit, {:timeout, _call} -> {:error, {:unknown, :send_timeout}}
    :exit, {reason, _call} -> {:error, {:unknown, {:sideband_exited, describe(reason)}}}
  end

  defp deliver(event, state) do
    case Events.dedupe(state.seen, event) do
      :duplicate -> state
      {:new, seen} -> forward(Events.normalize(event), %{state | seen: seen})
    end
  end

  defp forward({:reflected_audio, _direction}, state), do: state

  defp forward(event, state) do
    notify(state, {:event, event})
    state
  end

  defp attach_failure(%WebSockex.RequestError{code: code, message: phrase}),
    do: {:http_status, code, phrase}

  defp attach_failure(%WebSockex.ConnError{original: original}), do: {:transport, original}
  defp attach_failure(%WebSockex.HandshakeError{}), do: {:handshake, :accept_mismatch}
  defp attach_failure(other), do: {:transport, describe(other)}

  defp close_reason({:remote, :normal}), do: {:remote_close, 1000, ""}
  defp close_reason({:remote, code, text}), do: {:remote_close, code, text}
  defp close_reason({:remote, :closed}), do: :connection_lost
  defp close_reason({:local, :normal}), do: :local_close
  defp close_reason({:local, _code, _text}), do: :local_close
  defp close_reason({:error, error}), do: {:error, describe(error)}
  defp close_reason(other), do: {:error, describe(other)}

  defp describe(term), do: inspect(term, limit: 5, printable_limit: @describe_limit)

  defp notify(%{owner: owner, scrub: scrub}, payload),
    do: send(owner, {:phone_sideband, self(), scrub.(payload)})
end
