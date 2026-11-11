defmodule FermixChannels.Channels.IMessage.Supervisor do
  @moduledoc """
  The iMessage transport (MILESTONE_54 §5): `IMessage.Port`, which owns the
  Fermix Messages helper, then `IMessage.Listener`, which subscribes through it.
  `:rest_for_one`, so a Port crash restarts the Listener with it, while a
  Listener crash leaves the helper running.

  Off a Mac (M97 §6.4) the helper is the Mac of the home that carries
  Messages: `IMessage.ComputerHelper` takes the Port's place, the Listener
  runs here as it does on a Mac, and nothing is spawned here. No executable
  is resolved then; `:computers`, `:call_opts`, `:poll_ms` and `:retry_ms`
  pass to the computer helper, and `:macos?` names the host for a test.

  The helper executable and FERMIX_HOME are resolved once, here, through the
  core seams (`FermixCore.IMessage.HelperInstaller.binary_path/0`,
  `FermixCore.IMessage.Home.dir/0`), and passed down; tests inject them
  (`:executable`, `:home`, or the `:installer` / `:home_dir` modules). A
  missing helper, recipients the config cannot express, or a helper on another
  protocol version fails the start loud with that class (the channel registry
  does not start this supervisor while the helper is missing, §14). The account
  posture is not resolved here: the Listener reads the one the helper derived.
  """

  use Supervisor

  alias FermixChannels.Channels.IMessage
  alias FermixChannels.Channels.IMessage.ComputerHelper
  alias FermixChannels.Channels.IMessage.Listener
  alias FermixChannels.Channels.IMessage.Port, as: HelperPort

  @installer FermixCore.IMessage.HelperInstaller
  @home_dir FermixCore.IMessage.Home
  @port_options [:backoff_initial_ms, :backoff_max_ms, :init_timeout_ms, :max_outstanding]
  @computer_options [:computers, :call_opts, :poll_ms, :retry_ms]
  @listener_options [:agent, :agent_server, :probe_retry_ms, :handoff_retry_ms, :loop_pause_ms]

  @doc """
  Starts the transport. Options: `:name`, `:port_name`, `:listener_name`;
  `:executable` or `:installer`; `:home` or `:home_dir`; `:recipients`
  (default: `IMessage.recipients_from_config/0`); and the Port's and Listener's own tuning
  options, passed through.
  """
  @spec start_link(keyword()) :: Supervisor.on_start() | {:error, term()}
  def start_link(opts \\ []) when is_list(opts) do
    home_dir = Keyword.get(opts, :home_dir, @home_dir)
    here? = Keyword.get_lazy(opts, :macos?, &FermixCore.IMessage.macos?/0)

    with {:ok, executable} <- executable(opts, here?),
         {:ok, recipients} <- recipients(opts),
         home = Keyword.get_lazy(opts, :home, fn -> home_dir.fermix_home() end),
         :ok <- ensure_home(opts, home_dir) do
      init_arg =
        Keyword.merge(opts,
          executable: executable,
          home: home,
          recipients: recipients,
          here?: here?
        )

      Supervisor.start_link(__MODULE__, init_arg, name: Keyword.get(opts, :name, __MODULE__))
    end
  end

  @impl Supervisor
  def init(opts) do
    {helper, helper_spec} = helper_spec(opts)

    listener_opts =
      [
        name: Keyword.get(opts, :listener_name, Listener),
        helper: helper,
        server: Keyword.fetch!(elem(helper_spec, 1), :name),
        home: opts[:home],
        recipients: opts[:recipients]
      ] ++ Keyword.take(opts, @listener_options)

    Supervisor.init([helper_spec, {Listener, listener_opts}], strategy: :rest_for_one)
  end

  # This Mac's helper, or the Mac of the home that carries Messages.
  defp helper_spec(opts) do
    if opts[:here?] do
      port_opts =
        [name: Keyword.get(opts, :port_name, HelperPort), executable: opts[:executable]] ++
          [home: opts[:home]] ++ Keyword.take(opts, @port_options)

      {HelperPort, {HelperPort, port_opts}}
    else
      computer_opts =
        [name: Keyword.get(opts, :port_name, ComputerHelper), home: opts[:home]] ++
          Keyword.take(opts, @computer_options)

      {ComputerHelper, {ComputerHelper, computer_opts}}
    end
  end

  # The four `FERMIX_HOME/imessage` directories exist before the helper is
  # spawned, at 0700: the helper refuses a home it cannot find (exit 64) rather
  # than inventing one. A test that passes `:home` owns its own directories.
  defp ensure_home(opts, home_dir) do
    if Keyword.has_key?(opts, :home), do: :ok, else: home_dir.ensure()
  end

  # The helper is on the Mac that carries Messages, never spawned here.
  defp executable(_opts, false), do: {:ok, nil}

  defp executable(opts, true) do
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

  defp recipients(opts) do
    case Keyword.fetch(opts, :recipients) do
      {:ok, recipients} when is_map(recipients) -> {:ok, recipients}
      :error -> IMessage.recipients_from_config()
    end
  end
end
