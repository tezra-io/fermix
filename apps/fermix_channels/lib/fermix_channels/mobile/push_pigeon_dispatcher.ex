defmodule FermixChannels.Mobile.Push.PigeonDispatcher do
  @moduledoc """
  Owns the one Pigeon APNs dispatcher, connected lazily.

  Pigeon's APNs adapter connects inside its own `init` and stops when it cannot,
  so nothing connects at boot: an offline host must not keep the mobile subtree,
  and with it the channels application, from starting. The first batch
  connects, a failed connect is retried once per batch, and a connection Pigeon
  loses at runtime is dropped and reconnected by the next batch.

  The connection lives in a process of its own, which connects and then sends
  the batches one at a time, so this server never waits on the network:
  `status/1` answers while a connect hangs on a network that drops packets,
  and says push is degraded because it is connecting.

  A connect cannot be cut short. Pigeon's worker connects through Kadabra,
  which runs the TLS connect inside a start on its application-wide
  supervisor, with no timeout and one start at a time; neither library takes
  a connect timeout. Killing the Pigeon start would leave that connect
  running and queue the next one behind it. So the connect deadline answers
  the batches waiting on it, and the connect runs on to its own end: until
  then no other starts, and every batch is refused as connecting.
  """

  use GenServer

  @behaviour FermixChannels.Mobile.Push.Dispatcher

  require Logger

  alias FermixChannels.Mobile.Push.Config
  alias FermixCore.Net.Egress
  alias Pigeon.APNS.Notification

  @max_notifications 64
  @shutdown_timeout_ms 5_000
  @call_slack_ms 1_000
  # Each attempt is Pigeon's own three connects, one after another. A second
  # attempt starts only after the first failed within its deadline, with
  # batches still waiting; past the cap they fail and push reads degraded
  # until a later batch connects.
  @max_connect_attempts 2
  @connect_timeout_ms 10_000
  # A lazy connect happens inside the dispatch call, so the call allows for it.
  @connect_budget_ms @max_connect_attempts * @connect_timeout_ms
  # Batches that arrive while a connect runs wait for it, this many at most.
  @max_waiting_batches 32

  @type health :: :ready | {:degraded, :connecting | :connect_failed | :connection_lost}

  @type dependency_opts :: [
          start_dispatcher: (Config.t() -> {:ok, term()} | {:error, term()}),
          push: (term(), [Notification.t()], pos_integer() ->
                   {:ok, [Notification.t()]} | {:error, term()}),
          stop_dispatcher: (term() -> :ok | {:error, term()}),
          schedule_deadline: (term(), pos_integer() -> reference())
        ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) when is_list(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      shutdown: @shutdown_timeout_ms + @call_slack_ms
    }
  end

  @doc "How long the batches waiting on one connect to Apple wait for it."
  @spec connect_timeout_ms() :: pos_integer()
  def connect_timeout_ms, do: @connect_timeout_ms

  @doc "Most batches that wait for a connect; one more is refused while it runs."
  @spec max_waiting_batches() :: pos_integer()
  def max_waiting_batches, do: @max_waiting_batches

  @impl FermixChannels.Mobile.Push.Dispatcher
  @spec dispatch([Notification.t()], Config.t()) ::
          {:ok, [Notification.t()]} | {:error, term()}
  def dispatch(notifications, %Config{} = config) do
    dispatch(__MODULE__, notifications, config)
  end

  @doc false
  @spec dispatch(GenServer.server(), [Notification.t()], Config.t()) ::
          {:ok, [Notification.t()]} | {:error, term()}
  def dispatch(server, notifications, %Config{enabled: true} = config)
      when is_list(notifications) and length(notifications) <= @max_notifications do
    timeout = length(notifications) * config.timeout_ms + @connect_budget_ms + @call_slack_ms
    call(server, {:dispatch, notifications, config_fingerprint(config)}, timeout)
  end

  def dispatch(_server, notifications, %Config{}) when is_list(notifications),
    do: {:error, {:invalid_dispatch_count, length(notifications), @max_notifications}}

  @doc """
  Whether push is delivering, or degraded and why: connecting while a connect
  runs, then ready or connect_failed. Ready until the first connect.
  """
  @spec status(GenServer.server()) :: health()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl true
  def init(opts) do
    case fetch_config(opts) do
      {:ok, config} ->
        Process.flag(:trap_exit, true)
        {:ok, initial_state(config, opts)}

      {:error, reason} ->
        {:stop, {:push_dispatcher_start_failed, reason}}
    end
  end

  defp initial_state(config, opts) do
    %{
      connection: nil,
      dispatcher: nil,
      connecting: nil,
      waiting: [],
      health: :ready,
      config: config,
      config_fingerprint: config_fingerprint(config),
      timeout_ms: config.timeout_ms,
      egress: Keyword.get_lazy(opts, :egress, &Egress.active/0),
      start_dispatcher: Keyword.get(opts, :start_dispatcher, &start_pigeon_dispatcher/1),
      push: Keyword.get(opts, :push, &push_all/3),
      stop_dispatcher: Keyword.get(opts, :stop_dispatcher, &stop_dispatcher/1),
      schedule_deadline:
        Keyword.get(opts, :schedule_deadline, &Process.send_after(self(), &1, &2))
    }
  end

  @impl true
  def handle_call({:dispatch, _notifications, fingerprint}, _from, state)
      when fingerprint != state.config_fingerprint do
    {:reply, {:error, :push_dispatcher_config_mismatch}, state}
  end

  # The connection answers the caller itself. A batch handed over in the
  # instant the connection dies with its exit still unread here is lost, and
  # its caller's own call timeout answers it.
  def handle_call(
        {:dispatch, notifications, _fingerprint},
        from,
        %{connection: connection} = state
      )
      when is_pid(connection) do
    send(connection, {:push, from, notifications})
    {:noreply, state}
  end

  def handle_call(
        {:dispatch, _notifications, _fingerprint},
        _from,
        %{connecting: %{overdue?: true}} = state
      ) do
    {:reply, {:error, {:push_unavailable, :connecting}}, state}
  end

  def handle_call({:dispatch, _notifications, _fingerprint}, _from, state)
      when length(state.waiting) >= @max_waiting_batches do
    {:reply, {:error, {:push_unavailable, :connecting}}, state}
  end

  def handle_call({:dispatch, notifications, _fingerprint}, from, state) do
    state = %{state | waiting: [{from, notifications} | state.waiting]}
    {:noreply, ensure_connecting(state)}
  end

  def handle_call(:status, _from, state), do: {:reply, state.health, state}

  @impl true
  def handle_info({:apns_connected, pid, result}, %{connecting: %{pid: pid}} = state) do
    {:noreply, connect_result(result, state)}
  end

  # The batches waiting on a connect past its deadline are answered; the
  # connect runs on, and while it does no other starts.
  def handle_info({:connect_deadline, pid}, %{connecting: %{pid: pid, overdue?: false}} = state) do
    Logger.warning(
      "mobile APNs connect has not finished in #{@connect_timeout_ms} ms; " <>
        "push is refused until it ends"
    )

    refuse_waiting(state.waiting, {:push_unavailable, :connecting})
    {:noreply, %{state | connecting: %{state.connecting | overdue?: true}, waiting: []}}
  end

  # The deadline of a connect that already ended.
  def handle_info({:connect_deadline, _pid}, state), do: {:noreply, state}

  # A connection process that died before it could report failed its attempt.
  def handle_info({:EXIT, pid, reason}, %{connecting: %{pid: pid}} = state) do
    {:noreply, connect_result({:error, {:connect_exited, reason}}, state)}
  end

  def handle_info({:EXIT, connection, reason}, %{connection: connection} = state) do
    Logger.warning("mobile APNs connection lost (#{inspect(reason)}); the next push reconnects")

    {:noreply, %{state | connection: nil, dispatcher: nil, health: {:degraded, :connection_lost}}}
  end

  # A connection process that reported a failed connect exits after it.
  def handle_info({:EXIT, _other, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{dispatcher: nil}), do: :ok

  def terminate(_reason, state) do
    case call_dependency(:stop_dispatcher, state.stop_dispatcher, [state.dispatcher]) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("mobile APNs dispatcher shutdown failed: #{inspect(reason)}")
    end
  end

  defp ensure_connecting(%{connecting: nil} = state),
    do: start_connection(state, @max_connect_attempts)

  defp ensure_connecting(state), do: state

  defp start_connection(state, attempts_left) do
    connection = %{
      owner: self(),
      egress: state.egress,
      start_dispatcher: state.start_dispatcher,
      config: state.config,
      push: state.push,
      timeout_ms: state.timeout_ms
    }

    pid = spawn_link(fn -> run_connection(connection) end)
    _timer = state.schedule_deadline.({:connect_deadline, pid}, @connect_timeout_ms)
    connecting = %{pid: pid, attempts_left: attempts_left, overdue?: false}
    %{state | connecting: connecting, health: {:degraded, :connecting}}
  end

  defp connect_result({:ok, dispatcher}, %{connecting: %{pid: connection}} = state) do
    state.waiting
    |> Enum.reverse()
    |> Enum.each(fn {from, notifications} -> send(connection, {:push, from, notifications}) end)

    %{
      state
      | connection: connection,
        dispatcher: dispatcher,
        connecting: nil,
        waiting: [],
        health: :ready
    }
  end

  defp connect_result({:error, reason}, %{connecting: %{attempts_left: left}} = state) do
    Logger.warning("mobile APNs connection failed (#{inspect(reason)})")

    if left > 1 and state.waiting != [] do
      start_connection(state, left - 1)
    else
      refuse_waiting(state.waiting, {:push_unavailable, :connect_failed})
      %{state | connecting: nil, waiting: [], health: {:degraded, :connect_failed}}
    end
  end

  defp refuse_waiting(waiting, reason) do
    Enum.each(waiting, fn {from, _notifications} -> GenServer.reply(from, {:error, reason}) end)
  end

  # The connection process: it connects, and then owns the Pigeon dispatcher
  # (its parent) and sends the batches one at a time until the dispatcher or
  # this server exits. It traps exits so a failed Pigeon start is an answer,
  # not its own death.
  defp run_connection(connection) do
    Process.flag(:trap_exit, true)

    case start_dispatcher(connection) do
      {:ok, dispatcher} ->
        send(connection.owner, {:apns_connected, self(), {:ok, dispatcher}})
        serve(Map.put(connection, :dispatcher, dispatcher))

      {:error, reason} ->
        send(connection.owner, {:apns_connected, self(), {:error, reason}})

      other ->
        reason = {:invalid_push_dependency_reply, :start_dispatcher, other}
        send(connection.owner, {:apns_connected, self(), {:error, reason}})
    end
  end

  # APNs rides Pigeon's own HTTP/2 socket, which cannot tunnel. Behind a proxy
  # the connect is refused, so push degrades and says so, rather than leaving
  # around the proxy.
  defp start_dispatcher(connection) do
    with :ok <- Egress.ensure_direct(apns_origin(connection.config), connection.egress) do
      call_dependency(:start_dispatcher, connection.start_dispatcher, [connection.config])
    end
  end

  defp apns_origin(config) do
    case Config.pigeon_mode(config) do
      :prod -> "https://api.push.apple.com"
      :dev -> "https://api.development.push.apple.com"
    end
  end

  defp serve(connection) do
    owner = connection.owner

    receive do
      {:push, from, notifications} ->
        args = [connection.dispatcher, notifications, connection.timeout_ms]
        GenServer.reply(from, call_dependency(:push, connection.push, args))
        serve(connection)

      {:EXIT, ^owner, reason} ->
        exit(reason)

      {:EXIT, _dispatcher, reason} ->
        refuse_queued_pushes()
        exit({:apns_connection_lost, reason})
    end
  end

  # Batches already handed to a connection that is going away are answered,
  # so their callers do not wait out their whole timeout.
  defp refuse_queued_pushes do
    receive do
      {:push, from, _notifications} ->
        GenServer.reply(from, {:error, {:push_unavailable, :connection_lost}})
        refuse_queued_pushes()
    after
      0 -> :ok
    end
  end

  defp fetch_config(opts) do
    case Keyword.fetch(opts, :config) do
      {:ok, %Config{enabled: true} = config} -> {:ok, config}
      {:ok, values} -> enabled_config(values)
      :error -> {:error, :missing_push_config}
    end
  end

  defp enabled_config(values) do
    with {:ok, %Config{enabled: true} = config} <- Config.new(values) do
      {:ok, config}
    else
      {:ok, %Config{enabled: false}} -> {:error, :push_disabled}
      {:error, _reason} = error -> error
    end
  end

  defp start_pigeon_dispatcher(config) do
    Pigeon.Dispatcher.start_link(
      adapter: Pigeon.APNS,
      key: config.key,
      key_identifier: config.key_id,
      team_id: config.team_id,
      mode: Config.pigeon_mode(config),
      pool_size: 1
    )
  end

  defp push_all(dispatcher, notifications, timeout_ms) do
    {:ok, Pigeon.push(dispatcher, notifications, timeout: timeout_ms)}
  end

  defp stop_dispatcher(dispatcher) do
    Supervisor.stop(dispatcher, :normal, @shutdown_timeout_ms)
  end

  defp call(server, request, timeout) do
    GenServer.call(server, request, timeout)
  catch
    :exit, reason -> {:error, {:push_dispatcher_unavailable, reason}}
  end

  # Same contract as `FermixChannels.Mobile.Push.call_dependency/3`: the
  # exception class travels in the reason and the trace is logged, so a Fermix
  # defect stops reading as an APNs hiccup. Stack frame arguments are dropped
  # before formatting — they carry the notification list, whose device tokens and
  # encrypted payloads must never reach a log line.
  defp call_dependency(name, callback, args) when is_function(callback, length(args)) do
    apply(callback, args)
  rescue
    error ->
      Logger.error(
        "mobile push dependency #{inspect(name)} raised:\n" <>
          Exception.format(:error, error, arity_only(__STACKTRACE__))
      )

      {:error, {:push_dependency_exception, name, error.__struct__, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:push_dependency_exit, name, reason}}
  end

  defp call_dependency(name, callback, _args),
    do: {:error, {:invalid_push_dependency, name, callback}}

  defp arity_only(stacktrace) do
    Enum.map(stacktrace, fn
      {module, function, args, location} when is_list(args) ->
        {module, function, length(args), location}

      entry ->
        entry
    end)
  end

  defp config_fingerprint(config) do
    config
    |> Map.from_struct()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
  end
end
