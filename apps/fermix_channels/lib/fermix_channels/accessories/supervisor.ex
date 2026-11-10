defmodule FermixChannels.Accessories.Supervisor do
  @moduledoc """
  The accessories subtree (M91 §04): the pairing store's writer, the links
  and the port watcher, under `:rest_for_one` in that order. A link
  supervisor that starts again takes the watcher with it, and a watcher that
  starts again ends every link it finds (`Watcher`), so no port is ever held
  by a link nobody watches. Each link is a temporary child of its own, so one
  link's crash ends only its own call, and the voice core
  (`FermixCore.Realtime.Supervisor`, in core) is never in this tree.

  It runs only where it may (M91 §04, D9, D13):

    * **The switch.** `[fermix_channels.accessories] enabled`, default off
      (`FermixCore.Accessories.Config`). The channels application registers
      this subtree for the whole boot, on or off (`boot_child/0`), and
      `start_link/1` starts nothing while it is off; `switch/2` starts or
      stops the registered child when the setting changes, the mobile
      channel's precedent. Off, there is no watcher and no port is opened.
    * **The role.** Only a primary: it is in `Home.Role`'s primary-only list,
      so a device-role or candidate engine never starts it, whatever its
      `machine.toml` says after a move.
    * **The platform.** Only macOS: a home moved to a Linux server carries
      its records, and the switch stays on the Mac (`machine.toml`).
    * **Voice.** Not at all: the link runs whenever the switch is on, so an
      accessory stays attached and is told voice is not ready while voice is
      off, its key missing, or its runtime not started this boot.

  A test tree never registers it (`FermixChannels.Application`): a suite run
  against a home that has accessories on must open no port.
  """

  use Supervisor

  alias FermixChannels.Accessories.Serial
  alias FermixChannels.Accessories.StoreWriter
  alias FermixChannels.Accessories.Watcher
  alias FermixCore.Accessories.Config
  alias FermixCore.Setup.ConfigStore

  require Logger

  @links FermixChannels.Accessories.Links

  @doc "The child the channels application registers for the whole boot."
  @spec boot_child() :: {module(), keyword()}
  def boot_child, do: {__MODULE__, switch: &switch_on?/0}

  @doc "Whether `[fermix_channels.accessories] enabled` is on in the running config."
  @spec switch_on?() :: boolean()
  def switch_on?, do: Config.enabled?()

  @doc """
  Starts the subtree when its switch reads on and this is a Mac. `:switch` is
  the zero-arity read of the switch (a subtree started without one, as a test
  starts it, always starts), `:os_type` the platform, `:home` the home, and
  `:names`, `:transport`, `:transport_opts`, `:watcher_opts` and
  `:link_opts` replace the daemon's own in a test.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    cond do
      not switched_on?(opts) -> :ignore
      not mac?(opts) -> not_a_mac()
      true -> start_tree(opts)
    end
  end

  @doc """
  Starts or stops the registered subtree while the daemon runs, as
  `FermixChannels.Mobile.Supervisor.switch/2` does the phone's: on, the
  registered child starts again and reads its switch (`:not_started` when it
  still reads off, or this is not a Mac); `{:error, :not_ready}` when this
  boot registered none (a device-role engine, or a test tree); off, the child
  stops and stays registered. `:parent` replaces the channels supervisor in
  a test.
  """
  @spec switch(boolean(), keyword()) ::
          {:ok, :started | :not_started | :stopped} | {:error, :not_ready | term()}
  def switch(on?, opts \\ [])

  def switch(true, opts) when is_list(opts) do
    case Supervisor.restart_child(parent(opts), __MODULE__) do
      {:ok, pid} when is_pid(pid) -> {:ok, :started}
      {:ok, :undefined} -> {:ok, :not_started}
      {:error, :running} -> {:ok, :started}
      {:error, :not_found} -> {:error, :not_ready}
      {:error, reason} -> {:error, reason}
    end
  end

  def switch(false, opts) when is_list(opts) do
    case Supervisor.terminate_child(parent(opts), __MODULE__) do
      :ok -> {:ok, :stopped}
      {:error, :not_found} -> {:ok, :stopped}
    end
  end

  @doc "Whether the subtree runs: its registered name is alive."
  @spec running?((GenServer.name() -> pid() | nil)) :: boolean()
  def running?(whereis \\ &GenServer.whereis/1) when is_function(whereis, 1),
    do: is_pid(whereis.(__MODULE__))

  defp parent(opts), do: Keyword.get(opts, :parent, FermixChannels.Supervisor)

  defp switched_on?(opts) do
    case Keyword.get(opts, :switch) do
      nil -> true
      switch when is_function(switch, 0) -> switch.() == true
      other -> raise ArgumentError, ":switch must be a zero-arity function, got #{inspect(other)}"
    end
  end

  defp mac?(opts), do: Keyword.get_lazy(opts, :os_type, &:os.type/0) == {:unix, :darwin}

  defp not_a_mac do
    Logger.warning(
      "accessories are on in machine.toml, but an accessory needs a local Mac primary; " <>
        "no accessory port is watched on this engine"
    )

    :ignore
  end

  defp start_tree(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> Supervisor.start_link(__MODULE__, opts)
      name -> Supervisor.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(opts) do
    home = Keyword.get_lazy(opts, :home, &ConfigStore.fermix_home/0)
    names = names(opts)

    watcher_opts =
      Keyword.merge(
        [
          name: names.watcher,
          transport: Keyword.get(opts, :transport, Serial),
          transport_opts: Keyword.get(opts, :transport_opts, []),
          home: home,
          link_supervisor: names.links,
          link_opts:
            Keyword.put_new(Keyword.get(opts, :link_opts, []), :store_writer, names.store_writer)
        ],
        Keyword.get(opts, :watcher_opts, [])
      )

    children = [
      {StoreWriter, home: home, name: names.store_writer},
      {DynamicSupervisor, name: names.links, strategy: :one_for_one},
      {Watcher, watcher_opts}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc false
  @spec names(keyword()) :: %{store_writer: atom(), links: atom(), watcher: atom()}
  def names(opts \\ []) do
    Map.merge(
      %{store_writer: StoreWriter, links: @links, watcher: Watcher},
      Keyword.get(opts, :names, %{})
    )
  end
end
