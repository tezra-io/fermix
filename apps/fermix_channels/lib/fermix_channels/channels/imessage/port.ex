defmodule FermixChannels.Channels.IMessage.Port do
  @moduledoc """
  Owns the Fermix Messages helper's OS process (MILESTONE_54 §5.1) and is the
  production `IMessage.Helper`.

  The helper is spawned as `<executable> serve --home <FERMIX_HOME>` and spoken
  to in NDJSON over stdio (`IMessage.Protocol`), with a request id per call, a
  per-request timeout and at most 32 requests outstanding. The helper
  re-execs itself disclaimed; the engine never spawns it through the disclaim
  shim and has no undisclaimed variant. Its stderr is its own redacted log and
  stays off the data channel.

  `initialize` is the first request of every spawn. At boot a protocol mismatch
  refuses to start (`{:error, :helper_protocol_mismatch}`), so the channel's
  supervisor fails loud with that class. Every other helper failure leaves this
  process running: the exit status is classified, `64` (usage) and `70`–`72`
  (the disclaim contract) and a mismatch are never retried, anything else is
  re-spawned with backoff from 5 s doubling to a 60 s cap, retried
  indefinitely. The transport telemetry fires on transitions only: one
  `:degraded` at the first failure, one `:recovered` when a spawn answers
  `initialize` again. A raise in this module's own code still crashes it.
  """

  use GenServer

  @behaviour FermixChannels.Channels.IMessage.Helper

  require Logger

  alias FermixChannels.Channels.IMessage.Protocol
  alias FermixChannels.Telemetry, as: ChannelTelemetry

  @backoff_initial_ms 5_000
  @backoff_max_ms 60_000
  @init_timeout_ms 10_000
  # The helper's own `busy` threshold (§6); the engine refuses past it too, so
  # a stuck helper never accumulates an unbounded pending table here.
  @max_outstanding 32
  @line_chunk_bytes 65_536
  @max_line_bytes 16 * 1_024 * 1_024
  @max_buffered_notifications 256
  @shutdown_wait_ms 2_000
  # The Port answers every request through its own timer; the GenServer.call
  # budget only has to outlast that timer.
  @call_margin_ms 1_000
  @never_retried_exits [64, 70, 71, 72]

  @exit_meanings %{
    0 => "exited",
    64 => "usage error",
    70 => "disclaim API unavailable",
    71 => "disclaim refused",
    72 => "exec failed",
    74 => "I/O error",
    75 => "temporary failure",
    76 => "protocol error on stdin"
  }

  @type class ::
          {:helper_exit, integer()}
          | :helper_missing
          | {:helper_spawn_failed, atom()}
          | :helper_timeout
          | :helper_protocol_mismatch
          | :helper_initialize_failed
          | :protocol_error

  @type status :: %{
          status: :up | :backoff | :failed,
          class: class() | nil,
          failures: non_neg_integer(),
          outstanding: non_neg_integer()
        }

  # --- Public API ------------------------------------------------------------

  @doc """
  Starts the port. Options: `:executable` and `:home` (required), `:name`,
  `:backoff_initial_ms`, `:backoff_max_ms`, `:init_timeout_ms`,
  `:max_outstanding` (tests shrink these).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl FermixChannels.Channels.IMessage.Helper
  @spec call(GenServer.server(), String.t(), map(), pos_integer()) ::
          {:ok, map()} | {:error, FermixChannels.Channels.IMessage.Helper.error()}
  def call(server, method, params, timeout)
      when is_binary(method) and is_map(params) and is_integer(timeout) and timeout > 0 do
    GenServer.call(server, {:request, method, params, timeout}, timeout + @call_margin_ms)
  catch
    :exit, {:noproc, _call} -> {:error, not_running()}
    :exit, {:timeout, _call} -> {:error, timed_out(method, timeout)}
  end

  @impl FermixChannels.Channels.IMessage.Helper
  @spec attach(GenServer.server(), pid()) ::
          {:ok, map()} | {:error, FermixChannels.Channels.IMessage.Helper.error()}
  def attach(server, pid) when is_pid(pid) do
    GenServer.call(server, {:attach, pid})
  catch
    :exit, {:noproc, _call} -> {:error, not_running()}
  end

  @impl FermixChannels.Channels.IMessage.Helper
  @spec home(GenServer.server()) ::
          {:ok, String.t()} | {:error, FermixChannels.Channels.IMessage.Helper.error()}
  def home(server) do
    GenServer.call(server, :home)
  catch
    :exit, {:noproc, _call} -> {:error, not_running()}
  end

  @doc "The helper's posture for health and readiness: up, backing off, or failed."
  @spec status(GenServer.server()) :: status()
  def status(server), do: GenServer.call(server, :status)

  # --- GenServer ---------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)
    state = new_state(opts)

    case start_helper(state) do
      {:ok, state} ->
        {:ok, state}

      {:error, :helper_protocol_mismatch, _state} ->
        Logger.error(
          "iMessage helper refused: protocol_version is not #{Protocol.protocol_version()}"
        )

        {:stop, :helper_protocol_mismatch}

      {:error, class, state} ->
        {:ok, note_failure(state, class)}
    end
  end

  @impl GenServer
  def handle_call({:request, method, params, timeout}, from, %{status: :up} = state) do
    if map_size(state.pending) >= state.max_outstanding,
      do: {:reply, {:error, busy()}, state},
      else: dispatch(state, method, params, timeout, from)
  end

  def handle_call({:request, _method, _params, _timeout}, _from, state),
    do: {:reply, {:error, unavailable(state.class)}, state}

  def handle_call({:attach, pid}, _from, state) do
    state = attach_listener(state, pid)

    reply =
      if state.status == :up, do: {:ok, state.handshake}, else: {:error, unavailable(state.class)}

    {:reply, reply, state}
  end

  def handle_call(:home, _from, state), do: {:reply, {:ok, state.home}, state}

  def handle_call(:status, _from, state) do
    status = Map.take(state, [:status, :class, :failures])
    {:reply, Map.put(status, :outstanding, map_size(state.pending)), state}
  end

  @impl GenServer
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    {:noreply, receive_data(state, data)}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    {:noreply, note_failure(%{state | port: nil}, {:helper_exit, code})}
  end

  def handle_info({:request_timeout, id}, state), do: {:noreply, expire_request(state, id)}

  def handle_info(:respawn, state) do
    case start_helper(state) do
      {:ok, state} -> {:noreply, note_recovered(state)}
      {:error, class, state} -> {:noreply, note_failure(state, class)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{listener_ref: ref} = state) do
    {:noreply, %{state | listener: nil, listener_ref: nil}}
  end

  # A port is linked to its owner, and this process traps exits; the exit
  # status (or our own close) already accounted for the helper.
  def handle_info({:EXIT, port, _reason}, state) when is_port(port), do: {:noreply, state}

  # Output of a helper this process already gave up on (closed after a protocol
  # violation or a handshake timeout) carries a stale port and is discarded.
  def handle_info({port, _message}, state) when is_port(port), do: {:noreply, state}

  def handle_info(message, state) do
    Logger.warning("iMessage helper port ignored an unexpected message: #{inspect(message)}")
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, %{port: nil}), do: :ok

  def terminate(_reason, %{port: port} = state) do
    {:ok, line} = Protocol.encode_request(state.next_id, "shutdown", %{})

    case command(port, line) do
      :ok -> await_exit(port, @shutdown_wait_ms)
      {:error, :closed} -> :ok
    end

    close(port)
  end

  # --- Spawn and handshake -----------------------------------------------------

  defp new_state(opts) do
    %{
      executable: Keyword.fetch!(opts, :executable),
      home: Keyword.fetch!(opts, :home),
      backoff_initial_ms: Keyword.get(opts, :backoff_initial_ms, @backoff_initial_ms),
      backoff_max_ms: Keyword.get(opts, :backoff_max_ms, @backoff_max_ms),
      init_timeout_ms: Keyword.get(opts, :init_timeout_ms, @init_timeout_ms),
      max_outstanding: Keyword.get(opts, :max_outstanding, @max_outstanding),
      port: nil,
      status: :backoff,
      class: nil,
      failures: 0,
      handshake: nil,
      next_id: 1,
      pending: %{},
      partial: [],
      partial_bytes: 0,
      listener: nil,
      listener_ref: nil,
      buffered: []
    }
  end

  defp start_helper(state) do
    state = %{state | partial: [], partial_bytes: 0}

    case open_port(state) do
      {:ok, port} -> handshake(%{state | port: port})
      {:error, class} -> {:error, class, state}
    end
  end

  defp open_port(%{executable: executable, home: home}) do
    if File.regular?(executable) do
      options = [
        :binary,
        :exit_status,
        {:line, @line_chunk_bytes},
        args: ["serve", "--home", home]
      ]

      {:ok, Port.open({:spawn_executable, executable}, options)}
    else
      {:error, :helper_missing}
    end
  rescue
    error in ErlangError -> {:error, {:helper_spawn_failed, error.original}}
  end

  defp handshake(state) do
    id = state.next_id
    params = Protocol.initialize_params(client_version())
    {:ok, line} = Protocol.encode_request(id, "initialize", params)
    deadline = System.monotonic_time(:millisecond) + state.init_timeout_ms
    state = %{state | next_id: id + 1}

    # The write fails only when the helper already exited. Its exit status, the
    # real reason, is then the next message from the port, so both outcomes
    # wait for the answer.
    case command(state.port, line) do
      written when written in [:ok, {:error, :closed}] -> await_handshake(state, id, deadline)
    end
  end

  # Bounded by the deadline: every line read re-enters with less time left.
  defp await_handshake(%{port: port} = state, id, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} -> handshake_data(state, id, deadline, take_line(state, data))
      {^port, {:exit_status, code}} -> {:error, {:helper_exit, code}, %{state | port: nil}}
    after
      remaining -> {:error, :helper_timeout, close_helper(state)}
    end
  end

  defp handshake_data(_state, id, deadline, {:partial, state}),
    do: await_handshake(state, id, deadline)

  defp handshake_data(_state, _id, _deadline, {:overlong, state}),
    do: {:error, :protocol_error, close_helper(state)}

  defp handshake_data(_state, id, deadline, {:line, line, state}),
    do: handshake_frame(state, id, deadline, Protocol.decode(line))

  defp handshake_frame(state, id, _deadline, {:ok, {:response, id, {:ok, result}}}),
    do: check_version(state, result)

  defp handshake_frame(state, id, _deadline, {:ok, {:response, id, {:error, error}}}) do
    {kind, message, _data} = error
    Logger.error("iMessage helper refused initialize (#{kind}): #{message}")

    class =
      if kind == :protocol_mismatch,
        do: :helper_protocol_mismatch,
        else: :helper_initialize_failed

    {:error, class, close_helper(state)}
  end

  defp handshake_frame(state, id, deadline, {:ok, {:notification, event, params}}),
    do:
      await_handshake(buffer_notification(state, {:imessage_event, event, params}), id, deadline)

  defp handshake_frame(state, _id, _deadline, other) do
    Logger.error("iMessage helper answered initialize outside the protocol: #{inspect(other)}")
    {:error, :protocol_error, close_helper(state)}
  end

  defp check_version(state, %{"protocol_version" => version} = result) do
    if version == Protocol.protocol_version() do
      {:ok, %{state | status: :up, class: nil, handshake: result}}
    else
      Logger.error(
        "iMessage helper speaks protocol #{inspect(version)}; this engine speaks " <>
          "#{Protocol.protocol_version()} (helper #{inspect(result["helper_version"])})"
      )

      {:error, :helper_protocol_mismatch, close_helper(state)}
    end
  end

  defp check_version(state, _result), do: {:error, :protocol_error, close_helper(state)}

  defp client_version do
    case Application.spec(:fermix_channels, :vsn) do
      nil -> "unknown"
      vsn -> List.to_string(vsn)
    end
  end

  # --- Requests ----------------------------------------------------------------

  defp dispatch(state, method, params, timeout, from) do
    id = state.next_id

    with {:ok, line} <- Protocol.encode_request(id, method, params),
         :ok <- command(state.port, line) do
      timer = Process.send_after(self(), {:request_timeout, id}, timeout)
      pending = Map.put(state.pending, id, {from, timer, method, timeout})
      {:noreply, %{state | next_id: id + 1, pending: pending}}
    else
      {:error, {:unknown_method, method}} ->
        {:reply, {:error, {:protocol_error, "unknown helper method", %{"method" => method}}},
         state}

      {:error, :closed} ->
        {:reply, {:error, unavailable(:helper_exited)}, state}
    end
  end

  defp expire_request(state, id) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        state

      {{from, _timer, method, timeout}, pending} ->
        GenServer.reply(from, {:error, timed_out(method, timeout)})
        %{state | pending: pending}
    end
  end

  defp receive_data(state, data) do
    case take_line(state, data) do
      {:line, line, state} -> handle_frame(state, Protocol.decode(line))
      {:partial, state} -> state
      {:overlong, state} -> protocol_violation(state, :overlong_line)
    end
  end

  defp take_line(state, {:noeol, chunk}) do
    bytes = state.partial_bytes + byte_size(chunk)

    if bytes > @max_line_bytes,
      do: {:overlong, state},
      else: {:partial, %{state | partial: [state.partial, chunk], partial_bytes: bytes}}
  end

  defp take_line(state, {:eol, chunk}) do
    line = IO.iodata_to_binary([state.partial, chunk])
    state = %{state | partial: [], partial_bytes: 0}
    if byte_size(line) > @max_line_bytes, do: {:overlong, state}, else: {:line, line, state}
  end

  defp handle_frame(state, {:ok, {:response, id, result}}), do: reply_pending(state, id, result)

  defp handle_frame(state, {:ok, {:notification, event, params}}),
    do: deliver(state, {:imessage_event, event, params})

  defp handle_frame(state, {:error, {:unknown_error_kind, id, kind}}) do
    Logger.error(
      "iMessage helper answered request #{id} with an unknown error kind #{inspect(kind)}"
    )

    error = {:protocol_error, "helper returned an unknown error kind", %{"kind" => kind}}
    reply_pending(state, id, {:error, error})
  end

  defp handle_frame(state, {:error, {:unknown_event, event}}) do
    Logger.error("iMessage helper sent an unknown notification #{inspect(event)}; dropped")
    state
  end

  defp handle_frame(state, {:error, reason}), do: protocol_violation(state, reason)

  defp reply_pending(state, id, result) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        Logger.warning("iMessage helper answered request #{id} after it timed out; dropped")
        state

      {{from, timer, _method, _timeout}, pending} ->
        Process.cancel_timer(timer)
        GenServer.reply(from, result)
        %{state | pending: pending}
    end
  end

  # A line outside the wire contract means the two sides no longer agree on
  # framing; the only safe recovery is a fresh helper and a fresh handshake.
  defp protocol_violation(state, reason) do
    Logger.error("iMessage helper broke the wire protocol (#{inspect(reason)}); restarting it")
    state |> close_helper() |> note_failure(:protocol_error)
  end

  # --- Listener delivery --------------------------------------------------------

  defp attach_listener(state, pid) do
    if state.listener_ref, do: Process.demonitor(state.listener_ref, [:flush])
    state = %{state | listener: pid, listener_ref: Process.monitor(pid)}

    state.buffered
    |> Enum.reverse()
    |> Enum.each(&send(pid, &1))

    %{state | buffered: []}
  end

  defp deliver(%{listener: nil} = state, message), do: buffer_notification(state, message)

  defp deliver(%{listener: pid} = state, message) do
    send(pid, message)
    state
  end

  # Held until the Listener attaches (a `send.reconciled` from the helper's
  # startup arrives before it does). Bounded: past the cap the oldest is
  # dropped, loudly.
  defp buffer_notification(%{buffered: buffered} = state, message) do
    if length(buffered) >= @max_buffered_notifications do
      Logger.error("iMessage notification buffer full; dropping the oldest notification")
      %{state | buffered: [message | Enum.drop(buffered, -1)]}
    else
      %{state | buffered: [message | buffered]}
    end
  end

  defp notify_listener(%{listener: nil} = state, _message), do: state

  defp notify_listener(%{listener: pid} = state, message) do
    send(pid, message)
    state
  end

  # --- Failure, backoff, recovery ---------------------------------------------

  defp note_failure(state, class) do
    failures = state.failures + 1
    log_failure(state, class, failures)

    state =
      %{state | status: status_after(class), class: class, failures: failures, handshake: nil}
      |> fail_pending(class)
      |> notify_listener({:imessage_helper, :down, class})

    if failures == 1, do: emit_degraded(class)
    schedule_respawn(state)
  end

  defp note_recovered(state) do
    Logger.warning("iMessage helper recovered after #{state.failures} consecutive failures")
    ChannelTelemetry.emit_transport(:imessage, :recovered, state.failures, :none)
    notify_listener(%{state | failures: 0}, {:imessage_helper, :up, state.handshake})
  end

  # One line per state change: the first failure, and any change of class.
  defp log_failure(state, class, failures) do
    if failures == 1 or class != state.class do
      Logger.error("iMessage helper unavailable: #{describe(class)}#{retry_note(class)}")
    end
  end

  defp retry_note(class) do
    if retryable?(class), do: "; restarting with backoff", else: "; not retried"
  end

  defp emit_degraded(class),
    do: ChannelTelemetry.emit_transport(:imessage, :degraded, 1, class_atom(class))

  defp fail_pending(state, class) do
    Enum.each(state.pending, fn {_id, {from, timer, _method, _timeout}} ->
      Process.cancel_timer(timer)
      GenServer.reply(from, {:error, unavailable(class)})
    end)

    %{state | pending: %{}}
  end

  defp schedule_respawn(%{status: :backoff} = state) do
    Process.send_after(self(), :respawn, backoff_ms(state))
    state
  end

  defp schedule_respawn(state), do: state

  defp backoff_ms(%{failures: failures} = state) do
    doubled = state.backoff_initial_ms * Integer.pow(2, min(failures - 1, 16))
    min(doubled, state.backoff_max_ms)
  end

  defp status_after(class), do: if(retryable?(class), do: :backoff, else: :failed)

  defp retryable?({:helper_exit, code}), do: code not in @never_retried_exits
  defp retryable?(:helper_protocol_mismatch), do: false
  defp retryable?(_class), do: true

  defp class_atom({:helper_exit, _code}), do: :helper_exit
  defp class_atom({:helper_spawn_failed, _reason}), do: :helper_spawn_failed
  defp class_atom(class) when is_atom(class), do: class

  defp describe({:helper_exit, code}),
    do: "helper_exit #{code} (#{Map.get(@exit_meanings, code, "abnormal exit")})"

  defp describe({:helper_spawn_failed, reason}), do: "helper_spawn_failed (#{inspect(reason)})"
  defp describe(class) when is_atom(class), do: Atom.to_string(class)

  defp class_word({:helper_exit, code}), do: "helper_exit #{code}"
  defp class_word({:helper_spawn_failed, _reason}), do: "helper_spawn_failed"
  defp class_word(nil), do: "helper_not_started"
  defp class_word(class) when is_atom(class), do: Atom.to_string(class)

  # --- Small effects ----------------------------------------------------------

  defp command(port, line) do
    Port.command(port, line)
    :ok
  rescue
    ArgumentError -> {:error, :closed}
  end

  defp close_helper(%{port: nil} = state), do: state

  defp close_helper(%{port: port} = state) do
    close(port)
    %{state | port: nil, partial: [], partial_bytes: 0}
  end

  defp close(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp await_exit(port, wait_ms) do
    receive do
      {^port, {:exit_status, _code}} -> :ok
      {^port, {:data, _discarded}} -> await_exit(port, wait_ms)
    after
      wait_ms -> :ok
    end
  end

  defp busy, do: {:busy, "more than #{@max_outstanding} requests outstanding", %{}}

  defp unavailable(class) do
    word = class_word(class)
    {:helper_unavailable, "the iMessage helper is not running (#{word})", %{"class" => word}}
  end

  defp not_running,
    do: {:helper_unavailable, "the iMessage channel is not running", %{}}

  defp timed_out(method, timeout),
    do:
      {:request_timeout, "the iMessage helper did not answer #{method} within #{timeout} ms",
       %{"method" => method}}
end
