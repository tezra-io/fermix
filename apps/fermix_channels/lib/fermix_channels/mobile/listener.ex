defmodule FermixChannels.Mobile.Listener do
  @moduledoc """
  Lifecycle owner for the dedicated mobile TLS listener.

  The process starts dormant on a fresh installation. `Mobile.PairManager`
  creates the gateway identity during the first pairing window and activates
  this listener with it. On later boots the existing identity is loaded and
  Bandit starts immediately.

  An address it cannot listen on (a Tailscale address not up yet at login, a
  port another daemon holds) leaves it unavailable, never stopped: a stop
  escalates through the channels supervisor and halts the whole daemon. It
  says why through `status/1`, retries from one second doubling to a minute,
  and gives up after a day until the next boot. A Bandit that dies while
  serving is retried the same way.
  """

  use GenServer

  require Logger

  alias FermixChannels.Mobile.Identity
  alias FermixChannels.Mobile.Router
  alias FermixChannels.Mobile.TlsTransport

  @default_bind {0, 0, 0, 0}
  @default_port 4031
  # Pre-authentication bounds (SEC-2): phones are few, so 64 concurrent
  # connections in all, and an HTTP request slower than this before the
  # upgrade is closed. The WebSocket idle timeout governs after the upgrade.
  # `TlsTransport` ends a TLS handshake at ten seconds and the whole HTTP
  # phase at its upgrade deadline, and `SocketHandler` ends a socket that has
  # not said hello or sent its pair request, so a peer that stays silent, or
  # keeps talking HTTP, gives its slot back instead of holding it.
  @num_acceptors 4
  @num_connections 16
  @read_timeout_ms 10_000
  # A phone sends one small upgrade request: anything else gets one answer and
  # the connection closes. No phone speaks HTTP/2, whose connection idles
  # between frames where no read bounds it.
  @http_1_options [
    max_requests: 1,
    max_request_line_length: 2_048,
    max_header_length: 4_096,
    max_header_count: 32
  ]
  @first_retry_ms 1_000
  @max_retry_ms 60_000
  @retry_window_ms 24 * 3_600_000
  # How deep `failure/1` looks into a nested start error for the socket errno.
  @max_reason_depth 8

  @typedoc "Why the listener cannot serve, in the words `mobile.status` publishes."
  @type failure :: :address_unavailable | :address_in_use | :permission_denied | :listen_failed
  @type status ::
          :dormant
          | {:listening, {:inet.ip_address(), :inet.port_number()}}
          | {:unavailable, failure()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Starts Bandit once with identity material created by the pairing owner."
  @spec activate(GenServer.server(), Identity.t()) :: {:ok, status()} | {:error, term()}
  def activate(server \\ __MODULE__, %Identity{} = identity) do
    GenServer.call(server, {:activate, identity})
  end

  @doc "Dormant, unavailable with its reason, or the bound address (port 0 resolved)."
  @spec status(GenServer.server()) :: status()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc "Returns the actual address and port, including an OS-assigned port 0."
  @spec listener_info(GenServer.server()) ::
          {:ok, {:inet.ip_address(), :inet.port_number()}} | {:error, :not_listening}
  def listener_info(server \\ __MODULE__), do: GenServer.call(server, :listener_info)

  @doc false
  @spec options(keyword()) :: {:ok, keyword()} | {:error, term()}
  def options(opts) when is_list(opts) do
    port = Keyword.get(opts, :port, @default_port)
    keyfile = Keyword.get(opts, :keyfile)
    certfile = Keyword.get(opts, :certfile)

    with {:ok, bind} <- normalize_bind(Keyword.get(opts, :bind, @default_bind)),
         :ok <- validate_port(port),
         :ok <- validate_path(keyfile, :keyfile),
         :ok <- validate_path(certfile, :certfile) do
      {:ok, bandit_options(opts, bind, port, keyfile, certfile)}
    end
  end

  def options(_opts), do: {:error, :invalid_options}

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      bandit: nil,
      identity: nil,
      failure: nil,
      retry: nil,
      listener_opts: listener_opts(opts),
      root: Keyword.get(opts, :root),
      start_listener?: Keyword.get(opts, :start_listener?, true),
      clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end),
      schedule_retry: Keyword.get(opts, :schedule_retry, &Process.send_after(self(), &1, &2))
    }

    initialize_listener(state)
  end

  @impl true
  def handle_call({:activate, identity}, _from, %{bandit: nil} = state) do
    case start_bandit(state.listener_opts, identity) do
      {:ok, bandit} ->
        state = serving(state, bandit, identity)
        {:reply, listening_status(bandit), state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:activate, _identity}, _from, state) do
    {:reply, listening_status(state.bandit), state}
  end

  def handle_call(:status, _from, %{bandit: nil, failure: nil} = state),
    do: {:reply, :dormant, state}

  def handle_call(:status, _from, %{bandit: nil} = state),
    do: {:reply, {:unavailable, state.failure}, state}

  def handle_call(:status, _from, state) do
    {:reply, status_from_bandit(state.bandit), state}
  end

  def handle_call(:listener_info, _from, %{bandit: nil} = state) do
    {:reply, {:error, :not_listening}, state}
  end

  def handle_call(:listener_info, _from, state) do
    {:reply, ThousandIsland.listener_info(state.bandit), state}
  end

  @impl true
  def handle_info({:EXIT, bandit, reason}, %{bandit: bandit} = state) do
    Logger.error("mobile listener stopped serving (#{inspect(reason)}); retrying")
    state = %{state | bandit: nil}
    {:noreply, begin_retries(state, {:listener_exited, reason})}
  end

  def handle_info({:retry_listen, token}, %{retry: %{token: token}} = state) do
    {:noreply, retry_listen(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{bandit: bandit}) when is_pid(bandit) do
    if Process.alive?(bandit), do: Supervisor.stop(bandit, :shutdown)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp initialize_listener(%{start_listener?: false} = state), do: {:ok, state}

  defp initialize_listener(state) do
    case existing_identity(state.root) do
      {:ok, nil} -> {:ok, state}
      {:ok, identity} -> init_bandit(state, identity)
      {:error, reason} -> {:stop, {:mobile_identity_unavailable, reason}}
    end
  end

  defp init_bandit(state, identity) do
    state = %{state | identity: identity}

    case start_bandit(state.listener_opts, identity) do
      {:ok, bandit} -> {:ok, %{state | bandit: bandit}}
      {:error, reason} -> {:ok, begin_retries(state, reason)}
    end
  end

  defp serving(state, bandit, identity),
    do: %{state | bandit: bandit, identity: identity, failure: nil, retry: nil}

  # The retry window is measured from the first failure of a run of them, so
  # a listener that keeps failing gives up a day after it stopped serving.
  defp begin_retries(state, reason) do
    now = state.clock.()
    Logger.error("mobile listener could not listen (#{inspect(reason)}); retrying")
    retry = %{deadline_ms: now + @retry_window_ms, delay_ms: @first_retry_ms, token: nil}
    arm_retry(%{state | failure: failure(reason), retry: retry})
  end

  defp arm_retry(%{retry: retry} = state) do
    token = make_ref()
    _timer = state.schedule_retry.({:retry_listen, token}, retry.delay_ms)
    %{state | retry: %{retry | token: token}}
  end

  defp retry_listen(%{retry: retry} = state) do
    if state.clock.() >= retry.deadline_ms do
      give_up(state)
    else
      attempt_listen(state)
    end
  end

  defp attempt_listen(state) do
    case start_bandit(state.listener_opts, state.identity) do
      {:ok, bandit} ->
        Logger.info("mobile listener is serving again")
        serving(state, bandit, state.identity)

      {:error, reason} ->
        Logger.warning("mobile listener retry failed (#{inspect(reason)})")
        delay = min(state.retry.delay_ms * 2, @max_retry_ms)
        arm_retry(%{state | failure: failure(reason), retry: %{state.retry | delay_ms: delay}})
    end
  end

  defp give_up(state) do
    Logger.error(
      "mobile listener stopped retrying after a day without serving (#{state.failure}); " <>
        "it stays unavailable until Fermix restarts"
    )

    %{state | retry: nil}
  end

  # The errno is buried in whichever supervisor or listener tuple reported it.
  defp failure(reason) do
    cond do
      mentions?(reason, :eaddrnotavail, @max_reason_depth) -> :address_unavailable
      mentions?(reason, :eaddrinuse, @max_reason_depth) -> :address_in_use
      mentions?(reason, :eacces, @max_reason_depth) -> :permission_denied
      true -> :listen_failed
    end
  end

  defp mentions?(atom, atom, _depth), do: true
  defp mentions?(_term, _atom, 0), do: false

  defp mentions?(term, atom, depth) when is_tuple(term),
    do: term |> Tuple.to_list() |> mentions?(atom, depth)

  defp mentions?(term, atom, depth) when is_list(term),
    do: Enum.any?(term, &mentions?(&1, atom, depth - 1))

  defp mentions?(_term, _atom, _depth), do: false

  defp existing_identity(root) do
    opts = if is_nil(root), do: [], else: [root: root]

    with {:ok, paths} <- Identity.paths(opts) do
      case Enum.map(identity_entries(paths), &File.lstat/1) do
        [{:error, :enoent}, {:error, :enoent}, {:error, :enoent}, {:error, :enoent}] ->
          {:ok, nil}

        _some_present_or_unreadable ->
          Identity.ensure(opts)
      end
    end
  end

  defp start_bandit(listener_opts, identity) do
    opts =
      listener_opts
      |> Keyword.put(:keyfile, identity.tls_key_path)
      |> Keyword.put(:certfile, identity.tls_cert_path)
      |> Keyword.put(:identity, identity)

    with {:ok, bandit_opts} <- options(opts),
         :ok <- validate_file(identity.tls_key_path, :keyfile),
         :ok <- validate_file(identity.tls_cert_path, :certfile) do
      Bandit.start_link(bandit_opts)
    end
  end

  defp listener_opts(opts) do
    Keyword.take(opts, [:bind, :port, :router_opts, :startup_log])
  end

  defp identity_files(paths), do: [paths.gateway_key, paths.tls_key, paths.tls_cert]
  defp identity_entries(paths), do: identity_files(paths) ++ [paths.transaction]

  defp listening_status(bandit) do
    case ThousandIsland.listener_info(bandit) do
      {:ok, address} -> {:ok, {:listening, address}}
      :error -> {:error, :listener_info_unavailable}
    end
  end

  defp status_from_bandit(bandit) do
    case ThousandIsland.listener_info(bandit) do
      {:ok, address} -> {:listening, address}
      :error -> :dormant
    end
  end

  defp bandit_options(opts, bind, port, keyfile, certfile) do
    [
      scheme: :https,
      ip: bind,
      port: port,
      keyfile: keyfile,
      certfile: certfile,
      plug: {Router, router_opts(opts)},
      startup_log: Keyword.get(opts, :startup_log, false),
      thousand_island_options: [
        num_acceptors: @num_acceptors,
        num_connections: @num_connections,
        read_timeout: @read_timeout_ms,
        transport_module: TlsTransport
      ],
      http_1_options: @http_1_options,
      http_2_options: [enabled: false],
      websocket_options: [
        max_frame_size: Router.max_frame_size(),
        compress: false
      ]
    ]
  end

  defp router_opts(opts) do
    router_opts = Keyword.get(opts, :router_opts, [])
    identity = Keyword.fetch!(opts, :identity)
    root = identity.tls_key_path |> Path.dirname() |> Path.dirname()
    Keyword.put(router_opts, :identity_root, root)
  end

  defp normalize_bind({a, b, c, d} = bind)
       when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255,
       do: {:ok, bind}

  defp normalize_bind(bind) when is_binary(bind) do
    case :inet.parse_address(String.to_charlist(bind)) do
      {:ok, address} -> {:ok, address}
      {:error, reason} -> {:error, {:invalid_bind, bind, reason}}
    end
  end

  defp normalize_bind(bind), do: {:error, {:invalid_bind, bind}}

  defp validate_port(port) when is_integer(port) and port in 0..65_535, do: :ok
  defp validate_port(port), do: {:error, {:invalid_port, port}}

  defp validate_path(path, field) when is_binary(path) and path != "" do
    if Path.type(path) == :absolute, do: :ok, else: {:error, {:invalid_path, field}}
  end

  defp validate_path(_path, field), do: {:error, {:invalid_path, field}}

  defp validate_file(path, field) do
    case File.stat(path) do
      {:ok, %{type: :regular}} -> :ok
      {:ok, _stat} -> {:error, {:not_regular_file, field, path}}
      {:error, reason} -> {:error, {:missing_file, field, path, reason}}
    end
  end
end
