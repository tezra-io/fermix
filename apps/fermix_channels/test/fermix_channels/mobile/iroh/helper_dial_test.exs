defmodule FermixChannels.Mobile.Iroh.HelperDialTest do
  # Iroh.Helper's protocol 3 (M75 §4.1) against a fake fermix-iroh: the
  # endpoint that only dials, and `Helper.dial/3`'s socket from reservation to
  # cleanup. The fake is a small Perl script that speaks the helper contract,
  # logs every op it reads, and answers a `dial` as the test asks: connect to
  # the dial's socket, say something on it, then `dialed` and `dial_closed`;
  # `dial_failed`; nothing; or exit.
  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.Iroh.Helper
  alias FermixChannels.Mobile.Iroh.HelperProtocol
  alias FermixChannels.Mobile.Iroh.Relays
  alias FermixTestSupport.SafeRm

  @fixture_id "79b5562e8fe654f94078b112e8a98ba7901f853ae695bed7e0e3910bad049664"
  @peer "2f1b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f809"
  @relays [%{"url" => "https://relay.invalid/", "quic_port" => 7842}]
  @target %{node_id: @peer, relays: @relays}

  setup do
    # Short: a dial socket's path must fit a Unix socket address.
    root = Path.join(System.tmp_dir!(), "fx-hd-#{System.unique_integer([:positive])}")
    SafeRm.mark!(root)
    on_exit(fn -> SafeRm.rm_rf!(root) end)
    %{root: root, log: Path.join(root, "ops.log")}
  end

  defp fake(ctx, on_dial) do
    dial =
      case on_dial do
        :connect ->
          """
          my $c = IO::Socket::UNIX->new(Type => SOCK_STREAM(), Peer => $sock) or die "connect: $!";
          print $c "from the peer";
          print '{"event":"dialed","dial_id":"' . $id . '","kind":"direct","relay":null}' . "\\n";
          close($c);
          print '{"event":"dial_closed","dial_id":"' . $id . '"}' . "\\n";
          """

        {:fail, reason} ->
          ~s(print '{"event":"dial_failed","dial_id":"' . $id . '","reason":"#{reason}"}' . "\\n";)

        :silent ->
          ""

        :exit ->
          "exit 1;"
      end

    script = """
    #!/usr/bin/perl
    use strict; use warnings;
    use IO::Socket::UNIX;
    $| = 1;
    open(my $log, '>>', q{#{ctx.log}}) or die;
    $log->autoflush(1);
    print '{"event":"hello","protocol_version":#{HelperProtocol.protocol_version()},"helper_version":"0.3.0","iroh_version":"1.3.0"}' . "\\n";
    while (my $line = <STDIN>) {
      print $log $line;
      if ($line =~ /"op":"start"/) {
        print '{"event":"ready","endpoint_id":"#{@fixture_id}"}' . "\\n";
      }
      if ($line =~ /"op":"dial"/) {
        my ($id) = $line =~ /"dial_id":"([^"]+)"/;
        my ($sock) = $line =~ /"socket":"([^"]+)"/;
        #{dial}
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
      mode: :dial,
      root: ctx.root,
      os_type: {:unix, :linux},
      emit: fn _status, _failures, _class -> :ok end
    ]

    start_supervised!({Helper, Keyword.merge(defaults, opts)})
  end

  # The rail's own receipt of the fake's `ready` line is the event waited on;
  # a status read after it sees the rail ready.
  defp ready(pid, _ctx) do
    1 = :erlang.trace(pid, true, [:receive])

    unless match?(%{state: :ready}, Helper.status(pid)) do
      assert_receive {:trace, ^pid, :receive, {_port, {:data, {:eol, ~s({"event":"ready") <> _}}}}
    end

    assert %{state: :ready} = Helper.status(pid)
    :erlang.trace(pid, false, [:receive])
    pid
  end

  defp ops(ctx) do
    case File.read(ctx.log) do
      {:ok, text} -> text |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
      {:error, :enoent} -> []
    end
  end

  defp dial_sockets(ctx), do: Path.wildcard(Path.join([ctx.root, "mobile", "dial-*.sock"]))

  test "an endpoint that only dials starts at once, with no key, no bridge and the current relays",
       ctx do
    pid = ctx |> start(binary_path: fake(ctx, :silent)) |> ready(ctx)

    assert [start] = ops(ctx)

    assert start ==
             HelperProtocol.start_dial_only(
               Relays.to_wire(Relays.current().relays),
               Helper.limits()
             )

    refute Map.has_key?(start, "secret_key_path") or Map.has_key?(start, "bridge_socket")

    # Its endpoint id is the helper's own; it offers phones no route.
    assert %{state: :ready, endpoint_id: @fixture_id} = Helper.status(pid)
    assert Helper.candidate(pid) == :none

    # The dial sockets' directory is made private on a home that had none.
    assert {:ok, %{type: :directory, mode: mode}} = File.lstat(Path.join(ctx.root, "mobile"))
    assert Bitwise.band(mode, 0o777) == 0o700

    # It accepts nothing, so it has no peer to close and no relays to recompute.
    assert :ok = Helper.close(pid, @fixture_id)
    assert :ok = Helper.relays_acknowledged(pid)
    assert %{state: :ready} = Helper.status(pid)
    assert [_start] = ops(ctx)
  end

  test "a dial hands the caller the helper's connection and cleans its socket up", ctx do
    pid = ctx |> start(binary_path: fake(ctx, :connect)) |> ready(ctx)

    assert {:ok, socket, %{kind: :direct, relay: nil}} = Helper.dial(pid, @target)
    assert {:ok, "from the peer"} = :gen_tcp.recv(socket, 13, 2_000)

    assert [_start, %{"op" => "dial", "dial_id" => dial_id, "socket" => path} = op] =
             ops(ctx)

    assert op == HelperProtocol.dial(dial_id, @peer, @relays, path)
    assert path == Path.join([ctx.root, "mobile", "dial-#{dial_id}.sock"])
    assert dial_id =~ ~r/\A[0-9a-f]{8}\z/
    # The listening socket is gone as soon as its one connection is taken.
    assert dial_sockets(ctx) == []

    # The helper's word that the stream ended reaches the dial's owner.
    assert_receive {:iroh_dial, ^dial_id, :closed}
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 2_000)
    assert :sys.get_state(pid).dials == %{}
  end

  test "a dial the helper refuses comes back as its reason, with nothing left behind", ctx do
    for reason <- ~w(unreachable timeout refused bridge_unreachable busy) do
      pid = ctx |> start(binary_path: fake(ctx, {:fail, reason})) |> ready(ctx)

      assert {:error, String.to_existing_atom(reason)} == Helper.dial(pid, @target)
      assert dial_sockets(ctx) == []
      assert :sys.get_state(pid).dials == %{}
      stop_supervised!(Helper)
      SafeRm.rm!(ctx.log)
    end
  end

  test "a helper that does not answer a dial is given up on, and one that dies fails it", ctx do
    pid = ctx |> start(binary_path: fake(ctx, :silent)) |> ready(ctx)

    assert {:error, :no_answer} = Helper.dial(pid, @target, wait_ms: 100)
    assert dial_sockets(ctx) == []
    assert :sys.get_state(pid).dials == %{}
    stop_supervised!(Helper)

    pid = ctx |> start(binary_path: fake(ctx, :exit)) |> ready(ctx)
    assert {:error, :helper_failed} = Helper.dial(pid, @target)
    assert dial_sockets(ctx) == []
  end

  test "a rail that is not ready dials nothing; one past its bound is busy", ctx do
    assert {:error, :not_ready} = Helper.dial(:no_rail_here, @target)

    pid = ctx |> start(binary_path: fake(ctx, :silent)) |> ready(ctx)
    test_pid = self()

    # Reservations in flight, held by a process that never sends its dial.
    holder =
      spawn_link(fn ->
        for _n <- 1..HelperProtocol.max_dials(),
            do: {:ok, _id, _path} = GenServer.call(pid, {:reserve_dial, self()})

        send(test_pid, :held)
        Process.sleep(:infinity)
      end)

    assert_receive :held
    assert {:error, :busy} = Helper.dial(pid, @target)

    # A holder that goes away gives its places back, once the rail hears it.
    1 = :erlang.trace(pid, true, [:receive])
    Process.unlink(holder)
    Process.exit(holder, :kill)

    # One monitor, and so one word, per reservation.
    for _n <- 1..HelperProtocol.max_dials(),
        do: assert_receive({:trace, ^pid, :receive, {:DOWN, _ref, :process, ^holder, :killed}})

    assert :sys.get_state(pid).dials == %{}
    assert {:error, :no_answer} = Helper.dial(pid, @target, wait_ms: 50)
  end

  test "a home whose socket path is too long is refused before the helper is asked", ctx do
    long = Path.join(ctx.root, String.duplicate("h", 120))
    File.mkdir_p!(long)
    pid = ctx |> Map.put(:root, long) |> start(binary_path: fake(ctx, :connect)) |> ready(ctx)

    assert {:error, {:socket, {:path_too_long, _bytes, _limit}}} = Helper.dial(pid, @target)
    refute Enum.any?(ops(ctx), &(&1["op"] == "dial"))
    assert :sys.get_state(pid).dials == %{}
  end
end
