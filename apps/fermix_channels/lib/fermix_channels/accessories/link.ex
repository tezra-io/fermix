defmodule FermixChannels.Accessories.Link do
  @moduledoc """
  One attached accessory's link (M91 §05; `priv/accessory/PROTOCOL.md`): the
  process that owns its port, reads every frame, attaches it with both
  proofs, keeps it alive, pairs it over the port the owner selected, and
  hands each call to a per-call process (`FermixChannels.Accessories.Call`).
  One per opened port, started by the port watcher.

    * **Receiving.** Bytes go through `Parser` (fed an empty chunk on every
      tick, at most every 250 ms, so a stalled frame is found with nothing
      arriving) and control frames through `Reassembler`. Every receive or
      reassembly fault ends the link: the call ends, an open pairing is
      cancelled `link_reset`, the fault is counted and reported, and a new
      HELLO restores an idle link. A message the contract refuses is answered
      `error {code, message_type}` and counted; nothing acts on it.
    * **Attach.** Each HELLO opens a new generation and a single-use challenge
      (`Attach`), at most one a second (`Attach.may_hello?/2`), and resets the
      parser, the reassembler and the microphone's sequence base. A
      `hello_ack` is checked in the contract's order; a verified one gets the
      host's proof, and `attached` completes the link. Without both
      signatures verified within ten seconds of its HELLO, a port an enrolled
      accessory's hint named is greeted again, and the port the owner
      selected for pairing ends the step (`{:shutdown, :no_answer}`) until
      its accessory enrolls: from `enroll.done` on, the link is in attach
      mode, and its attach is greeted again like any other. A
      refusal either way (a host refusal, or the accessory's own) holds the
      port idle and is not retried until the owner acts.
    * **Liveness.** The host pings every 5 s outside a call and every second
      in one; fifteen seconds without a frame from the peer outside a call,
      three in one, is link loss, handled like a fault.
    * **Capabilities.** No message is sent whose capability
      (`Control.capability/1`) the accessory did not report.
    * **Pairing.** Only on the port the owner selected (`mode: :pairing`):
      `enroll_begin/1` and the owner's confirmation, mismatch and cancel
      (`Link.Pairing`); the record is written through the serialized store
      writer on `enroll.done`, and the accessory attaches with a new HELLO.
    * **Calls.** A `call.request` from the accessory, or `start_call/1` from
      the Mac, starts the call's own process under this one (linked; this
      process traps exits), so a call can block on its session's start while
      the link keeps reading. The call writes through the link, which drops
      anything of a stream that is not the current call's. A tap on an
      accessory that is not the voice device is refused `not_selected`, and
      one on an accessory short of power `power_too_low` (M91 §07); a start
      from the Mac is the owner's own act and needs no selection. The Mac's
      start is answered at once with the call's stream; its admission (the
      call's id, `phase: :active`) or its refusal (`last_call`) shows in the
      link's view. The Mac's controls name the call they are for, and one for
      a call that is not the current one is refused.
      The call's own view (`Call.View`) is published with the link's, so the
      Mac observes the call through `accessories.status`.
    * **Setup checks and settings** (M91 E3): a check, a calibration step or
      a setting only on an attached accessory with no call, and only one it
      reported the capability of; the check's progress and result, and the
      accessory's own fault, are published with the link.

  Time is the injected clock's monotonic milliseconds (`:clock`) and every
  timer goes through `:send_after`, so a test moves time by hand. Every state
  change is published through `:notify` (the watcher's view, which a status
  read and E3's long poll use).
  """

  use GenServer, restart: :temporary

  alias FermixChannels.Accessories.Link.Pairing
  alias FermixChannels.Accessories.Link.Wire
  alias FermixChannels.Accessories.StoreWriter
  alias FermixCore.Accessories.Attach
  alias FermixCore.Accessories.Capabilities
  alias FermixCore.Accessories.Control
  alias FermixCore.Accessories.Enrollment
  alias FermixCore.Accessories.Frame
  alias FermixCore.Accessories.Parser
  alias FermixCore.Accessories.Reassembler
  alias FermixCore.Accessories.Record
  alias FermixCore.Accessories.Store
  alias FermixCore.Accessories.Telemetry
  alias FermixCore.Accessories.VoiceDevice

  require Logger

  @tick_ms 250
  @ping_idle_ms 5_000
  @ping_call_ms 1_000
  @lost_idle_ms 15_000
  @lost_call_ms 3_000
  @max_gen 4_294_967_295
  @max_stream 65_535
  @call_timeout_ms 5_000
  # Inside a worker's default 5 s shutdown.
  @settle_call_ms 4_000
  @call_ending_errors ~w(credit_overgrant credit_exceeded segment_limit segment_sequence)
  @refusals %{
    "wire_version" => :wire_version,
    "unknown_accessory" => :unknown_accessory,
    "unknown_host" => :unknown_host,
    "bad_proof" => :bad_proof,
    "capability_missing" => :capability_missing,
    "unsupported_kind" => :unsupported_kind,
    "auth_timeout" => :auth_timeout,
    "stale_generation" => :stale_generation
  }
  @sources %{"screen_tap" => :screen_tap, "head_swipe" => :head_swipe}
  @always ~w(refuse error pong diag.counters diag.fault)
  @low_power ~w(low critical)
  @checks %{"tone" => :tone, "mic" => :mic, "face" => :face, "motion" => :motion}
  @by_phase %{
    hello: [],
    proving: ~w(attached),
    attached: ~w(accessory.state call.request call.end_request mic.state credit playback.progress
                 spk.drained spk.flushed check.level check.result diag.chunk),
    unenrolled: ~w(enroll.offer enroll.confirmed enroll.done enroll.cancel),
    refused: []
  }
  @call_scoped ~w(call.end_request mic.state credit playback.progress spk.drained spk.flushed)

  @type mode :: :attach | :pairing
  @type phase :: :hello | :proving | :attached | :unenrolled | :refused

  defstruct [
    :path,
    :serial,
    :mode,
    :transport,
    :transport_opts,
    :handle,
    :home,
    :store_writer,
    :clock,
    :send_after,
    :tick_ms,
    :readiness,
    :voice_device,
    :utc_now,
    :notify,
    :ended,
    :call_module,
    :call_opts,
    :challenge,
    :verified,
    :peer,
    :accessory_state,
    :refusal,
    :refused_range,
    :readiness_sent,
    :enrollment,
    :pairing_name,
    :pairing_expires_at,
    :host_key,
    :call,
    :closing,
    :published,
    :last_rx_ms,
    :last_ping_ms,
    :check,
    :fault,
    :last_call,
    :diag_counters,
    parser: nil,
    reassembler: nil,
    wire: nil,
    gen: 0,
    phase: :hello,
    hello_due?: false,
    next_stream: 1,
    counters: %{
      faults: %{},
      control_errors: %{},
      peer_errors: %{},
      dropped: %{},
      not_sent: %{},
      diagnostics: 0
    }
  ]

  # -- the API (the port watcher and E3's management layer) -------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "The link as it stands: the view the watcher publishes."
  @spec status(GenServer.server()) :: map()
  def status(link), do: GenServer.call(link, :status, @call_timeout_ms)

  @doc """
  Starts pairing on the selected port: the first `enroll.begin`. `name` is the
  name the paired accessory's record keeps, the kind's own when nil.
  """
  @spec enroll_begin(GenServer.server(), String.t() | nil) :: :ok | {:error, term()}
  def enroll_begin(link, name \\ nil) when is_binary(name) or is_nil(name),
    do: GenServer.call(link, {:owner_pairing, {:begin, name}}, @call_timeout_ms)

  @doc """
  The owner confirmed in the app that both screens show the same code, for
  `attempt` (`nil`: whichever is open); `{:error, :stale_attempt}` when it is
  not the open one.
  """
  @spec enroll_confirm(GenServer.server(), String.t() | nil) :: :ok | {:error, term()}
  def enroll_confirm(link, attempt \\ nil),
    do: GenServer.call(link, {:owner_pairing, :confirm, attempt}, @call_timeout_ms)

  @doc "The owner said the codes differ: the next round, or the attempt closes after three."
  @spec enroll_mismatch(GenServer.server(), String.t() | nil) :: :ok | {:error, term()}
  def enroll_mismatch(link, attempt \\ nil),
    do: GenServer.call(link, {:owner_pairing, :mismatch, attempt}, @call_timeout_ms)

  @doc "The owner cancelled the pairing in the app."
  @spec enroll_cancel(GenServer.server(), String.t() | nil) :: :ok | {:error, term()}
  def enroll_cancel(link, attempt \\ nil),
    do: GenServer.call(link, {:owner_pairing, :cancel, attempt}, @call_timeout_ms)

  @doc """
  Forgets the attached accessory: it is told to erase its keys
  (`accessory.forget`), its record is erased, its call ends, and the link is
  greeted again, where it reads as unenrolled.
  """
  @spec forget(GenServer.server()) :: :ok | {:error, term()}
  def forget(link), do: GenServer.call(link, {:remove, :forget}, @call_timeout_ms)

  @doc """
  Revokes the attached accessory at the daemon alone: its record is erased and
  its call ends; it is not told, so its next attach is refused
  `unknown_accessory`.
  """
  @spec revoke(GenServer.server()) :: :ok | {:error, term()}
  def revoke(link), do: GenServer.call(link, {:remove, :revoke}, @call_timeout_ms)

  @doc """
  Starts a call from the Mac on the attached accessory, answered at once with
  its stream, or `{:refused, code}` (the code the accessory's own request
  would hear) for what the link refuses itself. Whether the call is then
  admitted shows in the link's view.
  """
  @spec start_call(GenServer.server()) ::
          {:ok, %{stream: pos_integer()}} | {:error, {:refused, String.t()}}
  def start_call(link), do: GenServer.call(link, :start_call, @call_timeout_ms)

  @doc "Ends the accessory's call `call_id` from the Mac."
  @spec end_call(GenServer.server(), String.t()) :: :ok | {:error, :no_call | :stale_call}
  def end_call(link, call_id) when is_binary(call_id),
    do: GenServer.call(link, {:to_call, call_id, {:end, :mac_end}}, @call_timeout_ms)

  @doc "The Mac's mute for the accessory's call `call_id`."
  @spec mute(GenServer.server(), String.t(), boolean()) :: :ok | {:error, :no_call | :stale_call}
  def mute(link, call_id, muted?) when is_binary(call_id) and is_boolean(muted?),
    do: GenServer.call(link, {:to_call, call_id, {:mute, muted?}}, @call_timeout_ms)

  @doc "Interrupts the assistant's speech on the accessory (a flush, then the engine's interrupt)."
  @spec interrupt(GenServer.server(), String.t()) :: :ok | {:error, :no_call | :stale_call}
  def interrupt(link, call_id) when is_binary(call_id),
    do: GenServer.call(link, {:to_call, call_id, :interrupt}, @call_timeout_ms)

  @doc "Cancels one backend task of a task-engine call."
  @spec cancel_task(GenServer.server(), String.t(), String.t()) ::
          :ok | {:error, :no_call | :stale_call}
  def cancel_task(link, call_id, delegation_id)
      when is_binary(call_id) and is_binary(delegation_id),
      do:
        GenServer.call(link, {:to_call, call_id, {:cancel_task, delegation_id}}, @call_timeout_ms)

  @doc """
  Runs one setup check on an attached accessory with no call (`priv/accessory/
  PROTOCOL.md`, *Setup checks and calibration*): `:tone`, `:mic` for
  `seconds`, `:face` (the kind's test face) or `:motion` (its test gesture).
  """
  @spec check_start(GenServer.server(), :tone | :mic | :face | :motion, pos_integer() | nil) ::
          :ok | {:error, term()}
  def check_start(link, check, seconds) when check in [:tone, :mic, :face, :motion],
    do: GenServer.call(link, {:device, {:check, check, seconds}}, @call_timeout_ms)

  @doc "Ends any running check."
  @spec check_stop(GenServer.server()) :: :ok | {:error, term()}
  def check_stop(link), do: GenServer.call(link, {:device, :check_stop}, @call_timeout_ms)

  @doc "One Calibrate head step: `:begin`, `:nudge` with `%{axis, steps}`, `:set_zero`, `:cancel`."
  @spec calibrate(GenServer.server(), atom(), map() | nil) :: :ok | {:error, term()}
  def calibrate(link, op, nudge) when op in [:begin, :nudge, :set_zero, :cancel],
    do: GenServer.call(link, {:device, {:calibrate, op, nudge}}, @call_timeout_ms)

  @doc "Changes the accessory's own `volume`, `brightness` or `motion`."
  @spec set(GenServer.server(), map()) :: :ok | {:error, term()}
  def set(link, values) when is_map(values) and map_size(values) > 0,
    do: GenServer.call(link, {:device, {:set, values}}, @call_timeout_ms)

  # -- the process --------------------------------------------------------------------

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    {:ok, new_state(opts), {:continue, :open}}
  end

  @impl true
  def handle_continue(:open, state) do
    case state.transport.open(state.path, state.transport_opts) do
      {:ok, handle} -> opened(%{state | handle: handle})
      {:error, reason} -> {:stop, {:shutdown, {:open_failed, reason}}, state}
    end
  end

  @impl true
  def handle_call(:status, _from, state), do: reply(state, summary(state))

  def handle_call({:owner_pairing, {:begin, name}}, _from, state) do
    {result, state} = owner_pairing(state, :begin, name)
    reply(state, result)
  end

  def handle_call({:owner_pairing, op, attempt}, _from, state) do
    {result, state} = owner_step(state, op, attempt)
    reply(state, result)
  end

  def handle_call({:remove, how}, _from, state) do
    {result, state} = remove(state, how)
    reply(state, result)
  end

  def handle_call(:start_call, _from, state) do
    case call_refusal(state, :mac) do
      nil -> state |> start_call_process(nil, :mac) |> start_reply()
      code -> reply(state, {:error, {:refused, code}})
    end
  end

  def handle_call({:to_call, _call_id, _command}, _from, %{call: nil} = state),
    do: reply(state, {:error, :no_call})

  def handle_call({:to_call, call_id, command}, _from, %{call: call} = state) do
    if call.call_id == call_id and not call.ending? do
      send(call.pid, command)
      reply(state, :ok)
    else
      reply(state, {:error, :stale_call})
    end
  end

  def handle_call({:device, command}, _from, state) do
    {result, state} = device(state, command)
    reply(state, result)
  end

  @impl true
  def handle_info(:tick, state), do: state |> schedule_tick() |> tick() |> continue()

  def handle_info({:EXIT, pid, reason}, %{call: %{pid: pid}} = state),
    do: state |> call_exited(reason) |> continue()

  # Any other exit is the transport's (a port whose owner traps exits) or
  # nothing of this link's.
  def handle_info({:EXIT, _other, _reason} = message, state),
    do: transport_message(state, message)

  def handle_info({:call_send, stream, message, urgent?}, state),
    do: state |> call_send(stream, message, urgent?) |> continue()

  def handle_info({:call_pcm, stream, pcm}, state),
    do: state |> call_pcm(stream, pcm) |> continue()

  def handle_info({:call_view, stream, call_id, view}, state),
    do: state |> call_view(stream, call_id, view) |> continue()

  def handle_info(message, state), do: transport_message(state, message)

  # The watcher is told why the link ended before it exits: a link that ends
  # at once (a busy port) may be gone before the watcher's monitor is in.
  defp transport_message(%{handle: nil} = state, message), do: unexpected(state, message)

  defp transport_message(state, message) do
    case state.transport.message(state.handle, message) do
      {:data, bytes} ->
        state |> received(bytes) |> continue()

      {:closed, reason} ->
        {:stop, {:shutdown, {:transport_closed, reason}}, %{state | handle: nil}}

      :unknown ->
        unexpected(state, message)
    end
  end

  @impl true
  def terminate(reason, state) do
    settle_call(state.call)
    if state.handle, do: state.transport.close(state.handle)
    state.ended.(reason)
    :ok
  end

  # The link's end settles its call before the link is gone: the call tears
  # its session down while the voice core still runs (a subtree stopping, or
  # the daemon, stops the voice core after it). Bounded inside the link's
  # shutdown time; past the bound the call is killed, and `SessionGuard`
  # tears its session down.
  defp settle_call(nil), do: :ok

  defp settle_call(%{pid: pid}) do
    send(pid, {:end, :link_gone})

    receive do
      {:EXIT, ^pid, _reason} -> :ok
    after
      @settle_call_ms ->
        Logger.error(
          "accessory link: its call did not settle in #{@settle_call_ms} ms; killing it"
        )

        Process.exit(pid, :kill)
    end
  end

  # -- start ----------------------------------------------------------------------------

  defp new_state(opts) do
    mode = Keyword.fetch!(opts, :mode)
    true = mode in [:attach, :pairing]
    home = Keyword.fetch!(opts, :home)

    %__MODULE__{
      path: Keyword.fetch!(opts, :path),
      serial: Keyword.get(opts, :serial),
      mode: mode,
      transport: Keyword.fetch!(opts, :transport),
      transport_opts: Keyword.get(opts, :transport_opts, []),
      home: home,
      store_writer: Keyword.fetch!(opts, :store_writer),
      clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end),
      send_after: Keyword.get(opts, :send_after, &Process.send_after/3),
      tick_ms: Keyword.get(opts, :tick_ms, @tick_ms),
      readiness: Keyword.fetch!(opts, :readiness),
      voice_device: Keyword.get(opts, :voice_device, fn -> Store.load_voice_device(home) end),
      utc_now: Keyword.get(opts, :utc_now, &DateTime.utc_now/0),
      notify: Keyword.get(opts, :notify, fn _summary -> :ok end),
      ended: Keyword.get(opts, :ended, fn _reason -> :ok end),
      call_module: Keyword.get(opts, :call_module, FermixChannels.Accessories.Call),
      call_opts: Keyword.get(opts, :call_opts, []),
      parser: Parser.new(:accessory),
      reassembler: Reassembler.new(),
      wire: Wire.new()
    }
  end

  defp opened(state) do
    now = now(state)

    %{state | last_rx_ms: now, last_ping_ms: now}
    |> schedule_tick()
    |> greet()
    |> continue()
  end

  # -- answering ----------------------------------------------------------------------

  defp continue(%{closing: nil} = state), do: {:noreply, publish(state)}
  defp continue(state), do: {:stop, {:shutdown, state.closing}, state}

  defp reply(%{closing: nil} = state, value), do: {:reply, value, publish(state)}
  defp reply(state, value), do: {:stop, {:shutdown, state.closing}, value, state}

  defp start_reply(%{call: %{stream: stream}} = state), do: reply(state, {:ok, %{stream: stream}})
  defp start_reply(state), do: reply(state, {:error, {:refused, "call_failed"}})

  defp unexpected(state, message) do
    Logger.debug("accessory link ignored an unexpected message: #{inspect(message, limit: 8)}")
    {:noreply, state}
  end

  defp publish(state) do
    view = summary(state)
    if view != state.published, do: state.notify.(view)
    %{state | published: view}
  end

  # -- HELLO ------------------------------------------------------------------------------

  # A HELLO now when the rate allows, or at the first tick that does.
  defp greet(state) do
    if Attach.may_hello?(state.challenge, now(state)),
      do: send_hello(state),
      else: move(%{state | hello_due?: true}, :hello, :link_restart)
  end

  defp send_hello(state) do
    case host_key(state) do
      {:ok, host} -> hello_with(state, host)
      {:error, reason} -> %{state | closing: {:host_key, reason}}
    end
  end

  defp hello_with(state, host) do
    gen = if state.gen >= @max_gen, do: 1, else: state.gen + 1
    challenge = Attach.challenge(host, gen, now(state))
    state = move(state, :hello, :link_restart)

    %{
      state
      | gen: gen,
        challenge: challenge,
        host_key: host,
        hello_due?: false,
        verified: nil,
        refusal: nil,
        refused_range: nil,
        check: nil,
        fault: nil,
        diag_counters: nil,
        readiness_sent: nil,
        parser: Parser.reset(state.parser),
        reassembler: Reassembler.new()
    }
    |> transmit(Attach.hello(challenge))
  end

  # A port an enrolled accessory's hint named holds a key made at its
  # enrollment; the port the owner selected makes the home's key on its first
  # pairing, since even an unenrolled accessory's HELLO names the host.
  defp host_key(%{mode: :pairing} = state), do: StoreWriter.ensure_host_key(state.store_writer)

  defp host_key(state) do
    case Store.load_host_key(state.home) do
      {:ok, host} -> {:ok, host}
      :absent -> {:error, :no_host_key}
      {:error, reason} -> {:error, reason}
    end
  end

  # The link starts again: whatever it carried ends, and a new HELLO follows.
  defp restart(state, reason) do
    state
    |> stop_call(reason)
    |> reset_pairing()
    |> greet()
  end

  # -- ticks ------------------------------------------------------------------------------

  defp schedule_tick(state) do
    _ref = state.send_after.(self(), :tick, state.tick_ms)
    state
  end

  defp tick(state) do
    state
    |> step(&tick_parser/1)
    |> step(&tick_hello/1)
    |> step(&tick_attach_deadline/1)
    |> step(&tick_liveness/1)
    |> step(&tick_heartbeat/1)
    |> step(&tick_pairing/1)
  end

  defp step(%{closing: nil} = state, fun), do: fun.(state)
  defp step(state, _fun), do: state

  defp tick_parser(state), do: received(state, <<>>)

  defp tick_hello(%{hello_due?: true} = state) do
    if Attach.may_hello?(state.challenge, now(state)), do: send_hello(state), else: state
  end

  defp tick_hello(state), do: state

  defp tick_attach_deadline(%{phase: phase, challenge: %{deadline_ms: deadline}} = state)
       when phase in [:hello, :proving] do
    if now(state) >= deadline, do: attach_timed_out(state), else: state
  end

  defp tick_attach_deadline(state), do: state

  defp attach_timed_out(%{mode: :pairing} = state), do: %{state | closing: :no_answer}

  defp attach_timed_out(state) do
    attach_telemetry(state, :auth_timeout, nil)
    %{greet(state) | refusal: :auth_timeout}
  end

  # The accessory's own word that the attach ran out of time is taken as the
  # host's own deadline: a new HELLO, at the HELLO rate. Its other refusals
  # hold the port idle (`accessory_refused`).
  defp accessory_timed_out(state) do
    attach_telemetry(state, :accessory_refused, :auth_timeout)
    %{greet(state) | refusal: {:accessory, :auth_timeout}}
  end

  defp tick_liveness(%{phase: phase} = state) when phase in [:proving, :attached, :unenrolled] do
    {bound, since_ms} = liveness_window(state)

    if now(state) - since_ms >= bound,
      do: fault(state, :link_lost, :liveness),
      else: state
  end

  defp tick_liveness(state), do: state

  # A call's shorter bound counts from the call's start as well: outside a
  # call the peer's last frame can be a whole idle ping old.
  defp liveness_window(%{call: nil} = state), do: {@lost_idle_ms, state.last_rx_ms}

  defp liveness_window(%{call: call} = state),
    do: {@lost_call_ms, max(state.last_rx_ms, call.since_ms)}

  defp tick_heartbeat(%{phase: phase} = state) when phase in [:attached, :unenrolled] do
    interval = if state.call, do: @ping_call_ms, else: @ping_idle_ms

    if now(state) - state.last_ping_ms >= interval,
      do: %{state | last_ping_ms: now(state)} |> transmit(%{type: "ping"}) |> send_readiness(),
      else: state
  end

  defp tick_heartbeat(state), do: state

  defp tick_pairing(%{enrollment: nil} = state), do: state

  defp tick_pairing(state) do
    {effects, enrollment} = Pairing.tick(state.enrollment, now(state))
    run_effects(%{state | enrollment: enrollment}, effects)
  end

  # -- receiving --------------------------------------------------------------------------

  defp received(state, bytes) do
    {events, parser} = Parser.feed(state.parser, bytes, now(state))
    Enum.reduce(events, %{state | parser: parser}, &on_event/2)
  end

  defp on_event(_event, %{closing: closing} = state) when closing != nil, do: state
  defp on_event({:fault, reason}, state), do: fault(state, reason, :receive)

  defp on_event({:frame, frame}, state),
    do: on_frame(%{state | last_rx_ms: now(state)}, frame)

  defp on_frame(state, %Frame{type: :control} = frame) do
    case Reassembler.feed(state.reassembler, frame) do
      {:more, reassembler} -> %{state | reassembler: reassembler}
      {:message, stream, payload, r} -> on_payload(%{state | reassembler: r}, stream, payload)
      {:fault, reason, r} -> fault(%{state | reassembler: r}, reason, :reassembly)
    end
  end

  defp on_frame(state, %Frame{type: :mic} = frame), do: on_mic(state, frame)

  defp on_frame(state, %Frame{type: :diagnostics}),
    do: update_in(state.counters.diagnostics, &(&1 + 1))

  defp fault(state, reason, stage) do
    Logger.warning("accessory link #{state.path}: #{stage} fault #{reason}; greeting it again")
    Telemetry.emit_fault(reason, stage, 1)
    state |> count(:faults, reason) |> restart(:link_fault)
  end

  defp on_payload(state, stream, payload) do
    case Control.decode(:accessory, stream, payload) do
      {:ok, message} -> on_message(state, message)
      {:error, reason} -> control_error(state, reason)
    end
  end

  # Answered and counted; nothing acts on the message.
  defp control_error(state, reason) do
    {kind, code, type} = control_refusal(reason)
    Telemetry.emit_fault(kind, :control, 1)

    state
    |> count(:control_errors, kind)
    |> transmit(error_message(code, type))
  end

  defp control_refusal(:invalid_json), do: {:invalid_json, "invalid_message", nil}
  defp control_refusal({:unknown_message, type}), do: {:unknown_message, "unknown_message", type}

  defp control_refusal({:invalid_message, type, _field}),
    do: {:invalid_message, "invalid_message", type}

  defp control_refusal({:wrong_stream, type}), do: {:wrong_stream, "invalid_message", type}

  # `message_type` is text of at most 32 printable characters: a peer's type
  # that is not is left out rather than echoed.
  defp error_message(code, type) do
    if is_binary(type) and byte_size(type) in 1..32 and printable?(type),
      do: %{type: "error", code: code, message_type: type},
      else: %{type: "error", code: code}
  end

  # A `hello_ack` answers the attaching link's challenge alone; in any other
  # phase it is out of phase like any other message, and changes nothing.
  defp on_message(%{phase: :hello} = state, %{type: "hello_ack"} = ack),
    do: on_hello_ack(state, ack)

  defp on_message(%{gen: gen} = state, %{gen: other}) when other != gen,
    do: count(state, :dropped, :stale_generation)

  defp on_message(state, %{type: type} = message) do
    if type in @always or type in Map.fetch!(@by_phase, state.phase),
      do: dispatch(state, message),
      else: transmit(state, error_message("not_now", type))
  end

  defp dispatch(state, %{type: "refuse", code: "auth_timeout"}), do: accessory_timed_out(state)

  defp dispatch(state, %{type: "pong"}), do: state
  defp dispatch(state, %{type: "refuse"} = refusal), do: accessory_refused(state, refusal)
  defp dispatch(state, %{type: "error"} = error), do: peer_error(state, error)
  defp dispatch(state, %{type: "attached", state: accessory}), do: on_attached(state, accessory)

  defp dispatch(state, %{type: "accessory.state"} = message),
    do: %{state | accessory_state: Map.drop(message, [:type, :gen])}

  # The latest microphone opening's levels go to the call alone, never into
  # the link's view (`accessories.status`).
  defp dispatch(state, %{type: "diag.counters", counters: counters} = message) do
    levels = Map.drop(message, [:type, :gen, :counters])
    diag_to_call(%{state | diag_counters: counters}, counters, levels)
  end

  # The accessory's own fault is kept until the next HELLO, so the Mac says
  # it (M91 E3: "StackChan reports a problem").
  defp dispatch(state, %{type: "diag.fault", code: code}) do
    Logger.warning("accessory #{state.path} reported a fault: #{code}")
    Telemetry.emit_fault(:accessory_fault, :peer, 1)
    %{state | fault: code}
  end

  defp dispatch(state, %{type: "check.level", rms: rms}), do: check_level(state, rms)
  defp dispatch(state, %{type: "check.result"} = result), do: check_result(state, result)

  defp dispatch(state, %{type: "enroll." <> _} = message), do: accessory_pairing(state, message)
  defp dispatch(state, %{type: "call.request"} = request), do: call_request(state, request)

  defp dispatch(state, %{type: type} = message) when type in @call_scoped,
    do: to_call(state, message)

  defp dispatch(state, %{type: "diag.chunk"}), do: state

  # The robot's own counters and levels ride its call's link event too (M91 F3).
  defp diag_to_call(%{call: %{pid: pid, ending?: false}} = state, counters, levels) do
    send(pid, {:robot_diag, counters, levels})
    state
  end

  defp diag_to_call(state, _counters, _levels), do: state

  defp peer_error(state, %{code: code} = error) do
    Logger.warning("accessory #{state.path} refused a host message: #{inspect(error)}")
    state = count(state, :peer_errors, code)

    if code in @call_ending_errors and state.call != nil,
      do: tap_call(state, {:robot_error, code}),
      else: state
  end

  # -- attach -----------------------------------------------------------------------------

  defp on_hello_ack(%{challenge: nil} = state, _ack), do: count(state, :dropped, :no_challenge)

  defp on_hello_ack(state, ack) do
    case Store.list(state.home) do
      {:ok, records} -> verify_ack(state, ack, records)
      {:error, reason} -> store_unreadable(state, reason)
    end
  end

  defp verify_ack(state, ack, records) do
    {result, challenge} = Attach.verify(state.challenge, ack, records, now(state))
    state = %{state | challenge: challenge}
    if match?({:ignored, _}, result), do: state, else: attach_result(peer(state, ack), result)
  end

  defp peer(state, ack),
    do: %{state | peer: Map.take(ack, [:kind, :firmware, :wire, :caps, :pack, :accessory_id])}

  defp attach_result(state, {:ok, verified}) do
    %{state | verified: verified}
    |> move(:proving, :link_restart)
    |> transmit(Attach.host_proof(verified, state.host_key))
  end

  defp attach_result(state, {:unenrolled, _info}) do
    attach_telemetry(state, :unenrolled, nil)
    move(%{state | last_ping_ms: now(state)}, :unenrolled, :link_restart)
  end

  # An answer past the attach bound is refused and the link greeted again
  # (PROTOCOL.md, *Timing bounds*); every other refusal holds the port idle.
  defp attach_result(state, {:error, :auth_timeout}) do
    attach_telemetry(state, :auth_timeout, nil)
    state = transmit(state, refuse_message(:auth_timeout))
    %{greet(state) | refusal: :auth_timeout}
  end

  defp attach_result(state, {:error, refusal}) do
    attach_telemetry(state, refusal, nil)

    %{state | refusal: refusal}
    |> move(:refused, :refused)
    |> transmit(refuse_message(refusal))
  end

  defp refuse_message(:wire_version) do
    {wire_min, wire_max} = Control.supported_wire_range()
    %{type: "refuse", code: "wire_version", wire_min: wire_min, wire_max: wire_max}
  end

  defp refuse_message(refusal), do: %{type: "refuse", code: Atom.to_string(refusal)}

  defp store_unreadable(state, reason) do
    Logger.error(
      "accessory link #{state.path}: the pairing store is unreadable: #{inspect(reason)}"
    )

    move(%{state | refusal: {:store_unreadable, reason}}, :refused, :store_unreadable)
  end

  defp on_attached(state, accessory) do
    attach_telemetry(state, :attached, nil)

    %{state | mode: :attach, accessory_state: accessory, last_ping_ms: now(state)}
    |> move(:attached, nil)
    |> send_readiness()
  end

  # An accessory's `wire_version` refusal names its own range, which says
  # which side to update (PROTOCOL.md, *Versioning*).
  defp accessory_refused(state, %{code: code} = refusal) do
    reason = Map.fetch!(@refusals, code)
    attach_telemetry(state, :accessory_refused, reason)
    range = if reason == :wire_version, do: {refusal[:wire_min], refusal[:wire_max]}

    %{state | refusal: {:accessory, reason}, refused_range: range}
    |> move(:refused, :refused)
  end

  defp attach_telemetry(state, status, accessory_refusal) do
    opened = if state.challenge, do: state.challenge.opened_ms, else: now(state)

    Telemetry.emit_attach(status, max(now(state) - opened, 0) * 1_000, %{
      mode: state.mode,
      phase: state.phase,
      kind: state.peer && state.peer.kind,
      accessory_id: state.verified && state.verified.accessory.accessory_id,
      accessory_refusal: accessory_refusal
    })
  end

  defp send_readiness(%{phase: :attached} = state) do
    readiness = state.readiness.()

    if readiness == state.readiness_sent,
      do: state,
      else: %{state | readiness_sent: readiness} |> transmit(readiness_message(readiness))
  end

  defp send_readiness(state), do: state

  defp readiness_message(:ready), do: %{type: "voice.readiness", ready: true}

  defp readiness_message({:not_ready, code}) when is_binary(code),
    do: %{type: "voice.readiness", ready: false, code: code}

  # -- pairing ----------------------------------------------------------------------------

  defp owner_pairing(state, :begin, name) do
    cond do
      state.mode != :pairing -> {{:error, :not_pairing}, state}
      state.phase == :attached -> {{:error, :already_paired}, state}
      state.phase != :unenrolled -> {{:error, :not_unenrolled}, state}
      Pairing.open?(state.enrollment) -> {{:error, :pairing_open}, state}
      true -> begin_pairing(%{state | pairing_name: name})
    end
  end

  # Every step names the attempt it was drawn from (M91 §07: bind every step
  # to a daemon-issued attempt ID); `nil` is whichever is open.
  defp owner_step(%{enrollment: nil} = state, _op, _attempt), do: {{:error, :no_pairing}, state}

  defp owner_step(%{enrollment: %{attempt: open}} = state, _op, attempt)
       when attempt != nil and attempt != open,
       do: {{:error, :stale_attempt}, state}

  defp owner_step(state, op, _attempt) do
    {effects, enrollment} =
      Pairing.owner(state.enrollment, op, state.host_key, state.gen, now(state))

    {:ok, run_effects(%{state | enrollment: enrollment}, effects)}
  end

  # The home's key exists from this link's HELLO on; it is asked for again
  # here, at the first `enroll.begin`, so a pairing never starts without it.
  defp begin_pairing(state) do
    case StoreWriter.ensure_host_key(state.store_writer) do
      {:ok, host} ->
        {effects, enrollment} = Pairing.begin(host, state.gen, now(state))
        expires_at = DateTime.add(state.utc_now.(), div(Enrollment.window_ms(), 1_000), :second)

        state = %{state | host_key: host, enrollment: enrollment, pairing_expires_at: expires_at}
        {:ok, run_effects(state, effects)}

      {:error, reason} ->
        {{:error, {:host_key, reason}}, state}
    end
  end

  defp accessory_pairing(%{enrollment: nil} = state, _message),
    do: count(state, :dropped, :no_pairing)

  defp accessory_pairing(state, message) do
    {effects, enrollment} =
      Pairing.accessory(state.enrollment, message, state.host_key, state.gen, now(state))

    run_effects(%{state | enrollment: enrollment}, effects)
  end

  defp reset_pairing(%{enrollment: nil} = state), do: state

  defp reset_pairing(state) do
    {effects, enrollment} = Pairing.link_reset(state.enrollment)
    run_effects(%{state | enrollment: enrollment}, effects)
  end

  defp run_effects(state, effects), do: Enum.reduce(effects, state, &effect/2)

  defp effect({:send, message}, state), do: transmit(state, message)
  defp effect({:ignored, reason}, state), do: count(state, :dropped, reason)
  # The accessory committed: from here the port is an enrolled accessory's,
  # so its attach times out into a new HELLO, never into `no_answer`.
  defp effect({:enrolled, enrolled}, state),
    do: %{write_record(state, enrolled) | mode: :attach} |> greet()

  defp write_record(state, %{accessory_id: id, accessory_pk: pk}) do
    {:ok, meta} = Attach.kind_metadata(state.peer.kind)

    record = %Record{
      accessory_id: id,
      accessory_pk: pk,
      kind: state.peer.kind,
      name: state.pairing_name || meta.display_name,
      port_hint: state.serial,
      enrolled_at: DateTime.utc_now()
    }

    # The accessory committed; a record the host fails to write is refused
    # `unknown_accessory` at its next attach, where it offers to forget its side.
    case StoreWriter.put(state.store_writer, record) do
      :ok -> state
      {:error, reason} -> count(state, :not_sent, {:record, reason})
    end
  end

  # -- forget and revoke -----------------------------------------------------------------

  defp remove(%{phase: :attached} = state, how) do
    id = state.verified.accessory.accessory_id
    state = stop_call(state, :forgotten)
    state = if how == :forget, do: transmit(state, %{type: "accessory.forget"}), else: state

    case StoreWriter.forget(state.store_writer, id) do
      :ok -> {:ok, greet(state)}
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp remove(state, _how), do: {{:error, :not_attached}, state}

  # -- setup checks, calibration and settings -------------------------------------------

  # Only on an attached accessory with no call, and only what it reported the
  # capability of (PROTOCOL.md, *Setup checks and calibration*, *Capabilities*).
  defp device(state, command) do
    with :ok <- quiet(state),
         {:ok, message, urgent?} <- device_message(state, command),
         :ok <- device_capable(state, message) do
      {:ok, state |> transmit(message, urgent?) |> checking(command)}
    else
      {:error, _reason} = refused -> {refused, state}
    end
  end

  defp quiet(%{phase: :attached, call: nil}), do: :ok
  defp quiet(%{phase: :attached}), do: {:error, :call_active}
  defp quiet(_state), do: {:error, :not_attached}

  defp device_message(_state, {:check, :tone, _seconds}),
    do: {:ok, %{type: "check.tone"}, false}

  defp device_message(_state, {:check, :mic, seconds}) when seconds in 1..10,
    do: {:ok, %{type: "check.mic", seconds: seconds}, false}

  defp device_message(state, {:check, :face, _seconds}),
    do: {:ok, %{type: "check.face", pose: kind_pin(state, :face_pose)}, false}

  defp device_message(state, {:check, :motion, _seconds}),
    do: {:ok, %{type: "check.motion", gesture: kind_pin(state, :motion_gesture)}, false}

  defp device_message(_state, :check_stop), do: {:ok, %{type: "check.stop"}, true}

  defp device_message(_state, {:calibrate, :nudge, %{axis: axis, steps: steps}})
       when axis in [:pan, :tilt] and steps in -64..64 and steps != 0 do
    message = %{
      type: "accessory.calibrate",
      op: "nudge",
      axis: Atom.to_string(axis),
      steps: steps
    }

    {:ok, message, false}
  end

  defp device_message(_state, {:calibrate, op, nil}) when op in [:begin, :set_zero, :cancel],
    do: {:ok, %{type: "accessory.calibrate", op: Atom.to_string(op)}, false}

  defp device_message(_state, {:set, values}) when map_size(values) > 0,
    do:
      {:ok, Map.put(Map.take(values, [:volume, :brightness, :motion]), :type, "accessory.set"),
       false}

  # Anything else is outside the contract's own set (a check's seconds out of
  # range, a nudge with no axis, a step that takes none): refused, never sent.
  defp device_message(_state, _command), do: {:error, :invalid_command}

  defp kind_pin(state, key) do
    {:ok, meta} = Attach.kind_metadata(state.verified.kind)
    Map.fetch!(meta, key)
  end

  # `accessory.set`'s `motion` needs the capability its message type does not
  # name; everything else is the type's own.
  defp device_capable(state, %{type: "accessory.set"} = message) do
    if Map.has_key?(message, :motion) and :motion not in caps(state),
      do: {:error, {:capability_missing, :motion}},
      else: :ok
  end

  defp device_capable(state, %{type: type}), do: capable(state, type)

  defp checking(state, {:check, check, _seconds}),
    do: %{state | check: %{check: check, status: :running, code: nil, level: nil}}

  defp checking(state, _command), do: state

  defp check_level(%{check: %{status: :running} = check} = state, rms),
    do: %{state | check: %{check | level: rms}}

  defp check_level(state, _rms), do: count(state, :dropped, :no_check)

  defp check_result(state, %{check: check, result: result} = message) do
    level = if state.check, do: state.check.level

    %{
      state
      | check: %{
          check: Map.fetch!(@checks, check),
          status: String.to_existing_atom(result),
          code: message[:code],
          level: level
        }
    }
  end

  # -- calls ------------------------------------------------------------------------------

  defp call_request(state, %{request: request, source: source}) do
    case call_refusal(state, :accessory) do
      nil -> start_call_process(state, request, Map.fetch!(@sources, source))
      code -> transmit(state, refused_result(request, code))
    end
  end

  # A tap asks for a call on the accessory it came from, which must be the
  # voice device; the Mac's start is the owner choosing this accessory now.
  defp call_refusal(state, origin) do
    cond do
      state.phase != :attached -> "not_attached"
      state.call != nil -> "call_in_progress"
      state.next_stream > @max_stream -> "stream_ids_exhausted"
      low_power?(state) -> "power_too_low"
      origin == :accessory -> choice_refusal(state) || readiness_refusal(state.readiness.())
      true -> unreadable_refusal(state) || readiness_refusal(state.readiness.())
    end
  end

  # The Mac names this accessory, so its start needs no choice of it; a choice
  # that cannot be read still refuses it, as it refuses a tap.
  defp unreadable_refusal(state) do
    case state.voice_device.() do
      {:error, _why} = read -> voice_device_unreadable(state, read, :voice_device_unreadable)
      {:ok, _device} -> nil
    end
  end

  defp low_power?(%{accessory_state: %{power: power}}), do: power in @low_power
  defp low_power?(_state), do: false

  # A tap needs this accessory to be the voice device; a choice that cannot be
  # read refuses it with its own reason (`VoiceDevice.refusal/3`), never read
  # as chosen or not.
  defp choice_refusal(%{verified: %{accessory: %{accessory_id: id}}} = state) do
    read = state.voice_device.()

    case VoiceDevice.refusal({:accessory, id}, read, true) do
      {:error, {reason, _device, _sentence}} -> voice_device_unreadable(state, read, reason)
      :ok -> if read == {:ok, {:accessory, id}}, do: nil, else: "not_selected"
    end
  end

  defp voice_device_unreadable(state, {:error, why}, reason) do
    Logger.error(
      "accessory link #{state.path}: the voice device could not be read: #{inspect(why)}"
    )

    Atom.to_string(reason)
  end

  defp readiness_refusal(:ready), do: nil
  defp readiness_refusal({:not_ready, code}), do: code

  defp refused_result(request, code),
    do: %{type: "call.result", request: request, result: "refused", code: code}

  defp start_call_process(state, request, source) do
    stream = state.next_stream
    accessory = state.verified.accessory

    opts =
      [
        link: self(),
        stream: stream,
        request: request,
        source: source,
        endpoint: {:accessory, accessory.accessory_id},
        caps: state.verified.caps,
        robot_diag: state.diag_counters
      ] ++ state.call_opts

    case state.call_module.start_link(opts) do
      {:ok, pid} ->
        call =
          pid
          |> new_call(stream, request, source, now(state))
          |> Map.put(:accessory_id, accessory.accessory_id)

        %{state | call: call, next_stream: stream + 1}

      {:error, reason} ->
        call_not_started(state, request, reason)
    end
  end

  defp new_call(pid, stream, request, source, since_ms),
    do: %{
      pid: pid,
      stream: stream,
      request: request,
      source: source,
      since_ms: since_ms,
      call_id: nil,
      view: nil,
      end_reason: nil,
      result?: false,
      started?: false,
      ending?: false
    }

  defp call_not_started(state, request, reason) do
    Logger.error("accessory link #{state.path}: a call could not start: #{inspect(reason)}")
    if request, do: transmit(state, refused_result(request, "call_failed")), else: state
  end

  # What the call sends goes out only while it is the link's current call.
  defp call_send(%{call: %{stream: stream, ending?: false}} = state, stream, message, urgent?) do
    state = mark_call(state, message)
    transmit(state, message, urgent?)
  end

  defp call_send(state, _stream, _message, _urgent?), do: count(state, :dropped, :stale_call)

  defp mark_call(state, %{type: "call.result"}), do: put_in(state.call.result?, true)

  # Admitted: the call has its id, which the Mac's controls name.
  defp mark_call(state, %{type: "call.start", call: call_id}),
    do: %{state | call: %{state.call | started?: true, call_id: call_id}}

  defp mark_call(state, _message), do: state

  defp call_view(%{call: %{stream: stream}} = state, stream, call_id, view),
    do: %{state | call: %{state.call | view: view, call_id: state.call.call_id || call_id}}

  defp call_view(state, _stream, _call_id, _view), do: state

  defp call_pcm(%{call: %{stream: stream, ending?: false}} = state, stream, pcm),
    do: write_speaker(state, stream, pcm)

  defp call_pcm(state, _stream, _pcm), do: count(state, :dropped, :stale_call)

  defp on_mic(
         %{call: %{stream: stream, ending?: false} = call} = state,
         %Frame{stream: stream} = frame
       ) do
    send(call.pid, {:mic, frame.seq, frame.payload})
    state
  end

  defp on_mic(state, _frame), do: count(state, :dropped, :mic_off_call)

  defp to_call(%{call: %{stream: stream, ending?: false}} = state, %{stream: stream} = message),
    do: tap_call(state, {:robot, message})

  defp to_call(state, _message), do: count(state, :dropped, :stale_stream)

  defp tap_call(state, message) do
    send(state.call.pid, message)
    state
  end

  # Every change of phase goes through here, so the one invariant holds on
  # every path: a call lives only on an attached link, and leaving `:attached`
  # ends it, for `why`.
  defp move(state, :attached, _why), do: %{state | phase: :attached}
  defp move(state, phase, why), do: %{stop_call(state, why) | phase: phase}

  # The link ends its call itself: the accessory is told at once, and the call
  # process tears its session down and exits.
  defp stop_call(%{call: nil} = state, _reason), do: state
  defp stop_call(%{call: %{ending?: true}} = state, _reason), do: state

  defp stop_call(%{call: call} = state, reason) do
    send(call.pid, {:end, reason})
    state = %{state | call: %{call | ending?: true, end_reason: reason}}
    if call.started?, do: transmit(state, call_end(call.stream, reason), true), else: state
  end

  # The call's own reason is already its wire token; the link's are atoms.
  defp call_end(stream, reason) when is_atom(reason), do: call_end(stream, Atom.to_string(reason))

  defp call_end(stream, reason) when is_binary(reason),
    do: %{type: "call.end", stream: stream, reason: reason}

  defp call_exited(%{call: call} = state, reason) do
    state = %{state | call: nil, last_call: last_call(state, call, reason)}
    if call.ending?, do: state, else: call_settled(state, call, reason)
  end

  # How the call ended, for the Mac (`accessories.status`'s `last_call`): the
  # call's own reason, the refusal's code, or the link's reason for ending it.
  defp last_call(state, call, reason) do
    %{
      accessory_id: call.accessory_id,
      call_id: call.call_id,
      reason: ended_reason(call, reason),
      ended_at: state.utc_now.()
    }
  end

  defp ended_reason(%{ending?: true, end_reason: :forgotten}, _reason), do: "forgotten"
  defp ended_reason(%{ending?: true, end_reason: :mac_end}, _reason), do: "mac_end"
  defp ended_reason(%{ending?: true}, _reason), do: "link_lost"
  defp ended_reason(_call, {:shutdown, {:refused, code}}), do: code
  defp ended_reason(_call, {:shutdown, {:call_ended, reason}}), do: reason
  defp ended_reason(_call, _reason), do: "call_failed"

  defp call_settled(state, _call, {:shutdown, {:refused, _code}}), do: state

  defp call_settled(state, call, {:shutdown, {:call_ended, reason}}) do
    if call.started?, do: transmit(state, call_end(call.stream, reason), true), else: state
  end

  defp call_settled(state, call, reason) do
    Logger.error("accessory link #{state.path}: call #{call.stream} failed: #{inspect(reason)}")

    state =
      if call.started?,
        do: transmit(state, call_end(call.stream, :call_failed), true),
        else: state

    if call.request && not call.result?,
      do: transmit(state, refused_result(call.request, "call_failed")),
      else: state
  end

  # -- sending ----------------------------------------------------------------------------

  defp transmit(state, message, urgent? \\ false)
  defp transmit(%{closing: closing} = state, _message, _urgent?) when closing != nil, do: state

  defp transmit(state, message, urgent?) do
    message = Map.put(message, :gen, state.gen)

    with :ok <- capable(state, message.type),
         {:ok, frames, wire} <- Wire.control(state.wire, message, urgent?) do
      write(%{state | wire: wire}, frames)
    else
      {:error, reason} -> not_sent(state, message.type, reason)
    end
  end

  defp write_speaker(state, stream, pcm) do
    with :ok <- capable(state, "spk.begin"),
         {:ok, frame, wire} <- Wire.speaker(state.wire, stream, pcm) do
      write(%{state | wire: wire}, frame)
    else
      {:error, reason} -> not_sent(state, "speaker", reason)
    end
  end

  defp capable(state, type) do
    case Control.capability(type) do
      nil -> :ok
      needed -> if needed in caps(state), do: :ok, else: {:error, {:capability_missing, needed}}
    end
  end

  defp caps(%{verified: %Attach.Verified{caps: caps}}), do: caps
  defp caps(_state), do: []

  defp write(state, iodata) do
    case state.transport.write(state.handle, iodata) do
      :ok -> state
      {:error, reason} -> %{state | closing: {:write_failed, reason}}
    end
  end

  # The host's own bug: logged and counted, never sent.
  defp not_sent(state, type, reason) do
    Logger.error("accessory link #{state.path}: did not send #{type}: #{inspect(reason)}")
    count(state, :not_sent, type)
  end

  # -- the view ---------------------------------------------------------------------------

  defp summary(state) do
    %{
      path: state.path,
      serial: state.serial,
      mode: state.mode,
      phase: state.phase,
      gen: state.gen,
      accessory_id: accessory(state, :accessory_id),
      name: accessory(state, :name),
      kind: state.peer && state.peer.kind,
      firmware: state.peer && state.peer.firmware,
      caps: summary_caps(state),
      accessory_state: state.accessory_state,
      refusal: state.refusal,
      voice: state.readiness_sent,
      wire: state.peer && state.peer.wire,
      refused_range: state.refused_range,
      enrollment: enrollment_summary(state),
      call: call_summary(state.call),
      check: state.check,
      fault: state.fault,
      diag: state.diag_counters,
      last_call: state.last_call,
      counters: state.counters
    }
  end

  defp enrollment_summary(%{enrollment: nil}), do: nil

  defp enrollment_summary(state),
    do: Map.put(Pairing.summary(state.enrollment), :expires_at, state.pairing_expires_at)

  # `phase`: `starting` until the call is admitted, `ending` while it settles.
  defp call_summary(nil), do: nil

  defp call_summary(call) do
    phase =
      cond do
        call.ending? -> :ending
        call.started? -> :active
        true -> :starting
      end

    %{
      call_id: call.call_id,
      stream: call.stream,
      source: call.source,
      phase: phase,
      ending?: call.ending?,
      view: call.view
    }
  end

  defp accessory(%{verified: %Attach.Verified{accessory: record}}, key),
    do: Map.fetch!(record, key)

  defp accessory(_state, _key), do: nil

  defp summary_caps(%{verified: %Attach.Verified{caps: caps}}), do: caps

  defp summary_caps(%{peer: %{caps: caps}}),
    do: Capabilities.effective(Capabilities.host(), caps)

  defp summary_caps(_state), do: []

  defp count(state, group, key),
    do: update_in(state.counters[group], &Map.update(&1, key, 1, fn n -> n + 1 end))

  defp now(state), do: state.clock.()

  defp printable?(<<char, rest::binary>>) when char in 0x21..0x7E, do: printable?(rest)
  defp printable?(<<>>), do: true
  defp printable?(_other), do: false
end
