defmodule FermixCore.ComputerUse.PortDriverTest do
  use ExUnit.Case, async: true

  alias FermixCore.ComputerUse.PortDriver

  @fake Path.expand("fake_compux_sidecar.pl", __DIR__)

  test "fails loud when the sidecar binary is absent" do
    assert {:error, {:sidecar_missing, "/no/such/compux"}} =
             PortDriver.start(binary_path: "/no/such/compux")
  end

  test "handshakes, keeps :port in state, and round-trips an action" do
    {:ok, state} = PortDriver.start(binary_path: @fake)
    # :port at the top level is what Session's handle_info matches on.
    assert %{port: _port, session_id: nil} = state

    assert {:ok, %{"ok" => true, "pong" => true}} =
             PortDriver.execute(state, %{"action" => "screenshot"})

    assert :ok = PortDriver.stop(state)
  end

  test "refuses a protocol-version mismatch" do
    assert {:error, {:protocol_mismatch, %{library: lib, sidecar: 999}}} =
             PortDriver.start(binary_path: @fake, env: [{~c"FAKE_PROTO", ~c"999"}])

    assert lib == Compux.Protocol.protocol_version()
  end

  test "maps a sidecar-action timeout to the fermix Timeouts shape" do
    {:ok, state} = PortDriver.start(binary_path: @fake, timeout: 100, session_id: "cua_test")

    assert {:error, {:timeout, :cu_sidecar_action, 100}} =
             PortDriver.execute(state, %{"action" => "hang"})

    PortDriver.stop(state)
  end
end
