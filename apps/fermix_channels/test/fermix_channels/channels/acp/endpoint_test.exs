defmodule FermixChannels.Channels.Acp.EndpointTest do
  @moduledoc """
  The UDS listener (M29 §6.1/§11): 0600 socket under FERMIX_HOME, stale-socket
  probe before unlink, a bounded connection count, and one Peer per connection.

  Also the boot-fragility contract: the ACP surface ships on by default, so a
  socket this listener cannot bind must refuse loudly and leave the daemon
  running — never take the supervision tree down with it.
  """

  use ExUnit.Case, async: false

  import Bitwise, only: [&&&: 2]
  import ExUnit.CaptureLog

  alias FermixChannels.Channels.Acp.Endpoint
  alias FermixCore.Setup.ConfigStore
  alias FermixTestSupport.SafeRm

  # A short path on purpose: a Unix socket address is capped around 104 bytes,
  # which a nested tmp directory blows straight through (`:einval` on bind).
  setup do
    socket_path =
      Path.join(System.tmp_dir!(), "fermix-acp-#{System.unique_integer([:positive])}.sock")

    on_exit(fn -> SafeRm.rm(socket_path) end)
    {:ok, socket_path: socket_path}
  end

  describe "socket lifecycle" do
    test "binds a 0600 socket at the configured path", ctx do
      start_endpoint(ctx)

      assert File.exists?(ctx.socket_path)
      assert (File.stat!(ctx.socket_path).mode &&& 0o777) == 0o600
    end

    # First run on a fresh machine: FERMIX_HOME does not exist yet. The pre-flight
    # length check measures the path string, so it cannot fail closed on the
    # directory the listener is about to create.
    test "creates a missing FERMIX_HOME and binds inside it", ctx do
      home = Path.join(short_tmp_dir!("fresh"), "home")
      path = Path.join(home, "acp.sock")
      refute File.exists?(home)

      start_endpoint(ctx, socket_path: path)

      assert File.exists?(path)
      assert (File.stat!(path).mode &&& 0o777) == 0o600
      assert {:ok, client} = connect(path)
      :gen_tcp.close(client)
    end

    test "the default path is acp.sock under FERMIX_HOME" do
      assert Path.basename(Endpoint.socket_path()) == "acp.sock"
      assert Path.dirname(Endpoint.socket_path()) == ConfigStore.fermix_home()
    end

    test "unlinks a stale socket file left by a crashed daemon", ctx do
      File.write!(ctx.socket_path, "")
      start_endpoint(ctx)

      assert {:ok, client} = connect(ctx.socket_path)
      :gen_tcp.close(client)
    end

    test "refuses to bind over a LIVE socket instead of stealing the path", ctx do
      start_endpoint(ctx)
      Process.flag(:trap_exit, true)

      log =
        capture_log(fn ->
          assert Endpoint.start_link(socket_path: ctx.socket_path, name: :acp_endpoint_second) ==
                   :ignore
        end)

      assert log =~ "another ACP daemon is already listening"
      assert log =~ ctx.socket_path

      # The live listener kept its path and is still serving.
      assert File.exists?(ctx.socket_path)
      assert {:ok, client} = connect(ctx.socket_path)
      :gen_tcp.close(client)
    end

    test "removes the socket file when the listener stops", ctx do
      start_endpoint(ctx)
      pid = Process.whereis(endpoint_name())
      assert File.exists?(ctx.socket_path)

      stop_supervised!(:acp_supervisor)
      refute Process.alive?(pid)
      refute File.exists?(ctx.socket_path)
    end
  end

  describe "refusing a socket it cannot bind" do
    test "names an over-long path instead of leaking :einval, and creates nothing" do
      # Past every platform's `sun_path` (104 bytes on macOS, 108 on Linux).
      long_path = Path.join(short_tmp_dir!("long"), String.duplicate("a", 160) <> ".sock")

      log =
        capture_log(fn ->
          assert Endpoint.start_link(socket_path: long_path, name: :acp_endpoint_long) == :ignore
        end)

      assert log =~ "ACP socket path is #{byte_size(long_path)} bytes"
      assert log =~ "FERMIX_HOME"
      assert log =~ long_path
      refute File.exists?(long_path)
    end

    test "names a permission failure on an unwritable socket directory" do
      dir = short_tmp_dir!("readonly")
      path = Path.join(dir, "acp.sock")
      on_exit(fn -> File.chmod!(dir, 0o700) end)
      File.chmod!(dir, 0o500)

      log =
        capture_log(fn ->
          assert Endpoint.start_link(socket_path: path, name: :acp_endpoint_ro) == :ignore
        end)

      assert log =~ "permission denied"
      assert log =~ path
      refute log =~ "bytes, over the"
      refute File.exists?(path)
    end

    # The property the boot-fragility defect broke: the ACP transport is an
    # optional child of the channels tree, so an unbindable socket must cost the
    # ACP surface and nothing else. Before the fix this killed the whole daemon.
    test "leaves the supervision tree and its siblings alive" do
      long_path = Path.join(short_tmp_dir!("tree"), String.duplicate("b", 160) <> ".sock")
      Process.flag(:trap_exit, true)

      capture_log(fn ->
        assert {:ok, tree} =
                 Supervisor.start_link(tree_children(long_path), strategy: :one_for_one)

        assert Process.alive?(tree)
        assert is_pid(Process.whereis(:acp_boot_sibling))
        refute Process.whereis(Endpoint)

        Supervisor.stop(tree)
      end)
    end
  end

  describe "connection cap" do
    test "refuses politely above the cap and keeps serving the accepted ones", ctx do
      start_endpoint(ctx, max_connections: 2)

      {:ok, first} = connect(ctx.socket_path)
      {:ok, second} = connect(ctx.socket_path)
      wait_until(fn -> Endpoint.connection_count(endpoint_name()) == 2 end)

      {:ok, third} = connect(ctx.socket_path)

      assert %{"fermix_bridge_ack" => %{"status" => "error", "message" => message}} =
               recv_json(third)

      assert message =~ "too many"
      assert :gen_tcp.recv(third, 0, 1_000) == {:error, :closed}

      # The two accepted connections are untouched by the refusal.
      assert :ok = send_json(first, %{"fermix_bridge" => 1, "app_version" => "t", "env" => %{}})
      assert %{"fermix_bridge_ack" => %{"status" => "ok"}} = recv_json(first)
      :gen_tcp.close(second)
    end

    test "a closed connection frees its slot", ctx do
      start_endpoint(ctx, max_connections: 1)

      {:ok, first} = connect(ctx.socket_path)
      wait_until(fn -> Endpoint.connection_count(endpoint_name()) == 1 end)
      :gen_tcp.close(first)
      wait_until(fn -> Endpoint.connection_count(endpoint_name()) == 0 end)

      {:ok, second} = connect(ctx.socket_path)
      assert :ok = send_json(second, %{"fermix_bridge" => 1, "app_version" => "t", "env" => %{}})
      assert %{"fermix_bridge_ack" => %{"status" => "ok"}} = recv_json(second)
    end
  end

  # The shipped composition (Registry + peer supervisor + listener), because the
  # connection count is the peer supervisor's live child count.
  defp start_endpoint(ctx, opts \\ []) do
    opts = Keyword.merge([socket_path: ctx.socket_path], opts)
    start_supervised!({FermixChannels.Channels.Acp.Supervisor, opts}, id: :acp_supervisor)
  end

  defp endpoint_name, do: Endpoint

  # Short on purpose, like the `socket_path` in `setup`: `SafeRm.make_tmp_dir!/1`
  # nests deep enough that macOS's /var/folders tmp alone nearly fills the
  # ~104-byte `sun_path` cap, which would turn a permission case into a
  # path-length one.
  defp short_tmp_dir!(prefix) do
    dir =
      Path.join(System.tmp_dir!(), "fermix-acp-#{prefix}-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> SafeRm.rm_rf!(dir) end)
    dir
  end

  # `FermixChannels.Application`'s shape in miniature: the acp transport beside a
  # sibling child under one `:one_for_one` supervisor.
  defp tree_children(socket_path) do
    [
      Supervisor.child_spec(
        %{
          id: :acp_boot_sibling,
          start: {Agent, :start_link, [fn -> :alive end, [name: :acp_boot_sibling]]}
        },
        []
      ),
      Supervisor.child_spec(
        {FermixChannels.Channels.Acp.Supervisor,
         name: :acp_boot_supervisor,
         registry: :acp_boot_registry,
         peer_supervisor: :acp_boot_peer_supervisor,
         socket_path: socket_path},
        []
      )
    ]
  end

  defp connect(socket_path) do
    :gen_tcp.connect({:local, to_charlist(socket_path)}, 0, [
      :binary,
      {:active, false},
      {:packet, :line}
    ])
  end

  defp send_json(socket, payload), do: :gen_tcp.send(socket, Jason.encode!(payload) <> "\n")

  defp recv_json(socket) do
    {:ok, line} = :gen_tcp.recv(socket, 0, 2_000)
    Jason.decode!(line)
  end

  defp wait_until(fun, attempts \\ 100)

  defp wait_until(_fun, 0), do: flunk("condition never became true")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end
end
