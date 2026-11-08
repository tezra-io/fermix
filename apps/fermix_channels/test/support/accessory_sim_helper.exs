defmodule FermixTestSupport.AccessorySim do
  @moduledoc """
  The accessory end of the link, for tests: a robot built from the same
  `FermixCore.Accessories` modules the daemon uses, reading the host's frames
  with `Parser.new(:host)` and answering as `priv/accessory/PROTOCOL.md` says
  the firmware does.

    * **Attach**: answers `hello` with a signed `hello_ack` (or an unenrolled
      one), refuses a host other than the one it enrolled with
      (`unknown_host`) before signing, and checks `host_proof` before it says
      `attached`.
    * **Enrollment**: offers its key on `enroll.begin` (the owner's tap on its
      screen, automatic unless `auto_tap?: false`), checks `enroll.reveal`
      against the commitment, shows the compare code (told to the observer),
      signs `enroll.confirmed` when the owner taps Matches (`confirm_match/1`),
      verifies `enroll.commit` and answers `enroll.done`.
    * **Speaker**: grants credit, plays from a ring, and holds the host to
      every speaker rule (credit, segments, at most 8 open): a host that
      breaks one is answered `error {code}` as the firmware would, and the
      observer is told `{:violation, code}`, so a test can assert none.
    * **Microphone**: sends 960-byte frames on the call's stream.

  Every control message it reads reaches the observer as
  `{:sim, sim, {:received, message}}`, and every speaker frame as
  `{:sim, sim, {:pcm, bytes}}`.
  """

  use GenServer

  alias FermixCore.Accessories.Capabilities
  alias FermixCore.Accessories.Control
  alias FermixCore.Accessories.Frame
  alias FermixCore.Accessories.P256
  alias FermixCore.Accessories.Parser
  alias FermixCore.Accessories.Reassembler
  alias FermixCore.Accessories.Transcript
  alias FermixTestSupport.AccessoryMemoryTransport

  @mic_bytes 960
  @max_credit 8_192
  @max_segments 8
  @default_state %{
    battery: 80,
    power: "usb",
    brownout: false,
    volume: 60,
    brightness: 70,
    motion: "off",
    calibration: "valid"
  }

  # -- the test's controls --------------------------------------------------------

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def child_spec(opts),
    do: %{id: Keyword.get(opts, :id, __MODULE__), start: {__MODULE__, :start_link, [opts]}}

  @doc "The accessory's ID (the SHA-256 of its public key)."
  def accessory_id(sim), do: GenServer.call(sim, :accessory_id)

  @doc "A snapshot of what the accessory holds, for assertions."
  def peek(sim), do: GenServer.call(sim, :peek)

  @doc "A screen tap or head swipe asks for a call."
  def request_call(sim, source \\ "screen_tap"), do: GenServer.call(sim, {:request_call, source})

  @doc "The owner swipes back: the accessory asks the host to end the call."
  def end_request(sim), do: GenServer.call(sim, :end_request)

  @doc "Sends `count` microphone frames on the call's stream; `skip: n` leaves a seq gap first."
  def send_mic(sim, count, opts \\ []), do: GenServer.call(sim, {:send_mic, count, opts})

  @doc "Reports the microphone's state, as the accessory's own mute does."
  def mic_state(sim, state, reason \\ nil), do: GenServer.call(sim, {:mic_state, state, reason})

  @doc "Grants speaker credit; a grant past 8,192 outstanding is the host's to refuse."
  def grant(sim, bytes), do: GenServer.call(sim, {:grant, bytes})

  @doc "Plays `bytes` of queued speaker audio, draining segments as they finish."
  def play(sim, bytes), do: GenServer.call(sim, {:play, bytes})

  @doc "The owner taps Pair on the accessory's prompt (with `auto_tap?: false`)."
  def tap_pair(sim), do: GenServer.call(sim, :tap_pair)

  @doc "The owner taps Matches on the accessory's screen."
  def confirm_match(sim), do: GenServer.call(sim, :confirm_match)

  @doc "Sends any accessory message as the firmware would."
  def send_message(sim, message), do: GenServer.call(sim, {:send_message, message})

  @doc """
  Sends one control payload as written, in frames with the accessory's own
  sequence numbers: a message outside the contract (an unknown type, a field
  out of range, a payload that is not JSON) reaches the host intact.
  """
  def send_payload(sim, stream, payload),
    do: GenServer.call(sim, {:send_payload, stream, payload})

  @doc "Sends raw bytes onto the wire (line noise, a broken frame)."
  def send_raw(sim, bytes), do: GenServer.call(sim, {:send_raw, bytes})

  @doc "Changes a behaviour flag, such as `silent?` or `auto_credit`."
  def set(sim, key, value), do: GenServer.call(sim, {:set, key, value})

  # -- the accessory -----------------------------------------------------------------

  @impl true
  def init(opts) do
    {public, private} = Keyword.get_lazy(opts, :key, &P256.generate/0)

    {:ok,
     %{
       observer: Keyword.fetch!(opts, :observer),
       public: public,
       private: private,
       enrolled_host: Keyword.get(opts, :enrolled_host),
       kind: Keyword.get(opts, :kind, "stackchan"),
       caps: Keyword.get(opts, :caps, Capabilities.mask([:mic, :speaker, :screen, :touch])),
       firmware: Keyword.get(opts, :firmware, "0.1.0"),
       wire: Keyword.get(opts, :wire, 1),
       silent?: Keyword.get(opts, :silent?, false),
       bad_sig?: Keyword.get(opts, :bad_sig?, false),
       auto_tap?: Keyword.get(opts, :auto_tap?, true),
       auto_credit: Keyword.get(opts, :auto_credit, @max_credit),
       owner: nil,
       ref: nil,
       parser: Parser.new(:host),
       reassembler: Reassembler.new(),
       seq: %{control: 0, mic: 0, diagnostics: 0},
       gen: nil,
       hello: nil,
       enroll: nil,
       request: 0,
       call: nil
     }}
  end

  @impl true
  def handle_call(:accessory_id, _from, state), do: {:reply, P256.id(state.public), state}

  def handle_call(:peek, _from, state), do: {:reply, Map.drop(state, [:private, :parser]), state}

  def handle_call({:request_call, source}, _from, state) do
    request = state.request + 1

    state =
      send_msg(%{state | request: request}, %{
        type: "call.request",
        request: request,
        source: source
      })

    {:reply, request, state}
  end

  def handle_call(:end_request, _from, state),
    do: {:reply, :ok, send_msg(state, %{type: "call.end_request", stream: state.call.stream})}

  def handle_call({:send_mic, count, opts}, _from, state) do
    state = update_in(state, [:seq, :mic], &(&1 + Keyword.get(opts, :skip, 0)))
    {:reply, :ok, Enum.reduce(1..count//1, state, fn i, acc -> mic_frame(acc, i) end)}
  end

  def handle_call({:mic_state, mic, reason}, _from, state) do
    message = compact(%{type: "mic.state", stream: state.call.stream, state: mic, reason: reason})
    {:reply, :ok, send_msg(state, message)}
  end

  def handle_call({:grant, bytes}, _from, state), do: {:reply, :ok, grant_credit(state, bytes)}
  def handle_call({:play, bytes}, _from, state), do: {:reply, :ok, play_ring(state, bytes)}
  def handle_call(:tap_pair, _from, state), do: {:reply, :ok, offer(state)}
  def handle_call(:confirm_match, _from, state), do: {:reply, :ok, confirm(state)}

  def handle_call({:send_message, message}, _from, state),
    do: {:reply, :ok, send_msg(state, message)}

  def handle_call({:send_payload, stream, payload}, _from, state),
    do: {:reply, :ok, send_frames(state, stream, payload)}

  def handle_call({:send_raw, bytes}, _from, state) do
    AccessoryMemoryTransport.deliver(state.owner, state.ref, bytes)
    {:reply, :ok, state}
  end

  def handle_call({:set, key, value}, _from, state), do: {:reply, :ok, Map.put(state, key, value)}

  @impl true
  def handle_info({:accessory_port, :opened, ref, owner}, state) do
    # USB appeared for this host: the accessory's counters start again.
    {:noreply,
     %{
       state
       | owner: owner,
         ref: ref,
         parser: Parser.new(:host),
         reassembler: Reassembler.new(),
         seq: %{control: 0, mic: 0, diagnostics: 0},
         call: nil
     }}
  end

  def handle_info({:accessory_port, :closed, ref}, %{ref: ref} = state),
    do: {:noreply, %{state | owner: nil, ref: nil, call: nil}}

  def handle_info({:accessory_port, :bytes, ref, bytes}, %{ref: ref} = state) do
    {events, parser} = Parser.feed(state.parser, bytes, 0)
    {:noreply, Enum.reduce(events, %{state | parser: parser}, &event/2)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # -- reading the host --------------------------------------------------------------

  defp event({:fault, reason}, state) do
    notify(state, {:fault, reason})
    %{state | reassembler: Reassembler.new()}
  end

  defp event({:frame, %Frame{type: :control} = frame}, state) do
    case Reassembler.feed(state.reassembler, frame) do
      {:more, reassembler} ->
        %{state | reassembler: reassembler}

      {:message, stream, payload, reassembler} ->
        decoded(%{state | reassembler: reassembler}, stream, payload)

      {:fault, reason, reassembler} ->
        event({:fault, reason}, %{state | reassembler: reassembler})
    end
  end

  defp event({:frame, %Frame{type: :speaker} = frame}, state), do: speaker_pcm(state, frame)

  defp decoded(state, stream, payload) do
    case Control.decode(:host, stream, payload) do
      {:ok, message} ->
        notify(state, {:received, message})
        handle(message, state)

      {:error, reason} ->
        notify(state, {:undecodable, reason})
        state
    end
  end

  defp handle(%{type: "hello"} = hello, state) do
    state = %{state | gen: hello.gen, reassembler: Reassembler.new(), call: nil, enroll: nil}
    if state.silent?, do: state, else: answer_hello(state, hello)
  end

  defp handle(_message, %{silent?: true} = state), do: state
  defp handle(%{gen: gen}, %{gen: current} = state) when gen != current, do: state
  defp handle(%{type: "host_proof"} = proof, state), do: host_proof(state, proof)
  defp handle(%{type: "ping"}, state), do: send_msg(state, %{type: "pong", uptime_ms: 1_000})
  defp handle(%{type: "enroll.begin"} = begin, state), do: enroll_begin(state, begin)
  defp handle(%{type: "enroll.reveal"} = reveal, state), do: enroll_reveal(state, reveal)
  defp handle(%{type: "enroll.commit"} = commit, state), do: enroll_commit(state, commit)
  defp handle(%{type: "enroll.cancel"}, state), do: %{state | enroll: nil}
  defp handle(%{type: "accessory.forget"}, state), do: %{state | enrolled_host: nil}
  defp handle(%{type: "call.start"} = start, state), do: call_start(state, start)
  defp handle(%{type: "call.end"}, state), do: %{state | call: nil}
  defp handle(%{type: "spk.begin"} = begin, state), do: spk_begin(state, begin)
  defp handle(%{type: "spk.end"} = segment_end, state), do: spk_end(state, segment_end)
  defp handle(%{type: "spk.flush"}, state), do: spk_flush(state)

  defp handle(%{type: "call.state", state: "listening"}, %{call: %{}} = state),
    do: send_msg(state, %{type: "mic.state", stream: state.call.stream, state: "live"})

  defp handle(_message, state), do: state

  # -- attach --------------------------------------------------------------------------

  defp answer_hello(%{enrolled_host: host_pk} = state, hello) when is_binary(host_pk) do
    if P256.id(host_pk) == hello.host_id,
      do: signed_ack(state, hello),
      else: send_msg(state, %{type: "refuse", code: "unknown_host"})
  end

  defp answer_hello(state, hello) do
    nonce = :crypto.strong_rand_bytes(32)
    state = %{state | hello: Map.put(hello, :accessory_nonce, nonce)}
    send_msg(state, ack(state, nonce, nil, nil))
  end

  defp signed_ack(state, hello) do
    nonce = :crypto.strong_rand_bytes(32)
    id = P256.id(state.public)

    transcript =
      Transcript.attach(%{
        host_id: hello.host_id,
        accessory_id: id,
        host_nonce: hello.host_nonce,
        accessory_nonce: nonce,
        wire: state.wire,
        host_caps: hello.caps,
        accessory_caps: state.caps,
        gen: hello.gen,
        kind: state.kind
      })

    signed = if state.bad_sig?, do: transcript <> "x", else: transcript
    state = %{state | hello: Map.merge(hello, %{accessory_nonce: nonce, transcript: transcript})}
    send_msg(state, ack(state, nonce, id, P256.sign(signed, state.private)))
  end

  defp ack(state, nonce, id, sig) do
    %{
      type: "hello_ack",
      wire: state.wire,
      kind: state.kind,
      accessory_id: id,
      firmware: state.firmware,
      pack: nil,
      caps: state.caps,
      accessory_nonce: nonce,
      sig: sig
    }
  end

  defp host_proof(%{hello: %{transcript: transcript}} = state, %{sig: sig}) do
    if P256.verify(transcript, sig, state.enrolled_host),
      do: send_msg(state, %{type: "attached", state: @default_state}),
      else: send_msg(state, %{type: "refuse", code: "bad_proof"})
  end

  defp host_proof(state, _proof), do: state

  # -- enrollment --------------------------------------------------------------------

  defp enroll_begin(state, begin) do
    state = %{state | enroll: Map.take(begin, [:attempt, :round, :host_pk, :host_commit])}
    if state.auto_tap?, do: offer(state), else: state
  end

  defp offer(%{enroll: enroll} = state) do
    nonce = :crypto.strong_rand_bytes(32)
    state = put_in(state, [:enroll, :accessory_nonce], nonce)

    send_msg(state, %{
      type: "enroll.offer",
      attempt: enroll.attempt,
      round: enroll.round,
      accessory_pk: state.public,
      accessory_nonce: nonce
    })
  end

  defp enroll_reveal(%{enroll: enroll} = state, reveal) do
    if :crypto.hash(:sha256, reveal.host_nonce) == enroll.host_commit,
      do: show_code(state, reveal.host_nonce),
      else:
        send_msg(state, %{
          type: "enroll.cancel",
          attempt: enroll.attempt,
          reason: "invalid_reveal"
        })
  end

  defp show_code(%{enroll: enroll} = state, host_nonce) do
    transcript =
      Transcript.enroll(%{
        host_pk: enroll.host_pk,
        accessory_pk: state.public,
        host_nonce: host_nonce,
        accessory_nonce: enroll.accessory_nonce
      })

    notify(state, {:code, Transcript.compare_code(transcript)})
    put_in(state, [:enroll, :transcript], transcript)
  end

  defp confirm(%{enroll: enroll} = state) do
    send_msg(state, %{
      type: "enroll.confirmed",
      attempt: enroll.attempt,
      round: enroll.round,
      sig: P256.sign(enroll.transcript, state.private)
    })
  end

  defp enroll_commit(%{enroll: enroll} = state, commit) do
    if P256.verify(enroll.transcript, commit.host_sig, enroll.host_pk) do
      state = %{state | enrolled_host: enroll.host_pk, enroll: nil}

      send_msg(state, %{
        type: "enroll.done",
        attempt: enroll.attempt,
        accessory_id: P256.id(state.public)
      })
    else
      send_msg(state, %{type: "enroll.cancel", attempt: enroll.attempt, reason: "invalid_offer"})
    end
  end

  # -- calls and the speaker ------------------------------------------------------------

  defp call_start(state, start) do
    call = %{
      stream: start.stream,
      call: start.call,
      credit: 0,
      taking: nil,
      next_segment: 1,
      open: %{},
      ring: :queue.new(),
      ring_bytes: 0
    }

    state = %{state | call: call}
    if state.auto_credit > 0, do: grant_credit(state, state.auto_credit), else: state
  end

  defp grant_credit(%{call: call} = state, bytes) do
    state = put_in(state, [:call, :credit], call.credit + bytes)
    send_msg(state, %{type: "credit", stream: call.stream, bytes: bytes})
  end

  defp spk_begin(%{call: call} = state, begin) do
    cond do
      call.taking != nil -> violation(state, "segment_sequence")
      begin.segment != call.next_segment -> violation(state, "segment_sequence")
      map_size(call.open) >= @max_segments -> violation(state, "segment_limit")
      true -> begin_segment(state, begin)
    end
  end

  defp begin_segment(%{call: call} = state, begin) do
    segment = %{playback_id: begin.playback_id, ended?: false, queued: 0, played: 0}

    put_in(state, [:call], %{
      call
      | taking: begin.segment,
        next_segment: begin.segment + 1,
        open: Map.put(call.open, begin.segment, segment)
    })
  end

  defp spk_end(%{call: %{taking: segment} = call} = state, %{segment: segment}) do
    open = Map.update!(call.open, segment, &%{&1 | ended?: true})
    state = put_in(state, [:call], %{call | taking: nil, open: open})
    drain_finished(state)
  end

  defp spk_end(state, _segment_end), do: violation(state, "segment_sequence")

  defp speaker_pcm(%{call: nil} = state, _frame), do: violation(state, "segment_sequence")

  defp speaker_pcm(%{call: call} = state, %Frame{payload: pcm}) do
    notify(state, {:pcm, pcm})

    cond do
      call.taking == nil -> violation(state, "segment_sequence")
      byte_size(pcm) > call.credit -> violation(state, "credit_exceeded")
      true -> queue_pcm(state, call, pcm)
    end
  end

  defp queue_pcm(state, call, pcm) do
    open = Map.update!(call.open, call.taking, &%{&1 | queued: &1.queued + byte_size(pcm)})

    put_in(state, [:call], %{
      call
      | credit: call.credit - byte_size(pcm),
        open: open,
        ring: :queue.in({call.taking, byte_size(pcm)}, call.ring),
        ring_bytes: call.ring_bytes + byte_size(pcm)
    })
  end

  defp play_ring(state, 0), do: drain_finished(state) |> refill()

  defp play_ring(%{call: call} = state, bytes) do
    case :queue.out(call.ring) do
      {:empty, _ring} ->
        play_ring(state, 0)

      {{:value, {segment, size}}, ring} ->
        played = min(size, bytes)
        ring = if played == size, do: ring, else: :queue.in_r({segment, size - played}, ring)

        open =
          Map.update!(
            call.open,
            segment,
            &%{&1 | queued: &1.queued - played, played: &1.played + played}
          )

        call = %{call | ring: ring, ring_bytes: call.ring_bytes - played, open: open}
        play_ring(%{state | call: call}, bytes - played)
    end
  end

  # A segment whose end arrived and whose last sample played has drained.
  defp drain_finished(%{call: call} = state) do
    {drained, open} = Enum.split_with(call.open, fn {_n, s} -> s.ended? and s.queued == 0 end)
    state = put_in(state, [:call, :open], Map.new(open))

    drained
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
    |> Enum.reduce(state, &send_msg(&2, %{type: "spk.drained", stream: call.stream, segment: &1}))
  end

  defp refill(%{auto_credit: 0} = state), do: state

  defp refill(%{call: call} = state) do
    room = min(@max_credit - call.credit, 19_200 - call.ring_bytes - call.credit)
    if room > 0, do: grant_credit(state, room), else: state
  end

  defp spk_flush(%{call: call} = state) do
    playing = call.ring |> :queue.peek() |> playing_segment()
    played_ms = played_ms(call.open, playing)
    call = %{call | ring: :queue.new(), ring_bytes: 0, open: %{}, taking: nil}

    flushed =
      compact(%{type: "spk.flushed", stream: call.stream, segment: playing, played_ms: played_ms})

    send_msg(%{state | call: call}, flushed)
  end

  defp played_ms(_open, nil), do: 0
  defp played_ms(open, segment), do: div(open[segment].played, 48)

  defp playing_segment({:value, {segment, _size}}), do: segment
  defp playing_segment(:empty), do: nil

  defp violation(state, code) do
    notify(state, {:violation, code})
    send_msg(state, %{type: "error", code: code})
  end

  # -- writing --------------------------------------------------------------------------

  defp mic_frame(%{call: call} = state, i) do
    payload = :binary.copy(<<rem(i, 251)>>, @mic_bytes)
    frame = %Frame{type: :mic, stream: call.stream, seq: state.seq.mic, payload: payload}
    deliver(state, Frame.encode(frame))
    update_in(state, [:seq, :mic], &rem(&1 + 1, 4_294_967_296))
  end

  defp send_msg(state, message) do
    message = Map.put(message, :gen, state.gen)
    {:ok, json} = Control.encode(:accessory, message)
    send_frames(state, Control.stream(message), json)
  end

  defp send_frames(state, stream, payload) do
    payload
    |> Frame.control_fragments(urgent: false)
    |> Enum.reduce(state, fn {flags, chunk}, acc ->
      seq = acc.seq.control
      frame = %Frame{type: :control, flags: flags, stream: stream, seq: seq, payload: chunk}
      deliver(acc, Frame.encode(frame))
      put_in(acc, [:seq, :control], rem(seq + 1, 4_294_967_296))
    end)
  end

  defp deliver(%{owner: owner, ref: ref}, bytes) when is_pid(owner),
    do: AccessoryMemoryTransport.deliver(owner, ref, bytes)

  defp deliver(_state, _bytes), do: :ok

  defp notify(state, event), do: send(state.observer, {:sim, self(), event})

  defp compact(map), do: map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
end
