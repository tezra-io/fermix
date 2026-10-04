defmodule FermixChannels.Channels.IMessage.Supervisor do
  @moduledoc """
  The iMessage transport (MILESTONE_54 §5): `IMessage.Port`, which owns the
  Fermix Messages helper, then `IMessage.Listener`, which subscribes through it.
  `:rest_for_one`, so a Port crash restarts the Listener with it, while a
  Listener crash leaves the helper running.

  The helper executable and FERMIX_HOME are resolved once, here, through the
  core seams (`FermixCore.IMessage.HelperInstaller.binary_path/0`,
  `FermixCore.IMessage.Home.dir/0`), and passed down; tests inject them
  (`:executable`, `:home`, or the `:installer` / `:home_dir` modules). A
  missing helper, a policy the config cannot express, or a helper on another
  protocol version fails the start loud with that class.
  """

  use Supervisor

  alias FermixChannels.Channels.IMessage
  alias FermixChannels.Channels.IMessage.Listener
  alias FermixChannels.Channels.IMessage.Port, as: HelperPort

  @installer FermixCore.IMessage.HelperInstaller
  @home_dir FermixCore.IMessage.Home
  @port_options [:backoff_initial_ms, :backoff_max_ms, :init_timeout_ms, :max_outstanding]
  @listener_options [:agent, :agent_server, :probe_retry_ms, :handoff_retry_ms, :loop_pause_ms]

  @doc """
  Starts the transport. Options: `:name`, `:port_name`, `:listener_name`;
  `:executable` or `:installer`; `:home` or `:home_dir`; `:policy` (default:
  `IMessage.policy_from_config/0`); and the Port's and Listener's own tuning
  options, passed through.
  """
  @spec start_link(keyword()) :: Supervisor.on_start() | {:error, term()}
  def start_link(opts \\ []) when is_list(opts) do
    home_dir = Keyword.get(opts, :home_dir, @home_dir)

    with {:ok, executable} <- executable(opts),
         {:ok, policy} <- policy(opts),
         home = Keyword.get_lazy(opts, :home, fn -> home_dir.fermix_home() end),
         :ok <- ensure_home(opts, home_dir) do
      init_arg = Keyword.merge(opts, executable: executable, home: home, policy: policy)
      Supervisor.start_link(__MODULE__, init_arg, name: Keyword.get(opts, :name, __MODULE__))
    end
  end

  @impl Supervisor
  def init(opts) do
    port_name = Keyword.get(opts, :port_name, HelperPort)

    port_opts =
      [name: port_name, executable: opts[:executable], home: opts[:home]] ++
        Keyword.take(opts, @port_options)

    listener_opts =
      [
        name: Keyword.get(opts, :listener_name, Listener),
        helper: HelperPort,
        server: port_name,
        home: opts[:home],
        policy: opts[:policy]
      ] ++ Keyword.take(opts, @listener_options)

    Supervisor.init([{HelperPort, port_opts}, {Listener, listener_opts}], strategy: :rest_for_one)
  end

  # The four `FERMIX_HOME/imessage` directories exist before the helper is
  # spawned, at 0700: the helper refuses a home it cannot find (exit 64) rather
  # than inventing one. A test that passes `:home` owns its own directories.
  defp ensure_home(opts, home_dir) do
    if Keyword.has_key?(opts, :home), do: :ok, else: home_dir.ensure()
  end

  defp executable(opts) do
    case Keyword.fetch(opts, :executable) do
      {:ok, path} when is_binary(path) -> {:ok, path}
      :error -> installed(Keyword.get(opts, :installer, @installer))
    end
  end

  defp installed(installer) do
    case installer.binary_path() do
      {:ok, path} when is_binary(path) -> {:ok, path}
      {:error, reason} -> {:error, {:helper_missing, reason}}
    end
  end

  defp policy(opts) do
    case Keyword.fetch(opts, :policy) do
      {:ok, policy} when is_map(policy) -> {:ok, policy}
      :error -> IMessage.policy_from_config()
    end
  end
end
