defmodule FermixCore.Browser.HostServerTest do
  use ExUnit.Case, async: true

  alias FermixCore.Browser
  alias FermixCore.Browser.Backend
  alias FermixCore.Browser.Capabilities
  alias FermixCore.Browser.CDP
  alias FermixCore.Browser.Config
  alias FermixCore.Browser.Error
  alias FermixCore.Browser.HostAvailability
  alias FermixCore.Browser.HostServer
  alias FermixCore.Browser.ProfileManager
  alias FermixCore.Browser.ProfileServer

  # A backend whose runtime always comes up and whose every operation answers,
  # so what the server refuses on its own is visible: it never reaches here.
  defmodule UpBackend do
    @behaviour FermixCore.Browser.Backend

    @ops ~w(open navigate snapshot tabs focus close screenshot pdf console dialog cookies storage
            upload download act webmcp)a

    @impl true
    def init(opts), do: %{test_pid: Keyword.fetch!(opts, :test_pid)}
    @impl true
    def status(_state), do: %{"running" => true, "tabs" => 1}
    @impl true
    def start(_context, state), do: {:ok, state}
    @impl true
    def stop(state), do: state
    @impl true
    def handle_message(_message, state), do: state
    @impl true
    def console_buffer(_state), do: []

    for op <- @ops do
      @impl true
      def unquote(op)(_args, _context, state) do
        send(state.test_pid, {:backend_asked, unquote(op)})
        {:ok, %{"ok" => true}, state}
      end
    end
  end

  # A launcher that must never be reached: a pane profile is never Chrome.
  defmodule NoChrome do
    def attach(_config, _profile, _owner, _name), do: raise("a pane profile reached for Chrome")
    def start(_config, _profile, _owner, _name), do: raise("a pane profile launched Chrome")
    def stop(_runtime, _config), do: :ok
  end

  @pane %{mode: :fermix_app, headless: :auto, cdp_port: :auto}

  defp start_server(opts) do
    {:ok, config} = Config.current(%{})

    spec =
      {ProfileServer,
       [owner_key: "owner-pane", profile_name: "fermix", profile: @pane, config: config] ++ opts}

    start_supervised!(Supervisor.child_spec(spec, restart: :temporary))
  end

  # An isolated host, attached and reporting its pane available.
  defp usable_host do
    host = start_supervised!({HostAvailability, name: nil}, id: make_ref())
    endpoint = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(endpoint, :kill) end)
    :ok = HostAvailability.listening(host, endpoint)
    :ok = HostAvailability.attached(host)
    :ok = HostAvailability.report(host, true, nil)
    host
  end

  defp req(pid, action, args \\ %{}),
    do: ProfileServer.request(pid, %{action: action, args: args, context: %{agent_name: "t"}})

  test "the fermix_app mode is the host backend, and every other mode is CDP's" do
    assert Backend.for_mode(:fermix_app) == HostServer

    for mode <- [:managed, :existing_session, :remote_cdp, :attached_tab] do
      assert Backend.for_mode(mode) == CDP.Backend
    end
  end

  test "the app's pane is a whole browser of Fermix's own, without WebMCP" do
    caps = Capabilities.for_mode(:fermix_app)

    for capability <- [
          :new_tab,
          :close_tab,
          :focus_tab,
          :cookies,
          :downloads,
          :download_redirect,
          :target_discovery,
          :tab_cap
        ] do
      assert Map.fetch!(caps, capability), "#{capability} is withheld from the app's pane"
    end

    refute caps.webmcp
    refute caps.target_attach

    assert Map.keys(caps) |> Enum.sort() ==
             Capabilities.for_mode(:managed) |> Map.keys() |> Enum.sort()
  end

  # Until the wire lands the stub is the whole backend: the mode can be chosen
  # and every verb it is asked is refused by name, with nothing sent anywhere
  # and the profile left standing.
  test "every action on the app's pane is refused as host_unavailable" do
    pid = start_server(host_availability: usable_host())

    for action <- Browser.actions() -- ["doctor", "status", "stop"] do
      assert {:error, %Error{code: "host_unavailable"} = error} = req(pid, action),
             "`#{action}` was not refused"

      assert error.message =~ "Fermix app's browser"
    end

    assert {:ok, %{"running" => false, "profile" => "fermix"}} = req(pid, "status")
    assert {:ok, %{"stopped" => true}} = req(pid, "stop")
    assert Process.alive?(pid)
  end

  test "the server refuses WebMCP on the app's pane before the backend is asked" do
    pid = start_server(backend: UpBackend, test_pid: self())

    assert {:error, %Error{code: "unsupported_in_fermix_app"} = error} = req(pid, "webmcp")
    assert error.message =~ "snapshot"
    refute_received {:backend_asked, :webmcp}

    assert {:ok, _} = req(pid, "snapshot")
    assert_received {:backend_asked, :snapshot}
  end

  # ── a pane that goes away mid-task ──────────────────────────────────────────

  test "a pane whose app went away answers host_lost with the reason and is reaped" do
    host = usable_host()
    pid = start_server(host_availability: host)
    ref = Process.monitor(pid)

    assert {:error, %Error{code: "host_unavailable"}} = req(pid, "snapshot")

    :ok = HostAvailability.detached(host, "the app quit")

    assert {:error, %Error{code: "host_lost", message: message}} = req(pid, "snapshot")
    assert message == "The Fermix app's browser is no longer available: the app quit."
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end

  test "a pane the app reports unavailable is lost with the app's own reason" do
    host = usable_host()
    pid = start_server(host_availability: host)

    :ok = HostAvailability.report(host, false, "the pane was closed")

    assert {:error, %Error{code: "host_lost", message: message}} = req(pid, "tabs")
    assert message =~ "no longer available: the pane was closed"
  end

  test "a pane with no host at all is lost before it starts" do
    host = start_supervised!({HostAvailability, name: nil}, id: make_ref())
    pid = start_server(host_availability: host)

    assert {:error, %Error{code: "host_lost", message: message}} = req(pid, "start")
    assert message =~ "nothing in this engine serves it"
  end

  # The reap answers the request that met it; a request queued behind it sees
  # the server's exit, which the manager reads as "never ran" and re-sends to a
  # fresh profile of the SAME mode — so it meets the same lost pane, never a
  # Chrome it was not started on.
  test "requests racing a reaped pane all answer host_lost, and none reaches Chrome" do
    host = usable_host()
    :ok = HostAvailability.detached(host, "the app quit")
    {manager, registry} = pane_manager(host)
    {:ok, config} = Config.current(%{})
    request = %{action: "act", args: %{"kind" => "click"}, context: %{}, mutating: true}

    results =
      1..3
      |> Enum.map(fn _ ->
        Task.async(fn ->
          ProfileManager.dispatch("owner-race", "fermix", @pane, config, request,
            registry: registry,
            server: manager
          )
        end)
      end)
      |> Task.await_many(5_000)

    for result <- results do
      assert {:error, %Error{code: "host_lost"}} = result
    end
  end

  defp pane_manager(host) do
    suffix = System.unique_integer([:positive])
    registry = Module.concat(__MODULE__, "Registry#{suffix}")
    dynamic = Module.concat(__MODULE__, "Dyn#{suffix}")
    manager = Module.concat(__MODULE__, "Mgr#{suffix}")

    start_supervised!({Registry, keys: :unique, name: registry}, id: registry)
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: dynamic}, id: dynamic)

    start_supervised!(
      {ProfileManager,
       name: manager,
       registry: registry,
       dynamic_supervisor: dynamic,
       child_opts: [host_availability: host, launcher: NoChrome]},
      id: manager
    )

    {manager, registry}
  end
end
