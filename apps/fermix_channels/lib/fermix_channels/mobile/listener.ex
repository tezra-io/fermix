defmodule FermixChannels.Mobile.Listener do
  @moduledoc """
  Lifecycle owner for the dedicated mobile TLS listener.

  The process starts dormant on a fresh installation. `Mobile.PairManager`
  creates the gateway identity during the first pairing window and activates
  this listener with it. On later boots the existing identity is loaded and
  Bandit starts immediately.
  """

  use GenServer

  alias FermixChannels.Mobile.Identity

  @default_bind {0, 0, 0, 0}
  @default_port 4031
  @max_frame_size 65_535

  @type status :: :dormant | {:listening, {:inet.ip_address(), :inet.port_number()}}

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

  @doc "Returns dormant state or the actual bound address, including port 0 allocation."
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
      listener_opts: listener_opts(opts),
      root: Keyword.get(opts, :root),
      start_listener?: Keyword.get(opts, :start_listener?, true)
    }

    initialize_listener(state)
  end

  @impl true
  def handle_call({:activate, identity}, _from, %{bandit: nil} = state) do
    case start_bandit(state.listener_opts, identity) do
      {:ok, bandit} -> {:reply, listening_status(bandit), %{state | bandit: bandit}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:activate, _identity}, _from, state) do
    {:reply, listening_status(state.bandit), state}
  end

  def handle_call(:status, _from, %{bandit: nil} = state), do: {:reply, :dormant, state}

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
    {:stop, {:bandit_exited, reason}, %{state | bandit: nil}}
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
    case start_bandit(state.listener_opts, identity) do
      {:ok, bandit} -> {:ok, %{state | bandit: bandit}}
      {:error, reason} -> {:stop, {:mobile_listener_unavailable, reason}}
    end
  end

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
      plug: {FermixChannels.Mobile.Router, router_opts(opts)},
      startup_log: Keyword.get(opts, :startup_log, false),
      websocket_options: [max_frame_size: @max_frame_size, compress: false]
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
