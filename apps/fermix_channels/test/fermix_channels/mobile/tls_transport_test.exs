defmodule FermixChannels.Mobile.TlsTransportTest do
  @moduledoc """
  The listener's TLS transport over a real loopback socket: the stock one, with
  a handshake that ends. The deadline is passed in, so no test waits it out.
  """

  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.Identity
  alias FermixChannels.Mobile.TlsTransport

  setup do
    root = FermixTestSupport.SafeRm.make_tmp_dir!("mobile-tls-transport")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(root) end)
    assert {:ok, identity} = Identity.ensure(root: root)

    assert {:ok, listener} =
             TlsTransport.listen(0,
               ip: {127, 0, 0, 1},
               keyfile: identity.tls_key_path,
               certfile: identity.tls_cert_path
             )

    on_exit(fn -> TlsTransport.close(listener) end)
    assert {:ok, {{127, 0, 0, 1}, port}} = TlsTransport.sockname(listener)
    %{listener: listener, port: port}
  end

  # R4-8: ThousandIsland calls handshake/1 alone, in the connection's own
  # process, after handing it the accepted socket. It starts that connection's
  # fifteen-second upgrade deadline and hands :ssl its ten-second bound, which
  # answers a peer that never says hello with {:error, :timeout} (the test
  # below, at a bound short enough to wait out). A trace of the call names the
  # bound, so no test waits ten seconds for it.
  test "the listener's handshake starts the upgrade deadline and bounds a silent peer", ctx do
    session = :trace.session_create(:tls_transport_handshake, self(), [])
    on_exit(fn -> :trace.session_destroy(session) end)
    1 = :trace.function(session, {:ssl, :handshake, 2}, true, [:local])

    assert {:ok, silent} = :gen_tcp.connect(~c"127.0.0.1", ctx.port, [:binary, active: false])
    assert {:ok, accepted} = TlsTransport.accept(ctx.listener)
    test_pid = self()

    connection =
      spawn(fn ->
        receive do
          :go ->
            before = System.monotonic_time(:millisecond)
            result = TlsTransport.handshake(accepted)
            after_ms = System.monotonic_time(:millisecond)

            send(
              test_pid,
              {:handshake, result, TlsTransport.upgrade_deadline(), before, after_ms}
            )
        end
      end)

    assert :ok = TlsTransport.controlling_process(accepted, connection)
    1 = :trace.process(session, connection, true, [:call])
    send(connection, :go)

    assert_receive {:trace, ^connection, :call, {:ssl, :handshake, [_socket, 10_000]}}, 5_000
    assert TlsTransport.handshake_timeout_ms() == 10_000

    # The peer leaves without a word; the bound it was given is the one above.
    :ok = :gen_tcp.close(silent)
    assert_receive {:handshake, {:error, _closed}, deadline, before, after_ms}, 5_000
    assert TlsTransport.upgrade_deadline_ms() == 15_000
    assert deadline in (before + 15_000)..(after_ms + 15_000)
  end

  # R1-1: ThousandIsland runs `:ssl.handshake/1`, which waits forever, so a
  # peer that connects and never says hello held a connection slot for good.
  test "a peer that never sends a ClientHello is closed at the deadline", ctx do
    assert {:ok, silent} =
             :gen_tcp.connect(~c"127.0.0.1", ctx.port, [:binary, active: true])

    assert {:ok, accepted} = TlsTransport.accept(ctx.listener)

    assert {:error, :timeout} = TlsTransport.handshake(accepted, 50)
    assert_receive {:tcp_closed, ^silent}
  end

  # R3-1: a read's own timeout restarts with every byte, so a peer that
  # dribbled its request held the connection for good. A read waits no longer
  # than the upgrade deadline, and one past it closes the connection.
  test "reads end at the upgrade deadline, and a read past it closes the connection", ctx do
    test_pid = self()

    client =
      Task.async(fn ->
        {:ok, socket} =
          :ssl.connect(~c"127.0.0.1", ctx.port, [:binary, active: true, verify: :verify_none])

        send(test_pid, :connected)

        receive do
          {:ssl_closed, ^socket} -> :closed
        after
          5_000 -> :still_open
        end
      end)

    assert {:ok, accepted} = TlsTransport.accept(ctx.listener)
    assert {:ok, session} = TlsTransport.handshake(accepted, 5_000)
    assert_receive :connected, 5_000

    assert :ok = TlsTransport.start_upgrade_deadline(50)
    assert {:error, :timeout} = TlsTransport.recv(session, 0, :infinity)
    assert {:error, :closed} = TlsTransport.recv(session, 0, :infinity)
    assert Task.await(client) == :closed
  end

  test "a peer that completes TLS gets a working session", ctx do
    client =
      Task.async(fn ->
        {:ok, socket} =
          :ssl.connect(~c"127.0.0.1", ctx.port, [:binary, active: false, verify: :verify_none])

        :ok = :ssl.send(socket, "ping")
        socket
      end)

    assert {:ok, accepted} = TlsTransport.accept(ctx.listener)
    assert {:ok, session} = TlsTransport.handshake(accepted, 5_000)
    assert {:ok, "ping"} = TlsTransport.recv(session, 4, 5_000)
    assert TlsTransport.secure?()
    :ok = :ssl.close(Task.await(client))
  end
end
