defmodule FermixChannels.Mobile.Iroh.Helper do
  @moduledoc """
  The rail's helper: the GenServer that owns the `fermix-iroh` port (M62 §3).

  It starts the helper, holds it to `Iroh.HelperProtocol` (hello, start, ready),
  checks what the helper says about itself against what this build knows (the
  protocol version, the relays' iroh version, the endpoint id of the home's
  key), and keeps what the rail reports: the home relay, each connected peer's
  path, the refusals by reason.

  ## States

  - `dormant`: no gateway identity yet. The pair manager activates the rail at
    the first pairing window, as it activates the listener.
  - `helper_missing`: this build carries no helper (a source checkout, or any
    release before the helper is bundled). Reported, not retried; nothing takes
    its place.
  - `starting`, `ready`.
  - `failed`: the helper crashed, timed out, reported an error, or disagreed
    with this build. It never stops this process: a helper that keeps failing
    must not restart its way up the supervisors and halt the daemon. A crash or
    an error is retried after 1 s, doubling to 60 s, until a day after the rail
    last ran; a disagreement (protocol version, iroh version, endpoint id) or a
    refused key is not retried until the rail restarts.

  The relays the helper uses are the ones every paired phone has acknowledged
  (`Iroh.Relays.acknowledged/2`); a phone that acknowledges a new revision, or
  a revoked phone, makes the rail recompute them and tell the helper.
  """

  use GenServer

  require Logger

  alias FermixChannels.Mobile.DeviceStore
  alias FermixChannels.Mobile.Iroh.Bridge
  alias FermixChannels.Mobile.Iroh.HelperProtocol
  alias FermixChannels.Mobile.Iroh.Key
  alias FermixChannels.Mobile.Iroh.Relays
  alias FermixCore.ProcessGroup

  @hello_timeout_ms 10_000
  @ready_timeout_ms 30_000
  @shutdown_grace_ms 5_000
  @first_retry_ms 1_000
  @max_retry_ms 60_000
  @retry_window_ms 24 * 3_600_000
  # A helper that stayed ready this long ran, and its next failure starts the
  # backoff afresh; one that died sooner goes on with the backoff it had.
  @stable_ms 60_000
  # `max_connections` is the rail's outer bound, and the contract's most: a
  # connection past it is refused before its handshake, so a stranger holding
  # every one shuts a phone out before the bridge can make room for it. The
  # helper closes a connection with no stream for 30 s, and the bridge a silent
  # stream at its 10 s handshake deadline, so holding one takes a stream or a
  # handshake every 40 s: about 26 a second for all 1,024, where 64 took under
  # two. The helper cannot yet close a silent connection to make room for a new
  # one; until it does (a fermix-iroh change and a pin bump), this raises the
  # cost of shutting phones out and does not end it. Each connection costs the
  # helper its QUIC state; unread bytes wait only on streams the bridge has not
  # taken, which its 64-place backlog bounds.
  @limits %{
    max_connections: 1_024,
    max_streams_per_connection: 4,
    stream_receive_window: 262_144,
    connection_receive_window: 1_048_576,
    send_window: 1_048_576
  }
  @shim_missing_message "macOS disclaim shim is not built — rebuild fermix (mix compile) or reinstall"

  @typedoc "What the rail reports."
  @type status :: %{
          required(:state) => :dormant | :helper_missing | :starting | :ready | :failed,
          optional(:endpoint_id) => String.t(),
          optional(:relay) => String.t() | nil,
          optional(:connected) => boolean(),
          optional(:relay_error) => String.t() | nil,
          optional(:failure) => String.t(),
          optional(:helper_path) => Path.t(),
          required(:refused) => %{
            busy: non_neg_integer(),
            alpn: non_neg_integer(),
            bridge_unreachable: non_neg_integer()
          }
        }

  @doc "Where a release carries the helper."
  @spec default_binary_path() :: Path.t()
  def default_binary_path,
    do: Application.app_dir(:fermix_core, "priv/iroh_helper/bin/fermix-iroh")

  @doc "The limits `start` sends the helper."
  @spec limits() :: HelperProtocol.limits()
  def limits, do: @limits

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Starts a dormant rail, at the first pairing window. Never fails the window:
  an absent rail (switched off) or one already running answers `:ok`.
  """
  @spec activate(GenServer.server()) :: :ok
  def activate(server) do
    if alive?(server), do: GenServer.cast(server, :activate)
    :ok
  end

  @doc """
  The `iroh` candidate for `hello_ack` and `pair_approved`, or `:none` when the
  rail is not ready, switched off or absent. Never exits.
  """
  @spec candidate(GenServer.server()) :: {:ok, map()} | :none
  def candidate(server), do: safe_call(server, :candidate, :none)

  @doc "The rail's status; `%{state: :off}` when it is switched off or absent."
  @spec status(GenServer.server()) :: status() | %{state: :off}
  def status(server), do: safe_call(server, :status, %{state: :off})

  @doc """
  A session from this iroh peer failed before `hello` or a pair request: the
  helper closes the peer's connections. A rail that is not ready, switched off
  or absent holds no connection, so there is nothing to close. The op is built
  here, so an id that is not one fails the caller, never the rail.
  """
  @spec close(GenServer.server(), String.t()) :: :ok
  def close(server, endpoint_id) when is_binary(endpoint_id) do
    op = HelperProtocol.close(endpoint_id)
    if alive?(server), do: GenServer.cast(server, {:close, op})
    :ok
  end

  @doc "A phone acknowledged a relay list, or one was revoked: recompute the relays."
  @spec relays_acknowledged(GenServer.server()) :: :ok
  def relays_acknowledged(server) do
    if alive?(server), do: GenServer.cast(server, :recompute)
    :ok
  end

  defp alive?(server) when is_pid(server), do: Process.alive?(server)
  defp alive?(server), do: not is_nil(GenServer.whereis(server))

  # The rail can be switched off, and so stop, between the check and the call,
  # or be stopping its helper; a phone's hello must not inherit either, so the
  # reads are bounded and answer as if the rail were absent.
  @read_timeout_ms 2_000

  defp safe_call(server, message, absent) do
    if alive?(server), do: GenServer.call(server, message, @read_timeout_ms), else: absent
  catch
    :exit, {reason, _call} when reason in [:noproc, :normal, :shutdown, :timeout] -> absent
    :exit, {{:shutdown, _detail}, _call} -> absent
  end

  @doc """
  The spawn target and argv: on macOS through the `disclaim` exec shim, so the
  helper is its own TCC responsible process (engine AGENTS.md); a missing shim
  refuses, there is no undisclaimed spawn. A deliberate copy of
  `FermixCore.Meetings.Sidecar.Port.spawn_plan/4`, pinned by its own test.
  """
  @spec spawn_plan(Path.t(), {atom(), atom()}, Path.t() | nil) ::
          {:ok, {Path.t(), [String.t()]}} | {:error, {:disclaim_shim_missing, String.t()}}
  def spawn_plan(_binary_path, {:unix, :darwin}, nil),
    do: {:error, {:disclaim_shim_missing, @shim_missing_message}}

  def spawn_plan(binary_path, {:unix, :darwin}, shim) when is_binary(shim),
    do: {:ok, {shim, [binary_path]}}

  def spawn_plan(binary_path, _os_type, _shim), do: {:ok, {binary_path, []}}

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      root: Keyword.fetch!(opts, :root),
      bridge_socket: Keyword.fetch!(opts, :bridge_socket),
      device_store: Keyword.get(opts, :device_store, DeviceStore),
      binary_path: Keyword.get(opts, :binary_path, default_binary_path()),
      os_type: Keyword.get(opts, :os_type, :os.type()),
      shim_path: Keyword.get(opts, :shim_path, disclaim_shim_path()),
      revisions: Keyword.get(opts, :revisions, Relays.revisions()),
      identity_exists?: Keyword.get(opts, :identity_exists?, fn -> false end),
      list_devices: Keyword.get(opts, :list_devices, &DeviceStore.list/1),
      clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end),
      emit: Keyword.get(opts, :emit, fn _status, _failures, _class -> :ok end),
      bridge: Keyword.get(opts, :bridge),
      failures: 0,
      timeouts: %{
        hello: Keyword.get(opts, :hello_timeout_ms, @hello_timeout_ms),
        ready: Keyword.get(opts, :ready_timeout_ms, @ready_timeout_ms)
      },
      rail: :dormant,
      failure: nil,
      retryable?: true,
      retry: nil,
      ready_at: nil,
      port: nil,
      os_pid: nil,
      acc: "",
      stage: nil,
      timer: nil,
      key: nil,
      relays: [],
      home: %{relay: nil, connected: false, error: nil},
      paths: %{},
      refused: %{busy: 0, alpn: 0, bridge_unreachable: 0}
    }

    if state.identity_exists?.(), do: {:ok, state, {:continue, :start}}, else: {:ok, state}
  end

  @impl true
  def handle_continue(:start, state), do: {:noreply, start_helper(state)}

  @impl true
  def handle_cast(:activate, %{rail: :dormant} = state), do: {:noreply, start_helper(state)}
  def handle_cast(:activate, state), do: {:noreply, state}

  def handle_cast(:recompute, %{rail: :ready} = state), do: {:noreply, push_relays(state)}
  def handle_cast(:recompute, state), do: {:noreply, state}

  def handle_cast({:close, op}, %{rail: :ready} = state) do
    :ok = command(state, op)
    {:noreply, state}
  end

  def handle_cast({:close, _op}, state), do: {:noreply, state}

  @impl true
  def handle_call(:candidate, _from, %{rail: :ready} = state),
    do: {:reply, {:ok, candidate_for(state)}, state}

  def handle_call(:candidate, _from, state), do: {:reply, :none, state}
  def handle_call(:status, _from, state), do: {:reply, status_of(state), state}

  @impl true
  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state),
    do: {:noreply, buffer(state, chunk)}

  def handle_info({port, {:data, {:eol, chunk}}}, %{port: port} = state) do
    line = state.acc <> chunk
    state = %{state | acc: ""}

    case HelperProtocol.decode_event(line) do
      {:ok, event} -> {:noreply, handle_event(event, state)}
      {:error, reason} -> {:noreply, fail(state, {:protocol_error, reason}, true)}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    state = %{state | port: nil, os_pid: nil}
    {:noreply, fail(state, {:exited, status}, true)}
  end

  def handle_info({:stage_timeout, stage}, %{stage: stage} = state) when not is_nil(stage),
    do: {:noreply, fail(state, {:timeout, stage}, true)}

  def handle_info({:retry, token}, %{retry: %{token: token}} = state),
    do: {:noreply, start_helper(%{state | retry: %{state.retry | token: nil}})}

  # A port that closed with no exit status (a write to a helper that had
  # stopped reading fails with EPIPE) is a crash like any other. The process
  # group is killed in case the helper outlived its pipe. A port that exited
  # normally reported its status first and is no longer the current one.
  def handle_info({:EXIT, port, reason}, %{port: port} = state) when is_port(port) do
    _ = ProcessGroup.signal(state.os_pid, :sigkill)
    {:noreply, fail(%{state | port: nil, os_pid: nil}, {:port_closed, reason}, true)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    stop_port(state)
    :ok
  end

  # -- starting --------------------------------------------------------------

  defp start_helper(state) do
    with :ok <- helper_present(state),
         :ok <- bridge_listening(state),
         {:ok, key} <- ensure_key(state),
         {:ok, {executable, args}} <-
           spawn_plan(state.binary_path, state.os_type, state.shim_path),
         {:ok, port, os_pid} <- open_port(executable, args) do
      state
      |> Map.merge(%{
        rail: :starting,
        failure: nil,
        key: key,
        port: port,
        os_pid: os_pid,
        acc: ""
      })
      |> await(:hello, state.timeouts.hello)
    else
      {:missing, path} ->
        Logger.warning("fermix-iroh is not in this build (#{path}); remote reach is off")
        %{state | rail: :helper_missing}

      {:error, {:key, reason}} ->
        fail(state, {:key, reason}, false)

      {:error, :bridge_unavailable} ->
        fail(state, :bridge_unavailable, false)

      {:error, {:disclaim_shim_missing, _message} = reason} ->
        fail(state, reason, false)

      {:error, reason} ->
        fail(state, reason, true)
    end
  end

  defp helper_present(%{binary_path: path}) do
    if File.regular?(path), do: :ok, else: {:missing, path}
  end

  # The bridge returns `:ignore` when it cannot bind its socket; a helper
  # started then would have nowhere to bridge a phone to.
  defp bridge_listening(%{bridge: nil}), do: :ok

  defp bridge_listening(%{bridge: bridge}) do
    if Bridge.listening?(bridge),
      do: :ok,
      else: {:error, :bridge_unavailable}
  end

  defp ensure_key(state) do
    case Key.ensure(state.root) do
      {:ok, key} -> {:ok, key}
      {:error, reason} -> {:error, {:key, reason}}
    end
  end

  defp open_port(executable, args) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        {:line, HelperProtocol.max_line_bytes()},
        :use_stdio,
        :exit_status,
        :hide,
        {:args, args},
        {:env, unset_environment()}
      ])

    {:ok, port, os_pid(port)}
  rescue
    # A file that is present but cannot be run: Port.open raises the spawn's
    # errno (`eacces`, `enoexec`), or ArgumentError for a path it rejects.
    error in [ErlangError, ArgumentError] ->
      Logger.warning("fermix-iroh could not be started: #{Exception.message(error)}")
      {:error, {:spawn_failed, executable}}
  end

  # A helper that exited at once (seen under load) has closed its port before
  # its pid is read, and Port.info/2 answers nil. It did start: what it printed
  # and its exit status are still in the mailbox and fail the rail there.
  defp os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> os_pid
      nil -> nil
    end
  end

  defp buffer(state, chunk) do
    acc = state.acc <> chunk

    if byte_size(acc) > HelperProtocol.max_line_bytes(),
      do: fail(%{state | acc: ""}, {:protocol_error, :line_too_long}, true),
      else: %{state | acc: acc}
  end

  # The helper needs nothing from the daemon's environment, which may carry
  # secrets, so every inherited variable is unset for it.
  defp unset_environment do
    Enum.map(System.get_env(), fn {name, _value} -> {String.to_charlist(name), false} end)
  end

  # -- the helper's events ---------------------------------------------------

  defp handle_event(%{event: :hello} = hello, %{stage: :hello} = state) do
    current = List.last(state.revisions)

    cond do
      hello.protocol_version != HelperProtocol.protocol_version() ->
        fail(state, {:protocol_version, hello.protocol_version}, false)

      hello.iroh_version != current.iroh ->
        fail(state, {:iroh_version, hello.iroh_version, current.iroh}, false)

      true ->
        start_endpoint(state)
    end
  end

  defp handle_event(%{event: :ready, endpoint_id: id}, %{stage: :ready} = state) do
    if id == state.key.endpoint_id do
      Logger.info("fermix-iroh ready as #{id}")
      if state.failures > 0, do: :ok = state.emit.(:recovered, 0, :none)

      %{
        cancel_stage(state)
        | rail: :ready,
          stage: :running,
          failures: 0,
          ready_at: state.clock.()
      }
    else
      fail(state, {:endpoint_id, id, state.key.endpoint_id}, false)
    end
  end

  defp handle_event(%{event: :relay} = relay, %{stage: :running} = state) do
    %{
      state
      | home: %{relay: relay.home_relay, connected: relay.connected, error: clean(relay.error)}
    }
  end

  defp handle_event(%{event: :path} = path, %{stage: :running} = state) do
    if map_size(state.paths) < @limits.max_connections or
         Map.has_key?(state.paths, path.endpoint_id),
       do: %{
         state
         | paths: Map.put(state.paths, path.endpoint_id, Map.take(path, [:kind, :relay]))
       },
       else: state
  end

  defp handle_event(%{event: :closed, endpoint_id: id}, %{stage: :running} = state),
    do: %{state | paths: Map.delete(state.paths, id)}

  defp handle_event(%{event: :refused, reason: reason}, %{stage: :running} = state) do
    count = Map.fetch!(state.refused, reason) + 1
    warn_refused(count, reason)
    %{state | refused: Map.put(state.refused, reason, count)}
  end

  defp handle_event(%{event: :log, level: level, message: message}, state) do
    Logger.log(if(level == :warn, do: :warning, else: :info), "fermix-iroh: #{clean(message)}")
    state
  end

  # A refused key or a refused `start` would be refused again: neither is retried.
  defp handle_event(%{event: :error, code: code, message: message}, state),
    do:
      fail(
        state,
        {:helper_error, code, clean(message)},
        code not in ["key_invalid", "bad_request"]
      )

  defp handle_event(%{event: event}, state),
    do: fail(state, {:protocol_error, {:unexpected_event, event, state.stage}}, true)

  defp start_endpoint(state) do
    case acknowledged(state) do
      {:ok, relays} ->
        start = HelperProtocol.start(state.key.path, state.bridge_socket, wire(relays), @limits)
        :ok = command(state, start)
        await(%{state | relays: relays}, :ready, state.timeouts.ready)

      {:error, reason} ->
        fail(state, {:device_store, reason}, true)
    end
  end

  # -- relays ----------------------------------------------------------------

  defp acknowledged(state) do
    case state.list_devices.(state.device_store) do
      {:ok, devices} ->
        {:ok, devices |> Enum.map(& &1.relay_list_rev) |> Relays.acknowledged(state.revisions)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A list that cannot be read now leaves the relays the helper already has,
  # the ones every phone acknowledged when they were last read.
  defp push_relays(state) do
    case acknowledged(state) do
      {:ok, same} when same == state.relays ->
        state

      {:ok, relays} ->
        :ok = command(state, HelperProtocol.set_relays(wire(relays)))
        %{state | relays: relays}

      {:error, reason} ->
        Logger.warning("remote reach kept its relays: #{describe({:device_store, reason})}")
        state
    end
  end

  defp wire(relays), do: Relays.to_wire(relays)

  defp candidate_for(state) do
    current = List.last(state.revisions)

    %{
      "kind" => "iroh",
      "node_id" => state.key.endpoint_id,
      "relays" => wire(current.relays),
      "relays_rev" => current.id
    }
  end

  # -- failing and retrying ----------------------------------------------------

  defp fail(state, reason, retryable?) do
    state = state |> cancel_stage() |> stop_port()
    words = describe(reason)
    Logger.warning("fermix-iroh failed: #{words}")
    failures = state.failures + 1
    # Telemetry on the transition into failure only, as every channel transport.
    if failures == 1, do: :ok = state.emit.(:degraded, failures, class(reason))

    state = %{
      forget_backoff_if_stable(state)
      | rail: :failed,
        failure: words,
        retryable?: retryable?,
        stage: nil,
        failures: failures,
        ready_at: nil
    }

    if retryable?, do: schedule_retry(state), else: %{state | retry: nil}
  end

  defp forget_backoff_if_stable(%{ready_at: ready_at} = state) when is_integer(ready_at) do
    if state.clock.() - ready_at >= @stable_ms, do: %{state | retry: nil}, else: state
  end

  defp forget_backoff_if_stable(state), do: state

  defp schedule_retry(state) do
    now = state.clock.()
    retry = state.retry || %{deadline_ms: now + @retry_window_ms, delay_ms: @first_retry_ms}

    if now >= retry.deadline_ms do
      Logger.warning("fermix-iroh gave up a day after it last ran; remote reach stays off")
      %{state | retry: nil, retryable?: false}
    else
      token = make_ref()
      Process.send_after(self(), {:retry, token}, retry.delay_ms)
      delay = min(retry.delay_ms * 2, @max_retry_ms)
      %{state | retry: %{retry | delay_ms: delay} |> Map.put(:token, token)}
    end
  end

  defp class({kind, _detail}) when is_atom(kind), do: kind
  defp class({kind, _a, _b}) when is_atom(kind), do: kind
  defp class(reason) when is_atom(reason), do: reason
  defp class(_reason), do: :helper_failed

  defp describe(:bridge_unavailable), do: "the bridge socket is not listening"
  defp describe({:exited, status}), do: "the helper exited with status #{status}"
  defp describe({:timeout, stage}), do: "the helper did not answer #{stage} in time"
  defp describe({:helper_error, code, message}), do: "#{code}: #{message}"
  defp describe({:protocol_version, version}), do: "the helper speaks protocol #{version}"

  defp describe({:iroh_version, theirs, ours}),
    do: "the helper runs iroh #{theirs}, the relays run #{ours}"

  defp describe({:endpoint_id, theirs, ours}),
    do: "the helper reported endpoint #{theirs}, the key's is #{ours}"

  defp describe({:key, reason}), do: key_words(reason)
  defp describe({:protocol_error, reason}), do: "the helper sent #{line_words(reason)}"
  defp describe({:spawn_failed, path}), do: "the helper at #{path} could not be started"

  defp describe({:port_closed, reason}) when is_atom(reason),
    do: "the helper's pipe closed: #{:file.format_error(reason)}"

  defp describe({:device_store, reason}) when is_atom(reason),
    do: "the paired phones could not be read: #{:file.format_error(reason)}"

  defp describe({:device_store, reason}),
    do: "the paired phones could not be read (#{inspect(reason)})"

  defp describe({:disclaim_shim_missing, message}), do: message

  defp key_words({:iroh_key_invalid, path, {:mode, mode}}),
    do: "the iroh key #{path} is mode #{octal(mode)}; it must be 0600"

  defp key_words({:iroh_key_invalid, path, {:size, size}}),
    do: "the iroh key #{path} holds #{size} bytes, not 32"

  defp key_words({:iroh_key_dir_unusable, dir, {:mode, mode}}),
    do: "#{dir} is mode #{octal(mode)}; it must be 0700"

  defp key_words({:iroh_key_unsafe_type, path, type}),
    do: "the iroh key #{path} is a #{type}, not a file"

  defp key_words({kind, path, reason})
       when kind in [:iroh_key_unreadable, :iroh_key_dir_unusable],
       do: "#{path} cannot be read: #{:file.format_error(reason)}"

  defp key_words({:iroh_key_write_failed, path, reason, _cleanup}),
    do: "the iroh key #{path} cannot be written: #{:file.format_error(reason)}"

  defp key_words({:stale_temp_unremovable, path, reason}),
    do: "#{path} cannot be removed: #{:file.format_error(reason)}"

  defp key_words({:too_many_stale_temps, count}),
    do: "#{count} unfinished iroh key files are in the way; remove them"

  defp line_words(:line_too_long), do: "a line over 64 KiB"
  defp line_words(:malformed_json), do: "a line that is not JSON"
  defp line_words(:not_an_event), do: "a line that is not an event"
  defp line_words({:invalid_event, name}), do: "an invalid #{name} event"
  defp line_words(:invalid_endpoint_id), do: "an invalid endpoint id"
  defp line_words(:invalid_path), do: "an invalid path event"
  defp line_words(:text_too_long), do: "a text longer than its bound"
  defp line_words({:unexpected_event, event, stage}), do: "#{event} while #{stage}"

  defp octal(mode),
    do: mode |> Bitwise.band(0o777) |> Integer.to_string(8) |> String.pad_leading(4, "0")

  # Helper and relay text is the helper's or a relay's, never the daemon's:
  # control characters go before it reaches a log line or a settings row.
  defp clean(nil), do: nil
  defp clean(text), do: String.replace(text, ~r/[\x00-\x1F\x7F-\x9F]/u, " ")

  defp status_of(state) do
    base = %{state: state.rail, refused: state.refused}

    case state.rail do
      :ready ->
        Map.merge(base, %{
          endpoint_id: state.key.endpoint_id,
          relay: state.home.relay,
          connected: state.home.connected,
          relay_error: state.home.error
        })

      :failed ->
        Map.put(base, :failure, state.failure)

      :helper_missing ->
        Map.put(base, :helper_path, state.binary_path)

      _other ->
        base
    end
  end

  # Said at 1, 10, 100… of each reason, so a flood costs a few log lines.
  defp warn_refused(count, reason) do
    if power_of_ten?(count) do
      noun = if count == 1, do: "connection", else: "connections"
      Logger.warning("fermix-iroh turned away #{count} remote #{noun} (#{reason})")
    end

    :ok
  end

  defp power_of_ten?(1), do: true
  defp power_of_ten?(count) when rem(count, 10) == 0, do: power_of_ten?(div(count, 10))
  defp power_of_ten?(_count), do: false

  # -- the port ----------------------------------------------------------------

  defp await(state, stage, timeout_ms) do
    state = cancel_stage(state)

    %{
      state
      | stage: stage,
        timer: Process.send_after(self(), {:stage_timeout, stage}, timeout_ms)
    }
  end

  defp cancel_stage(%{timer: nil} = state), do: state

  defp cancel_stage(state) do
    _ = Process.cancel_timer(state.timer)
    %{state | timer: nil}
  end

  defp command(%{port: port}, op) do
    Port.command(port, HelperProtocol.encode(op))
    :ok
  rescue
    # The helper exited a moment ago: its exit status is already on its way
    # and fails the rail there.
    ArgumentError -> :ok
  end

  # A shutdown op first, then the process group if the helper is still there
  # after the grace: Port.close alone would only close the pipe.
  defp stop_port(%{port: nil} = state), do: state

  defp stop_port(%{port: port, os_pid: os_pid} = state) do
    if Port.info(port) do
      :ok = command(state, HelperProtocol.shutdown())

      unless await_exit(port, @shutdown_grace_ms) do
        close(port)
        ProcessGroup.signal(os_pid, :sigkill)
      end
    end

    flush(port)
    %{state | port: nil, os_pid: nil}
  end

  # A port whose helper exited closes itself; closing it again raises.
  defp close(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp await_exit(port, grace_ms) do
    receive do
      {^port, {:exit_status, _status}} -> true
    after
      grace_ms -> false
    end
  end

  defp flush(port) do
    receive do
      {^port, _message} -> flush(port)
    after
      0 -> :ok
    end
  end

  defp disclaim_shim_path do
    path = Application.app_dir(:fermix_nif, "priv/disclaim")
    if File.regular?(path), do: path, else: nil
  end
end
