defmodule FermixChannels.Test.TwoEngines do
  @moduledoc """
  A server and one of its computers in one test VM (M97 §6), each with its
  own home and its own processes under the test's names, joined by the real
  link: `DesktopRail`'s primary (a real `Mobile.Session` behind the real
  bridge socket, with the computer's server-side families) and the
  computer's real `Desktop.Relay`, offers reporter and `Desktop.Invoke`.

  The server side adds `Computers.Registry` and `Computers.Calls` under test
  names, and reaches the computer through `Desktop.InvokeTransport` with the
  primary's peers registry. The computer side takes every option explicitly
  (`home:`, `switches:`, `capabilities:`, `clock:`, `relay:`), so nothing
  is read from application environment and the two engines never share a
  setting. Its journal is under its own temporary home.

  The test capabilities below report each run to the test that started the
  engines (`{:running, name, pid, part}`) and, for the waiting ones, end
  when it says (`finish/2`). Each test module that uses this is
  `async: false`: the relay's dial and the computer's switch listeners are
  VM-wide names.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [start_supervised!: 1, start_supervised!: 2, on_exit: 1]

  alias FermixChannels.Desktop.ComputerFamily
  alias FermixChannels.Desktop.Invoke
  alias FermixChannels.Desktop.InvokeFamily
  alias FermixChannels.Desktop.InvokeTransport
  alias FermixChannels.Desktop.Offers
  alias FermixChannels.Test.DesktopRail
  alias FermixCore.Computers
  alias FermixCore.Computers.Calls
  alias FermixCore.Computers.Computer
  alias FermixCore.Computers.Facts
  alias FermixCore.Computers.Registry
  alias FermixCore.Computers.Switches
  alias FermixCore.Sandbox.Config, as: SandboxConfig
  alias FermixTestSupport.SafeRm

  @mac [
    os: :macos,
    arch: "arm64",
    landlock: :not_asked,
    helpers: %{computer_use: true},
    sandbox_mode: :standard
  ]

  defmodule Probe do
    @moduledoc false
    # Where a test capability tells the test of its run: keyed by the
    # computer's home, which each test makes its own.
    def tell(context, message) do
      test = :persistent_term.get({__MODULE__, context.home})
      send(test, message)
    end

    def await_finish(default) do
      receive do
        {:finish, result} -> result
      after
        30_000 -> default
      end
    end
  end

  defmodule Wait do
    @moduledoc "A read that runs until the test finishes it."
    @behaviour FermixCore.Computers.Capability

    @impl true
    def id, do: :wait
    @impl true
    def offer, do: :files
    @impl true
    def ops, do: ["wait"]
    @impl true
    def effect?(_op), do: false
    @impl true
    def long_lived?(_op), do: false
    @impl true
    def validate("wait", %{"name" => name}) when is_binary(name), do: :ok
    def validate("wait", _args), do: {:error, "Wait needs a name."}
    @impl true
    def bounds(_op), do: %{result_bytes: 1_024, part_bytes: 1_024 * 1_024}
    @impl true
    def admit(_op, _args, _context), do: :ok

    @impl true
    def run("wait", %{"name" => name}, part, context) do
      Probe.tell(context, {:running, name, self(), part})
      Probe.await_finish({:failed, "The test never finished it."})
    end

    @impl true
    def target("wait", %{"name" => name}), do: "wait #{name}"
  end

  defmodule Hold do
    @moduledoc "A long-lived read, asked with no deadline: it runs until the test finishes it."
    @behaviour FermixCore.Computers.Capability

    @impl true
    def id, do: :hold
    @impl true
    def offer, do: :files
    @impl true
    def ops, do: ["hold"]
    @impl true
    def effect?(_op), do: false
    @impl true
    def long_lived?(_op), do: true
    @impl true
    def validate("hold", %{"name" => name}) when is_binary(name), do: :ok
    def validate("hold", _args), do: {:error, "Hold needs a name."}
    @impl true
    def bounds(_op), do: %{result_bytes: 1_024, part_bytes: 0}
    @impl true
    def admit(_op, _args, _context), do: :ok

    @impl true
    def run("hold", %{"name" => name}, nil, context) do
      Probe.tell(context, {:running, name, self(), nil})
      Probe.await_finish({:failed, "The test never finished it."})
    end

    @impl true
    def target("hold", %{"name" => name}), do: "hold #{name}"
  end

  defmodule Touch do
    @moduledoc "An effect: it writes a file in the computer's home, then runs until finished."
    @behaviour FermixCore.Computers.Capability

    @impl true
    def id, do: :touch
    @impl true
    def offer, do: :files
    @impl true
    def ops, do: ["touch"]
    @impl true
    def effect?(_op), do: true
    @impl true
    def long_lived?(_op), do: false
    @impl true
    def validate("touch", %{"name" => name}) when is_binary(name), do: :ok
    def validate("touch", _args), do: {:error, "Touch needs a name."}
    @impl true
    def bounds(_op), do: %{result_bytes: 1_024, part_bytes: 0}
    @impl true
    def admit(_op, _args, _context), do: :ok

    @impl true
    def run("touch", %{"name" => name}, nil, context) do
      :ok = File.write(Path.join(context.home, name), "touched", [:append])
      Probe.tell(context, {:running, name, self(), nil})
      Probe.await_finish({:ok, %{"touched" => name}, nil})
    end

    @impl true
    def target("touch", %{"name" => name}), do: "touch #{name}"
  end

  @doc "The test capabilities a computer started here offers, by name."
  @spec capabilities() :: %{String.t() => module()}
  def capabilities,
    do: Map.merge(Invoke.capabilities(), %{"wait" => Wait, "hold" => Hold, "touch" => Touch})

  @doc """
  Starts the server and its computer, connected, the computer offering
  `:offers` (files by default). Answers what the test reaches them by.

  The computer's sandbox is its own: `:sandbox` (keyword for
  `Sandbox.Config.normalize/1`, its paths relative to the computer's home) or
  `strict` with the workspace under that home; the server's is the test VM's
  application environment, which never names the computer's home. `:send`
  replaces how the computer's answers reach the link (`Admission`'s seam),
  and `:browser` is the computer's browser (`Desktop.Invoke`'s option).
  `:facts` replaces facts of the computer its offers are worked out from
  (`Computers.Facts.read/1`'s options, over an Apple silicon Mac's).
  `:history` is the server's computer-history service's options
  (`ComputerHistory.Submission`'s: its store, summarizer and settings).
  """
  @spec start!(keyword()) :: map()
  def start!(opts \\ []) do
    suffix = System.unique_integer([:positive])
    names = names(suffix)
    server_home = SafeRm.make_tmp_dir!("two_engines_server")
    on_exit(fn -> SafeRm.rm_rf!(server_home) end)

    start_supervised!(
      {Registry, name: names.registry, home: server_home, status_changed: fn -> :ok end}
    )

    start_supervised!({Calls, name: names.calls})

    primary =
      DesktopRail.primary!(
        families: %{
          computer: {ComputerFamily, registry: names.registry},
          invoke:
            {InvokeFamily,
             [calls: names.calls, home: server_home] ++ Keyword.take(opts, [:history])}
        }
      )

    root = DesktopRail.desktop_home!(primary)
    :persistent_term.put({Probe, root}, self())
    on_exit(fn -> :persistent_term.erase({Probe, root}) end)
    computer!(primary, root, names, opts)
  end

  @doc "The computer's sandbox config for `opts`' `:sandbox` (the moduledoc of `start!/1`)."
  @spec sandbox(Path.t(), keyword()) :: SandboxConfig.t()
  def sandbox(root, given) do
    [mode: :strict, workspace_root: "workspace", allowed_roots: [], blocked_roots: []]
    |> Keyword.merge(given)
    |> Keyword.update!(:workspace_root, &Path.join(root, &1))
    |> Keyword.update!(:allowed_roots, fn roots -> Enum.map(roots, &Path.join(root, &1)) end)
    |> Keyword.update!(:blocked_roots, fn roots -> Enum.map(roots, &Path.join(root, &1)) end)
    |> Keyword.merge(home: root, os_home: root)
    |> SandboxConfig.normalize()
  end

  defp names(suffix) do
    %{
      registry: :"two_engines_registry_#{suffix}",
      calls: :"two_engines_calls_#{suffix}",
      relay: :"two_engines_relay_#{suffix}",
      offers: :"two_engines_offers_#{suffix}",
      invoke: :"two_engines_invoke_#{suffix}",
      switches: {:two_engines_switches, suffix}
    }
  end

  defp computer!(primary, root, names, opts) do
    offered = Keyword.get(opts, :offers, [:files])
    switches = start_supervised!({Agent, fn -> Switches.only(offered) end}, id: names.switches)
    read_switches = fn -> Agent.get(switches, & &1) end
    sandbox = sandbox(root, Keyword.get(opts, :sandbox, []))
    File.mkdir_p!(sandbox.workspace_root)

    start_supervised!(
      {Invoke,
       [
         name: names.invoke,
         home: root,
         switches: read_switches,
         sandbox: fn -> sandbox end,
         capabilities: capabilities(),
         clock: &DateTime.utc_now/0,
         relay: names.relay
       ] ++ Keyword.take(opts, [:send, :browser])}
    )

    start_supervised!(
      {Offers,
       name: names.offers,
       home: root,
       relay: names.relay,
       facts: fn -> Facts.read(Keyword.merge(@mac, Keyword.get(opts, :facts, []))) end,
       switches: read_switches,
       timer: fn _message, _delay -> make_ref() end}
    )

    DesktopRail.start_relay!(root, primary,
      name: names.relay,
      offers: names.offers,
      families: %{invoke: Invoke.admission(names.invoke)}
    )

    DesktopRail.await_connected(names.relay)

    engines =
      Map.merge(names, %{
        primary: primary,
        root: root,
        admission: Invoke.admission(names.invoke),
        switch_agent: switches,
        sandbox: sandbox,
        device_id: DesktopRail.device_id()
      })

    await_offers(engines)
    engines
  end

  @doc "Waits until the server holds the computer's offers, within 10 s."
  @spec await_offers(map(), non_neg_integer()) :: [map()]
  def await_offers(engines, attempts \\ 1_000) do
    case Registry.live(engines.registry)[engines.device_id] do
      %{offers: [_ | _] = offers} ->
        offers

      _none when attempts == 0 ->
        flunk("the server never heard what the computer offers")

      _none ->
        # sleep: polls the server's live view, which tells only the Always On watch
        Process.sleep(10)
        await_offers(engines, attempts - 1)
    end
  end

  @doc "The computer as the server knows it now."
  @spec computer(map()) :: Computer.t()
  def computer(engines) do
    live = Registry.live(engines.registry)[engines.device_id]

    %Computer{
      device_id: engines.device_id,
      name: "studio Mac",
      platform: :macos,
      connected: live != nil,
      last_seen: ~U[2026-11-09 22:40:00Z],
      offers: if(live, do: live.offers, else: [])
    }
  end

  @doc "The options a call from the server takes here."
  @spec call_opts(map(), keyword()) :: keyword()
  def call_opts(engines, more \\ []) do
    [
      calls: engines.calls,
      transport: {InvokeTransport, registry: engines.primary.peers},
      epoch: 3
    ]
    |> Keyword.merge(more)
  end

  @doc "An owner's chat turn on the server."
  @spec turn() :: map()
  def turn,
    do: %{session_id: "main-31", computer_use_origin: :interactive, source_trust: :operator}

  @doc "Calls the computer from the server, beside the test, which plays the owner."
  @spec call(map(), module(), String.t(), map(), keyword()) :: Task.t()
  def call(engines, module, op, args, more \\ []) do
    computer = computer(engines)
    opts = call_opts(engines, more)
    Task.async(fn -> Computers.call(computer, module, op, args, turn(), opts) end)
  end

  @doc "A test capability's run, as it reports itself."
  @spec running(String.t()) :: {pid(), binary() | nil}
  def running(name) do
    assert_receive {:running, ^name, pid, part}, 10_000
    {pid, part}
  end

  @doc "Ends a waiting test capability's run with `result`."
  @spec finish(pid(), term()) :: :ok
  def finish(pid, result) do
    send(pid, {:finish, result})
    :ok
  end

  @doc """
  Ends the computer's session as a lost connection does, and lets it come
  back only when `reconnect!/1` is called.
  """
  @spec drop_session!(map()) :: :ok
  def drop_session!(engines) do
    connections = engines.primary.connections

    for {_id, pid, _type, _modules} <- DynamicSupervisor.which_children(connections),
        is_pid(pid),
        do: :ok = DynamicSupervisor.terminate_child(connections, pid)

    assert_receive {:scheduled, {:relay_timer, :reconnect, _token} = timer, _delay}, 10_000
    Process.put({__MODULE__, :reconnect}, timer)
    :ok
  end

  @doc "Lets the dropped session come back, and waits until it is up."
  @spec reconnect!(map()) :: :ok
  def reconnect!(engines) do
    timer = Process.delete({__MODULE__, :reconnect})
    send(Process.whereis(engines.relay), timer)
    DesktopRail.await_connected(engines.relay)
    :ok
  end
end
