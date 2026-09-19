defmodule FermixCore.ComputerUse.PortDriverTest do
  use ExUnit.Case, async: true

  alias FermixCore.ComputerUse.PortDriver

  @fake Path.expand("fake_compux_sidecar.pl", __DIR__)

  test "fails loud when the sidecar binary is absent" do
    assert {:error, {:sidecar_missing, "/no/such/compux"}} =
             PortDriver.start(binary_path: "/no/such/compux")
  end

  test "handshakes, holds the transport, and round-trips an action" do
    {:ok, state} = PortDriver.start(binary_path: @fake)
    # The state is the transport's pid, never a Port: the Port belongs to the
    # transport, and the sidecar's death reaches this process as a message.
    assert %{transport: transport, session_id: nil} = state
    assert is_pid(transport)

    # A reply that hands back coordinates names the image they belong to
    # (protocol 8), which the fake mints exactly as the helper does.
    assert {:ok, %{"ok" => true, "observation_id" => "boot-fake-1"}} =
             PortDriver.execute(state, %{"action" => "screenshot"})

    assert :ok = PortDriver.stop(state)
  end

  # A control answers from the ACKNOWLEDGEMENT, and the generation it carries is
  # the sidecar's — walked, so a consumer that assumed a constant is caught.
  test "a control is answered from the sidecar's acknowledgement" do
    {:ok, state} = PortDriver.start(binary_path: @fake)

    assert {:ok, ack} = PortDriver.control(state, :pause)
    assert ack.action == :pause
    assert ack.ok == true
    assert ack.in_flight_request_id == nil

    assert {:ok, resumed} = PortDriver.control(state, :resume)
    assert resumed.action == :resume
    assert resumed.authorization_generation > ack.authorization_generation

    assert :ok = PortDriver.stop(state)
  end

  # The slice's headline claim, against a real Port: a control is answered WHILE a
  # request is open, and its ack names that request. The previous shape sent the
  # control with nothing in flight, which an adapter that serialised controls
  # behind actions would have passed just as happily.
  test "a control is answered while a request is open, and its ack names it" do
    {:ok, state} = PortDriver.start(binary_path: @fake)
    parent = self()

    spawn_link(fn ->
      send(parent, {:deferred, PortDriver.execute(state, %{"action" => "defer"})})
    end)

    Process.sleep(50)

    assert {:ok, ack} = PortDriver.control(state, :pause)
    assert is_binary(ack.in_flight_request_id)

    # …and the request it named comes back as the half-done thing it is.
    assert_receive {:deferred, {:error, {:action_failed, payload}}}, 2_000
    assert payload["error"] == "cancelled"
    assert payload["receipt"]["dispatch"] == "partial"

    assert :ok = PortDriver.stop(state)
  end

  test "a control the sidecar refuses is reported as refused, never as confirmed" do
    {:ok, state} =
      PortDriver.start(binary_path: @fake, env: [{~c"FAKE_CONTROL_MODE", ~c"refuse"}])

    assert {:error, {:control_refused, ack}} = PortDriver.control(state, :pause)
    assert ack.ok == false

    assert :ok = PortDriver.stop(state)
  end

  # A refusal is the same frame as a success minus the payload: it carries the code
  # AND the receipt the outcome is read from, so "the helper said no" never has to
  # be taken as proof that nothing reached the screen.
  test "a refused action carries its code, its detail and its receipt" do
    {:ok, state} = PortDriver.start(binary_path: @fake)

    assert {:error, {:action_failed, payload}} =
             PortDriver.execute(state, %{"action" => "refuse"})

    assert payload["error"] == "paused"
    assert payload["detail"] == "a pause is installed"
    assert payload["receipt"]["dispatch"] == "not_sent"

    assert :ok = PortDriver.stop(state)
  end

  # The library deliberately passes a receipt-less mutating success through
  # untouched — refusing there would destroy the response of an action that already
  # ran — so this is the shape Fermix's own `:missing_receipt` fault is built on,
  # and it has to keep arriving unchanged for that fault to be the only rule.
  test "a mutating success with no receipt reaches the consumer untouched" do
    {:ok, state} = PortDriver.start(binary_path: @fake)

    assert {:ok, response} = PortDriver.execute(state, %{"action" => "no_receipt"})
    refute Map.has_key?(response, "receipt")

    assert :ok = PortDriver.stop(state)
  end

  # A mutating action's response carries the receipt the session's outcome is
  # derived from; a read-only one carries none, because it dispatches nothing.
  test "a mutating action's response carries a receipt" do
    {:ok, state} = PortDriver.start(binary_path: @fake)

    assert {:ok, %{"receipt" => %{"dispatch" => "sent"}}} =
             PortDriver.execute(state, %{
               "action" => "left_click",
               "observation_id" => "boot-fake-1",
               "x" => 1,
               "y" => 2
             })

    assert {:ok, response} = PortDriver.execute(state, %{"action" => "screenshot"})
    refute Map.has_key?(response, "receipt")

    assert :ok = PortDriver.stop(state)
  end

  # The addressing half of protocol 8, at the wire: a pointer action must name the
  # image its coordinates were read in and must not carry a rectangle, and every
  # refusal of one dispatched nothing. The fake answers exactly as the helper does,
  # so the session's sentences are exercised against a real Port rather than a map.
  test "a pointer action that names no image is refused with a not_sent receipt" do
    {:ok, state} = PortDriver.start(binary_path: @fake)

    assert {:error, {:action_failed, payload}} =
             PortDriver.execute(state, %{"action" => "left_click", "x" => 1, "y" => 2})

    assert payload["error"] == "observation_required"
    assert payload["receipt"]["dispatch"] == "not_sent"

    assert :ok = PortDriver.stop(state)
  end

  test "a pointer action carrying a rectangle is refused as an unknown field" do
    {:ok, state} = PortDriver.start(binary_path: @fake)

    assert {:error, {:action_failed, %{"error" => "unknown_field"}}} =
             PortDriver.execute(state, %{
               "action" => "left_click",
               "observation_id" => "boot-fake-1",
               "region" => %{"x" => 0, "y" => 0, "w" => 10, "h" => 10},
               "x" => 1,
               "y" => 2
             })

    assert :ok = PortDriver.stop(state)
  end

  # The other side of the same rule: an action that reads no coordinates must not
  # name an image either. A fake that refused only the addressed actions would let
  # a request shape the real helper rejects pass every test in this repo.
  test "an action that reads no coordinates is refused for naming an image" do
    {:ok, state} = PortDriver.start(binary_path: @fake)

    for request <- [
          %{"action" => "type", "text" => "e4", "observation_id" => "boot-fake-1"},
          %{"action" => "key", "chord" => "enter", "observation_id" => "boot-fake-1"},
          %{"action" => "windows", "observation_id" => "boot-fake-1"}
        ] do
      assert {:error, {:action_failed, %{"error" => "unknown_field"}}} =
               PortDriver.execute(state, request),
             "#{request["action"]} must be refused for naming an image"
    end

    # A viewing action MAY name one: its rectangle is then read in that image.
    assert {:ok, %{"observation_id" => _}} =
             PortDriver.execute(state, %{
               "action" => "screenshot",
               "observation_id" => "boot-fake-1",
               "region" => %{"x" => 0, "y" => 0, "w" => 10, "h" => 10}
             })

    assert :ok = PortDriver.stop(state)
  end

  # Each of the helper's own addressing and geometry refusals, which the session
  # renders into a sentence of its own and drops the named image for.
  for code <- ~w(unknown_observation expired_observation stale_observation
                 point_outside_observation capture_geometry_mismatch) do
    test "the helper's #{code} arrives with a not_sent receipt" do
      {:ok, state} =
        PortDriver.start(
          binary_path: @fake,
          env: [{~c"FAKE_OBSERVATION_ERROR", ~c"#{unquote(code)}"}]
        )

      assert {:error, {:action_failed, payload}} =
               PortDriver.execute(state, %{
                 "action" => "left_click",
                 "observation_id" => "boot-fake-1",
                 "x" => 1,
                 "y" => 2
               })

      assert payload["error"] == unquote(code)
      assert payload["detail"] == "the fake sidecar refused it"
      assert payload["receipt"]["dispatch"] == "not_sent"

      assert :ok = PortDriver.stop(state)
    end
  end

  # The one message that says the sidecar is gone, and the only place a status the
  # sidecar chose for itself (75, the capture stall) can reach its owner.
  test "the sidecar's exit reaches the process that started the driver" do
    {:ok, state} = PortDriver.start(binary_path: @fake)
    transport = state.transport

    # The in-flight action is answered FIRST — a caller waiting on a reply never
    # learns of the death before its own receipt.
    assert {:error, {:sidecar_exited, 7}} = PortDriver.execute(state, %{"action" => "boom"})
    assert_receive {:compux_sidecar_exit, ^transport, 7}, 2_000
  end

  test "refuses a protocol-version mismatch" do
    assert {:error, {:protocol_mismatch, %{library: lib, sidecar: 999}}} =
             PortDriver.start(binary_path: @fake, env: [{~c"FAKE_PROTO", ~c"999"}])

    assert lib == Compux.Protocol.protocol_version()
  end

  test "maps a sidecar-action timeout to the fermix Timeouts shape" do
    # 500ms (not a tight 100) so the handshake round-trip has headroom under
    # concurrent test load; the "hang" (10s sleep) still trips the deadline.
    {:ok, state} = PortDriver.start(binary_path: @fake, timeout: 500, session_id: "cua_test")

    assert {:error, {:timeout, :cu_sidecar_action, 500}} =
             PortDriver.execute(state, %{"action" => "hang"})

    PortDriver.stop(state)
  end
end
