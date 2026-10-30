defmodule FermixChannels.Desktop.ManageTest do
  @moduledoc """
  Management forwarding end to end (M75 §6, B12): the desktop app's request
  on the desktop engine's own `daemon.sock` (a real `Fermix.CLI.Daemon` in the
  device role with its desktop link), its owner placement and placement
  there, the relay and its Noise session to the primary's real
  `Mobile.Session`, the primary's desktop peer and its `manage` family, and
  the primary's own `Fermix.CLI.Daemon`, whose router answers as its
  `daemon.sock` would.

  Both daemons run in this VM under the test's own sockets and names. Stood
  in for: the dial (the bridge socket), the trust store's row, each daemon's
  settings reader (so the answer says which engine read it) and the phone
  channel's pairing provider.
  """

  use ExUnit.Case, async: true

  alias Fermix.CLI.Daemon
  alias Fermix.CLI.Daemon.Client
  alias FermixChannels.Desktop.Manage
  alias FermixChannels.Desktop.Peer
  alias FermixChannels.Desktop.Relay
  alias FermixChannels.Test.DesktopRail
  alias FermixTestSupport.ParentProcess

  @reply_ms 15_000

  # The phone channel's pairing decision, on the primary: reported to the
  # test that started it.
  defmodule PairProvider do
    @moduledoc false
    def pair_decide(session_id, approved, opts) do
      send(Keyword.fetch!(opts, :test), {:pair_decided, session_id, approved})
      {:error, :unknown_pairing_session}
    end
  end

  setup do
    test = self()
    task_supervisor = start_supervised!({Task.Supervisor, []}, id: :daemon_tasks)
    primary_daemon = start_daemon!(:primary, task_supervisor, [])
    {:ok, gate} = Agent.start_link(fn -> :open end)

    serve = fn frame, device_id ->
      %{"method" => method} = Jason.decode!(frame)
      send(test, {:served, method, self()})
      wait_gate(gate)
      Daemon.serve_forwarded(frame, device_id, primary_daemon)
    end

    primary =
      DesktopRail.primary!(
        families: %{manage: {Manage, serve: serve, task_supervisor: task_supervisor}}
      )

    root = DesktopRail.desktop_home!(primary)
    relay = DesktopRail.start_relay!(root, primary)
    DesktopRail.await_connected(relay)

    device_socket =
      start_daemon!(:device, task_supervisor,
        desktop_link?: true,
        forward: &Relay.forward(relay, &1, &2)
      )

    %{primary: primary, relay: relay, socket: device_socket, gate: gate, tasks: task_supervisor}
  end

  test "a primary-class request is answered by the primary", ctx do
    assert {:ok, %{"engine" => "primary", "section" => "providers.openai"}} =
             request(ctx, "settings.get", %{"section" => "providers.openai"})

    assert_receive {:served, "settings.get", _task}

    assert {:ok, %{"source" => "catalog", "models" => [_ | _]}} =
             request(ctx, "providers.models.list", %{"provider" => "anthropic", "live" => false})

    assert_receive {:served, "providers.models.list", _task}
  end

  test "a device-class request is answered here, and never reaches the primary", ctx do
    assert {:ok, %{"engine" => "device", "section" => "sandbox"}} =
             request(ctx, "settings.get", %{"section" => "sandbox"})

    assert {:ok, %{"protocol" => %{"current_version" => 2}}} = request(ctx, "hello", %{})
    refute_received {:served, _method, _task}
  end

  test "an owner decision is forwarded once this engine placed its caller as the owner", ctx do
    assert {:error, {:management_error, "unknown_pairing_session", _message, _details}} =
             request(ctx, "mobile.pair.decide", %{"session_id" => "pair-1", "approved" => true})

    assert_receive {:served, "mobile.pair.decide", _task}
    assert_receive {:pair_decided, "pair-1", true}
  end

  test "an owner decision from a process this engine started is refused here", ctx do
    socket =
      start_daemon!(:device, ctx.tasks,
        desktop_link?: true,
        forward: &Relay.forward(ctx.relay, &1, &2),
        daemon_os_pid: ParentProcess.os_pid()
      )

    assert {:error, {:management_error, "unavailable", _message, %{"capability" => "mobile"}}} =
             Client.request_v1(
               "mobile.pair.decide",
               %{"session_id" => "pair-1", "approved" => true},
               socket_path: socket,
               timeout: @reply_ms
             )

    refute_received {:served, _method, _task}
    refute_received {:pair_decided, _session, _approved}
  end

  test "a device-class request that reaches the primary is refused there by name", ctx do
    request = %{request_id: "r-1", protocol_version: 2, method: "hello", params: %{}}

    assert {:error, :device_class_method, %{"method" => "hello", "sentence" => sentence}} =
             Relay.forward(ctx.relay, request)

    assert sentence =~ "configures the computer it came from"
  end

  test "the relay keeps 8 calls in flight and sends the next as one is answered", ctx do
    Agent.update(ctx.gate, fn _ -> :closed end)

    # One at a time, each taken by the relay before the next is made.
    callers =
      for n <- 1..9 do
        caller =
          Task.async(fn ->
            request(ctx, "settings.get", %{"section" => "providers.openai"}, "r-#{n}")
          end)

        assert_receive {:scheduled, {:relay_timer, {:call, _call_id}, _token}, 8_000}, @reply_ms
        caller
      end

    served = for _n <- 1..8, do: served()
    refute_received {:served, _method, _task}

    # The first answer frees a place, and the ninth call takes it.
    Agent.update(ctx.gate, fn _ -> :open end)
    send(hd(served), :go)
    assert_receive {:served, "settings.get", _ninth}, @reply_ms
    Enum.each(tl(served), &send(&1, :go))

    for caller <- callers,
        do: assert({:ok, %{"engine" => "primary"}} = Task.await(caller, @reply_ms))
  end

  describe "the primary's manage family" do
    test "holds at most 8 calls of one desktop, and refuses a ninth as busy" do
      test = self()
      task_supervisor = start_supervised!({Task.Supervisor, []}, id: :family_tasks)
      registry = :"manage_family_peers_#{System.unique_integer([:positive])}"
      start_supervised!({Registry, keys: :unique, name: registry})

      serve = fn frame, _device_id ->
        send(test, {:serving, self()})
        receive do: (:go -> :ok)
        %{"request_id" => id} = Jason.decode!(frame)
        %{"request_id" => id, "result" => %{}}
      end

      {:ok, peer} =
        Peer.start_link(
          device_id: DesktopRail.device_id(),
          session: test,
          registry: registry,
          families: %{manage: {Manage, serve: serve, task_supervisor: task_supervisor}}
        )

      for n <- 1..9, do: assert(:ok = Peer.deliver(peer, manage("c-#{n}")))

      servers = for _n <- 1..8, do: serving()
      assert_receive {:mobile_event, %{"t" => "manage_result", "call_id" => "c-9"} = busy}
      assert %{"error" => %{"code" => "busy"}} = Jason.decode!(busy["bytes"])

      Enum.each(servers, &send(&1, :go))

      for n <- 1..8 do
        id = "c-#{n}"
        assert_receive {:mobile_event, %{"t" => "manage_result", "call_id" => ^id}}
      end

      assert Manage.max_in_flight() == 8
    end
  end

  defp served do
    assert_receive {:served, "settings.get", task}, @reply_ms
    task
  end

  defp serving do
    assert_receive {:serving, server}
    server
  end

  # -- daemons -----------------------------------------------------------------------

  defp start_daemon!(engine, task_supervisor, opts) do
    # Short: the socket's path must fit a Unix socket address.
    socket_path = Path.join(DesktopRail.root!("fx-dm"), "d.sock")
    name = :"desktop_manage_daemon_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Daemon,
       [
         name: name,
         socket_path: socket_path,
         task_supervisor: task_supervisor,
         management_opts: management_opts(engine)
       ] ++ Keyword.put_new(opts, :desktop_link?, false)},
      id: name
    )

    if engine == :primary, do: name, else: socket_path
  end

  defp management_opts(engine) do
    test = self()

    [
      engine_role:
        if(engine == :primary,
          do: %{role: :primary, primary: nil},
          else: %{role: :device, primary: "fermix-vm"}
        ),
      settings_reader: fn section, _opts ->
        {:ok, %{"section" => section, "engine" => Atom.to_string(engine)}}
      end,
      identity_provider: fn -> {:ok, identity()} end,
      endpoint_opts: [port: 4041],
      operation_opts: [mobile: [provider: PairProvider, test: test]]
    ]
  end

  defp identity do
    %{
      "engine_id" => "fermix-engine-test",
      "product_version" => "1.2.3",
      "build_id" => nil,
      "source_commit" => nil,
      "distribution_identity" => "standalone",
      "artifact_target" => nil,
      "architecture" => "arm64",
      "pid" => "4321"
    }
  end

  defp request(ctx, method, params, request_id \\ "r-1") do
    Client.request_v1(method, params,
      request_id: request_id,
      socket_path: ctx.socket,
      timeout: @reply_ms
    )
  end

  # A forwarded call waits here while the test holds the gate closed.
  defp wait_gate(gate) do
    if Agent.get(gate, & &1) == :closed do
      receive do: (:go -> :ok)
    end

    :ok
  end

  defp manage(call_id) do
    %{
      type: "manage",
      payload: %{
        "call_id" => call_id,
        "method" => "settings.get",
        "protocol_version" => 2,
        "index" => 0,
        "last" => true
      },
      bytes: ~s({"section":"providers.openai"})
    }
  end
end
