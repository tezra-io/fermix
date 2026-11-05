defmodule FermixChannels.Mobile.Iroh.HelperTest do
  # Iroh.Helper against a fake fermix-iroh: a small Perl script that speaks the
  # helper contract and writes every op it reads to a log the test inspects.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias FermixChannels.Mobile.Iroh.Bridge
  alias FermixChannels.Mobile.Iroh.Helper
  alias FermixChannels.Mobile.Iroh.HelperProtocol
  alias FermixChannels.Mobile.Iroh.Relays.Source

  @moduletag :tmp_dir
  @fixture_id "79b5562e8fe654f94078b112e8a98ba7901f853ae695bed7e0e3910bad049664"
  @us1 %{url: "https://us1.relay.fermix.ai/", quic_port: 7842}
  @eu1 %{url: "https://eu1.relay.fermix.ai/", quic_port: 7842}
  @ap1 %{url: "https://ap1.relay.fermix.ai/", quic_port: 7842}
  # What the fake says is a Perl process's work, which on a loaded runner takes
  # longer than the suite's 2 s; the rail itself gives a helper 10 s to start.
  # Every wait on the fake, its state or its telemetry, takes this bound.
  @helper_ms 10_000
  @poll_ms 20

  setup %{tmp_dir: root} do
    mobile = Path.join(root, "mobile")
    File.mkdir_p!(mobile)
    File.chmod!(mobile, 0o700)
    key = Path.join(mobile, "iroh_key")
    File.write!(key, :binary.list_to_bin(Enum.to_list(1..32)))
    File.chmod!(key, 0o600)
    %{root: root, log: Path.join(root, "ops.log")}
  end

  # A fake helper: `hello` with the given fields, then after `start` whatever
  # `after_start` prints; every op it reads goes to the log; `shutdown` or EOF
  # ends it with 0.
  defp fake(ctx, opts \\ []) do
    hello =
      Jason.encode!(%{
        "event" => "hello",
        "protocol_version" =>
          Keyword.get(opts, :protocol_version, HelperProtocol.protocol_version()),
        "helper_version" => "0.1.0",
        "iroh_version" => Keyword.get(opts, :iroh_version, "1.3.0")
      })

    after_start =
      Keyword.get(opts, :after_start, [
        ~s({"event":"ready","endpoint_id":"#{@fixture_id}"}),
        ~s({"event":"relay","home_relay":"https://us1.relay.fermix.ai/","connected":true})
      ])

    exit_after_hello = Keyword.get(opts, :exit_after_hello)
    exit_after_start = Keyword.get(opts, :exit_after_start)
    close_stdin_before_hello = Keyword.get(opts, :close_stdin_before_hello, false)

    script = """
    #!/usr/bin/perl
    use strict; use warnings;
    $| = 1;
    open(my $log, '>>', q{#{ctx.log}}) or die;
    $log->autoflush(1);
    open(my $env, '>', q{#{ctx.root}/env.txt}) or die;
    print $env join(",", sort keys %ENV);
    close($env);
    #{if close_stdin_before_hello, do: "close(STDIN);", else: ""}
    print '#{hello}' . "\\n";
    #{if exit_after_hello, do: "exit #{exit_after_hello};", else: ""}
    #{if close_stdin_before_hello, do: "sleep 5; exit 0;", else: ""}
    while (my $line = <STDIN>) {
      print $log $line;
      if ($line =~ /"op":"start"/) {
        #{Enum.map_join(after_start, "\n", &"print '#{&1}' . \"\\n\";")}
        #{if exit_after_start, do: "exit #{exit_after_start};", else: ""}
      }
      exit 0 if $line =~ /"op":"shutdown"/;
    }
    exit 0;
    """

    path = Path.join(ctx.root, "fermix-iroh")
    File.write!(path, script)
    File.chmod!(path, 0o755)
    path
  end

  defp start(ctx, opts) do
    defaults = [
      name: nil,
      root: ctx.root,
      bridge_socket: Path.join(ctx.root, "mobile/bridge.sock"),
      os_type: {:unix, :linux},
      identity_exists?: fn -> true end,
      list_devices: fn _store -> {:ok, []} end,
      emit: fn status, failures, class ->
        send(self_pid(opts), {:emit, status, failures, class})
        :ok
      end
    ]

    {:ok, pid} = Helper.start_link(Keyword.merge(defaults, opts))
    pid
  end

  defp self_pid(opts), do: Keyword.get(opts, :test_pid, self())

  defp await_state(pid, state, attempts \\ div(@helper_ms, @poll_ms)) do
    case Helper.status(pid) do
      %{state: ^state} = status ->
        status

      other when attempts > 0 ->
        Process.sleep(@poll_ms)

        if attempts == 1,
          do: flunk("rail stayed #{inspect(other)}"),
          else: await_state(pid, state, attempts - 1)
    end
  end

  # The rail's retry timer, delivered by hand once it has failed `failures`
  # times, rather than waited for.
  defp retry_now(pid, failures) do
    state = await_failures(pid, failures)
    send(pid, {:retry, state.retry.token})
  end

  defp await_failures(pid, failures, attempts \\ div(@helper_ms, @poll_ms)) do
    state = :sys.get_state(pid)

    cond do
      state.rail == :failed and state.failures >= failures and state.retry.token != nil ->
        state

      attempts == 0 ->
        flunk("the rail did not fail #{failures} times: #{inspect(state.rail)}")

      true ->
        # sleep: polls a state the rail announces to no one
        Process.sleep(@poll_ms)
        await_failures(pid, failures, attempts - 1)
    end
  end

  defp ops(ctx) do
    ctx.log |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  end

  test "a source build without the helper reports it missing and offers no candidate", ctx do
    pid = start(ctx, binary_path: Path.join(ctx.root, "absent"))

    assert %{state: :helper_missing, helper_path: path} = await_state(pid, :helper_missing)
    assert path == Path.join(ctx.root, "absent")
    assert Helper.candidate(pid) == :none
  end

  test "a home with no phone identity stays dormant until the first pairing window", ctx do
    pid = start(ctx, binary_path: fake(ctx), identity_exists?: fn -> false end, test_pid: self())

    assert %{state: :dormant} = Helper.status(pid)
    assert :ok = Helper.activate(pid)
    assert %{state: :ready} = await_state(pid, :ready)
  end

  test "hello, start, ready: the helper gets the key, the bridge, the relays and the limits",
       ctx do
    pid = start(ctx, binary_path: fake(ctx), test_pid: self())

    assert %{state: :ready, endpoint_id: @fixture_id, connected: true} = await_state(pid, :ready)

    assert [%{"op" => "start"} = start] = ops(ctx)
    assert start["secret_key_path"] == Path.join(ctx.root, "mobile/iroh_key")
    assert start["bridge_socket"] == Path.join(ctx.root, "mobile/bridge.sock")
    assert start["alpn"] == "fermix/mobile/1"

    assert start["relays"] == [%{"url" => @us1.url, "quic_port" => 7842}]

    # The helper's cap is the rail's outer bound: far above the bridge's 64, so
    # silent connections fill the bridge, where a phone can still get a place,
    # long before they fill the helper, where it cannot (`Iroh.Bridge`).
    assert start["limits"]["max_connections"] == 1_024
    assert start["limits"]["max_connections"] > 4 * Bridge.max_connections()

    assert {:ok, %{"kind" => "iroh", "node_id" => @fixture_id, "relays_rev" => rev}} =
             Helper.candidate(pid)

    assert rev =~ ~r/\A[0-9a-f]{16}\z/
  end

  # An Always On server's endpoint binds its fixed port; every other binds
  # iroh's own, so its start names none.
  test "a start names the fixed port only when the rail was given one", ctx do
    pid = start(ctx, binary_path: fake(ctx), test_pid: self())
    await_state(pid, :ready)
    assert [%{"op" => "start"} = start] = ops(ctx)
    refute Map.has_key?(start, "bind_port")
    GenServer.stop(pid)

    pid = start(ctx, binary_path: fake(ctx), test_pid: self(), bind_port: 4100)
    await_state(pid, :ready)
    # The second helper's start follows the first's in the same log.
    assert %{"op" => "start", "bind_port" => 4100} =
             ops(ctx) |> Enum.filter(&(&1["op"] == "start")) |> List.last()
  end

  test "the hints are this machine's tailnet addresses at the fixed port, read when asked",
       ctx do
    {:ok, reads} = Agent.start_link(fn -> 0 end)

    interfaces = fn ->
      Agent.update(reads, &(&1 + 1))

      {:ok,
       [
         {~c"en0", [flags: [:up, :running], addr: {192, 168, 1, 9}]},
         {~c"tailscale0",
          [
            flags: [:up, :running],
            addr: {100, 90, 8, 7},
            addr: {0xFD7A, 0x115C, 0xA1E0, 0, 0, 0, 0, 2}
          ]}
       ]}
    end

    pid = start(ctx, binary_path: fake(ctx), bind_port: 4100, interfaces: interfaces)
    await_state(pid, :ready)

    assert Helper.hints(pid) == ["100.90.8.7:4100", "[fd7a:115c:a1e0::2]:4100"]
    assert Helper.hints(pid) == ["100.90.8.7:4100", "[fd7a:115c:a1e0::2]:4100"]
    assert Agent.get(reads, & &1) == 2

    # A rail that binds iroh's own port has no address worth recording.
    GenServer.stop(pid)
    pid = start(ctx, binary_path: fake(ctx), interfaces: interfaces)
    await_state(pid, :ready)
    assert Helper.hints(pid) == []
    assert Agent.get(reads, & &1) == 2

    # Nor has one that is not ready, or not running.
    assert Helper.hints(:no_rail_here) == []
  end

  # An Always On server whose fixed port another process holds: the helper
  # says `bind_failed` and exits, every time. The rail retries on its backoff,
  # never a spin, says the failure once for the run of it, and its status
  # names the port until the port is free.
  test "a fixed port another process holds is retried on the backoff and said once", ctx do
    taken =
      Jason.encode!(%{
        "event" => "error",
        "code" => "bind_failed",
        "message" =>
          "UDP port 4033 could not be bound: Failed to bind sockets: Address already in use " <>
            "[os error 48]"
      })

    binary = fake(ctx, after_start: [taken], exit_after_start: 1)

    log =
      capture_log(fn ->
        pid = start(ctx, binary_path: binary, bind_port: 4033, test_pid: self())
        assert_receive {:emit, :degraded, 1, :helper_error}, @helper_ms

        for failures <- 1..5, do: retry_now(pid, failures)
        state = await_failures(pid, 6)

        assert state.retry.delay_ms == min(1_000 * Integer.pow(2, state.failures), 60_000)
        assert %{state: :failed, failure: failure} = Helper.status(pid)
        assert failure =~ "bind_failed: UDP port 4033 could not be bound"
        refute_received {:emit, :degraded, 2, _class}
        GenServer.stop(pid)
      end)

    assert length(String.split(log, "UDP port 4033 could not be bound")) == 2
  end

  test "a helper that disagrees with this build fails without retrying", ctx do
    for {opts, words} <- [
          {[protocol_version: 1], "protocol 1"},
          {[iroh_version: "1.2.0"], "iroh 1.2.0"},
          {[after_start: [~s({"event":"ready","endpoint_id":"#{String.duplicate("a", 64)}"})]],
           "reported endpoint"}
        ] do
      pid = start(ctx, binary_path: fake(ctx, opts), test_pid: self())
      assert %{state: :failed, failure: failure} = await_state(pid, :failed)
      assert failure =~ words
      assert_receive {:emit, :degraded, 1, _class}
      assert :sys.get_state(pid).retry == nil
      GenServer.stop(pid)
    end
  end

  test "a helper that crashes is retried, and a crash never stops the rail", ctx do
    pid = start(ctx, binary_path: fake(ctx, exit_after_hello: 3), test_pid: self())

    # The first failure's telemetry, not a poll: a poll can land after the
    # one-second retry has already failed again.
    assert_receive {:emit, :degraded, 1, _class}, @helper_ms
    assert %{rail: :failed, failure: failure, retry: %{delay_ms: 2_000}} = :sys.get_state(pid)
    # Dying right after `hello` can also surface as the daemon's `start` write
    # failing on the closed pipe, whichever the OS reports first.
    assert failure =~ "exited with status 3" or failure =~ "did not answer" or
             failure =~ "pipe closed"

    assert Process.alive?(pid)
  end

  # The failure is said where the owner reads it (Doctor, the app's status), so
  # it is a sentence, never an Elixir term.
  test "an iroh key the rail cannot use fails it in words, without retrying", ctx do
    key = Path.join(ctx.root, "mobile/iroh_key")
    File.chmod!(key, 0o644)
    pid = start(ctx, binary_path: fake(ctx), test_pid: self())

    assert %{state: :failed, failure: failure} = await_state(pid, :failed)
    assert failure == "the iroh key #{key} is mode 0644; it must be 0600"
    assert :sys.get_state(pid).retry == nil
  end

  test "a line the rail cannot read is said in words and retried", ctx do
    pid = start(ctx, binary_path: fake(ctx, after_start: ["not json"]), test_pid: self())

    assert %{state: :failed, failure: failure} = await_state(pid, :failed)
    assert failure == "the helper sent a line that is not JSON"
    assert %{retry: %{delay_ms: 2_000}} = :sys.get_state(pid)
  end

  test "a helper file that cannot be run is said with its path", ctx do
    path = fake(ctx)
    File.chmod!(path, 0o644)
    pid = start(ctx, binary_path: path, test_pid: self())

    assert %{state: :failed, failure: failure} = await_state(pid, :failed)
    assert failure == "the helper at #{path} could not be started"
  end

  # A helper that reaches ready and then dies has not run: the backoff goes on
  # from where it was, so a crash loop slows to once a minute and gives up a
  # day after the rail last ran (M62 §3), instead of restarting every second.
  test "a helper that dies soon after ready keeps backing off", ctx do
    pid = start(ctx, binary_path: fake(ctx, exit_after_start: 101), test_pid: self())

    assert_receive {:emit, :degraded, 1, :exited}, @helper_ms
    assert %{retry: %{delay_ms: 2_000}} = :sys.get_state(pid)

    assert_receive {:emit, :recovered, 0, :none}, @helper_ms
    assert_receive {:emit, :degraded, 1, :exited}, @helper_ms
    assert %{retry: %{delay_ms: 4_000}} = :sys.get_state(pid)
  end

  # A helper that has stopped reading when `start` is written closes the port
  # with no exit status (the write's EPIPE): that is a crash like any other,
  # not a wait for the ready timeout. The fake closes its input before `hello`,
  # and the daemon writes `start` only after reading `hello`, so the write
  # always meets a closed pipe.
  test "a helper whose pipe closed under the daemon's write is a crash", ctx do
    pid = start(ctx, binary_path: fake(ctx, close_stdin_before_hello: true), test_pid: self())

    assert_receive {:emit, :degraded, 1, :port_closed}, @helper_ms

    assert %{
             rail: :failed,
             failure: "the helper's pipe closed: broken pipe",
             retry: %{delay_ms: 2_000}
           } = :sys.get_state(pid)
  end

  # `bad_request` is the helper refusing the daemon's own `start`: the same
  # `start` would be refused again.
  test "a start the helper refuses as a bad request is not retried", ctx do
    refusal = ~s({"event":"error","code":"bad_request","message":"duplicate relay"})
    pid = start(ctx, binary_path: fake(ctx, after_start: [refusal]), test_pid: self())

    assert %{state: :failed, failure: "bad_request: duplicate relay"} = await_state(pid, :failed)
    assert :sys.get_state(pid).retry == nil
  end

  # The helper needs nothing from the daemon's environment, which may carry
  # secrets: it starts with every inherited variable unset.
  test "the helper inherits none of the daemon's environment", ctx do
    pid = start(ctx, binary_path: fake(ctx), test_pid: self())
    await_state(pid, :ready)

    assert File.read!(Path.join(ctx.root, "env.txt")) == ""
  end

  # A paired-phone list that cannot be read is a failure, never the launch
  # relays in its place (Code Rule 12).
  test "a paired-phone list that cannot be read fails the start", ctx do
    pid =
      start(ctx,
        binary_path: fake(ctx),
        list_devices: fn _store -> {:error, :eacces} end,
        test_pid: self()
      )

    assert %{state: :failed, failure: failure} = await_state(pid, :failed)
    assert failure == "the paired phones could not be read: permission denied"
  end

  test "a bridge that is not listening fails the rail before a helper starts", ctx do
    pid = start(ctx, binary_path: fake(ctx), bridge: :no_such_bridge)

    assert %{state: :failed, failure: "the bridge socket is not listening"} =
             await_state(pid, :failed)

    refute File.exists?(ctx.log)
  end

  test "paths, closes and refusals are counted, and the per-peer map forgets a closed peer",
       ctx do
    after_start = [
      ~s({"event":"ready","endpoint_id":"#{@fixture_id}"}),
      ~s({"event":"path","endpoint_id":"#{String.duplicate("b", 64)}","kind":"direct","relay":null}),
      ~s({"event":"closed","endpoint_id":"#{String.duplicate("b", 64)}"}),
      ~s({"event":"refused","reason":"busy","endpoint_id":null}),
      ~s({"event":"refused","reason":"bridge_unreachable","endpoint_id":"#{String.duplicate("c", 64)}"})
    ]

    pid = start(ctx, binary_path: fake(ctx, after_start: after_start), test_pid: self())
    await_state(pid, :ready)
    Process.sleep(100)

    assert %{refused: %{busy: 1, bridge_unreachable: 1, alpn: 0}} = Helper.status(pid)
    assert :sys.get_state(pid).paths == %{}
  end

  # M62 §7: a flood of refusals is counted, and said in the log at 1, 10, 100…
  # of each reason, never once per refusal.
  test "refusals are warned about at each power of ten, per reason", ctx do
    busy = ~s({"event":"refused","reason":"busy","endpoint_id":null})

    after_start = [
      ~s({"event":"ready","endpoint_id":"#{@fixture_id}"}) | List.duplicate(busy, 12)
    ]

    log =
      capture_log(fn ->
        pid = start(ctx, binary_path: fake(ctx, after_start: after_start), test_pid: self())
        await_state(pid, :ready)
        Process.sleep(100)
        assert %{refused: %{busy: 12}} = Helper.status(pid)
        GenServer.stop(pid)
      end)

    assert log =~ "fermix-iroh turned away 1 remote connection (busy)"
    assert log =~ "fermix-iroh turned away 10 remote connections (busy)"
    assert length(String.split(log, "turned away")) == 3
  end

  test "a phone acknowledging a new relay list widens the helper's relays", ctx do
    revisions =
      Source.parse!(%{
        "revisions" => [
          %{"iroh" => "1.3.0", "relays" => [wire(@us1), wire(@eu1)]},
          %{"iroh" => "1.3.0", "relays" => [wire(@us1), wire(@eu1), wire(@ap1)]}
        ]
      })

    [_launch, added] = Enum.map(revisions, & &1.id)
    devices = :counters.new(1, [])

    list_devices = fn _store ->
      rev = if :counters.get(devices, 1) == 1, do: added, else: nil
      {:ok, [%{relay_list_rev: rev}]}
    end

    pid =
      start(ctx,
        binary_path: fake(ctx),
        revisions: revisions,
        list_devices: list_devices,
        test_pid: self()
      )

    await_state(pid, :ready)
    :counters.put(devices, 1, 1)
    :ok = Helper.relays_acknowledged(pid)
    Process.sleep(100)

    assert [%{"op" => "start"} = start, %{"op" => "set_relays", "relays" => relays}] = ops(ctx)
    assert length(start["relays"]) == 2
    assert Enum.map(relays, & &1["url"]) == [@us1.url, @eu1.url, @ap1.url]
  end

  test "a peer whose session failed is closed at a ready helper", ctx do
    pid = start(ctx, binary_path: fake(ctx), test_pid: self())
    await_state(pid, :ready)

    assert :ok = Helper.close(pid, @fixture_id)
    :ok = GenServer.stop(pid)

    assert [
             %{"op" => "start"},
             %{"op" => "close", "endpoint_id" => @fixture_id},
             %{"op" => "shutdown"}
           ] = ops(ctx)
  end

  # No helper holds a connection before it is ready, so there is nothing to close.
  test "a close before the helper is ready is not sent", ctx do
    pid = start(ctx, binary_path: fake(ctx, after_start: []), test_pid: self())

    assert :ok = Helper.close(pid, @fixture_id)
    assert %{state: :starting} = Helper.status(pid)
    :ok = GenServer.stop(pid)

    refute Enum.any?(ops(ctx), &(&1["op"] == "close"))
  end

  test "stopping the rail shuts the helper down", ctx do
    pid = start(ctx, binary_path: fake(ctx), test_pid: self())
    await_state(pid, :ready)

    :ok = GenServer.stop(pid)
    assert [%{"op" => "start"}, %{"op" => "shutdown"}] = ops(ctx)
  end

  test "an absent rail answers reads as off and never exits the caller" do
    assert Helper.status(:no_rail_here) == %{state: :off}
    assert Helper.candidate(:no_rail_here) == :none
    assert :ok = Helper.activate(:no_rail_here)
    assert :ok = Helper.relays_acknowledged(:no_rail_here)
    assert :ok = Helper.close(:no_rail_here, @fixture_id)
    assert_raise ArgumentError, fn -> Helper.close(:no_rail_here, "79B5") end
  end

  test "macOS spawns through the disclaim shim and refuses without one" do
    assert {:ok, {"/shim", ["/bin/fermix-iroh"]}} =
             Helper.spawn_plan("/bin/fermix-iroh", {:unix, :darwin}, "/shim")

    assert {:error, {:disclaim_shim_missing, _message}} =
             Helper.spawn_plan("/bin/fermix-iroh", {:unix, :darwin}, nil)

    assert {:ok, {"/bin/fermix-iroh", []}} =
             Helper.spawn_plan("/bin/fermix-iroh", {:unix, :linux}, nil)
  end

  defp wire(relay), do: %{"url" => relay.url, "quic_port" => relay.quic_port}
end
