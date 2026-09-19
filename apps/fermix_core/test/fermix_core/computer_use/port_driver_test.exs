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
    # (protocol 10), which the fake mints exactly as the helper does.
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

  # The addressing half of the wire (protocol 10): a pointer action must name the
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

  # The check, at the wire (protocol 10). A mutating success answers the evidence
  # its request asked for, on its OWN frame — an image check comes back as that
  # image, minting an id of its own — and always says which evidence that was and
  # what each phase cost. A fake that omitted either would be kinder than the
  # helper, and this side would come to depend on a frame that never arrives.
  test "an image check rides the action's own frame, with its settle and its timings" do
    {:ok, state} = PortDriver.start(binary_path: @fake)

    assert {:ok, response} =
             PortDriver.execute(state, %{
               "action" => "left_click",
               "observation_id" => "boot-fake-1",
               "x" => 1,
               "y" => 2,
               "check" => "image"
             })

    assert is_binary(response["data"])
    assert is_binary(response["observation_id"])
    assert response["observation_kind"] == "image"

    assert response["receipt"]["check"] == %{
             "kind" => "image",
             "settle" => "stable",
             "changed" => true
           }

    assert response["receipt"]["timings_ms"] == %{
             "input" => 1,
             "settle" => 0,
             "capture" => 0,
             "encode" => 0
           }

    assert :ok = PortDriver.stop(state)
  end

  test "a check of none is the receipt alone, and says so" do
    {:ok, state} = PortDriver.start(binary_path: @fake)

    assert {:ok, response} =
             PortDriver.execute(state, %{"action" => "type", "text" => "e4", "check" => "none"})

    refute Map.has_key?(response, "data")
    assert response["receipt"]["check"] == %{"kind" => "none"}

    assert :ok = PortDriver.stop(state)
  end

  # A view that never stopped moving, and one identical to the image acted on:
  # both are observations about the picture, and both reach this side as the
  # helper's own words rather than as an absence.
  test "a settle that timed out and a view that did not change arrive as they are" do
    {:ok, state} =
      PortDriver.start(
        binary_path: @fake,
        env: [{~c"FAKE_SETTLE", ~c"timeout"}, {~c"FAKE_CHANGED", ~c"0"}]
      )

    assert {:ok, %{"receipt" => %{"check" => check}}} =
             PortDriver.execute(state, %{
               "action" => "left_click",
               "observation_id" => "boot-fake-1",
               "x" => 1,
               "y" => 2,
               "check" => "image"
             })

    assert check == %{"kind" => "image", "settle" => "timeout", "changed" => false}

    assert :ok = PortDriver.stop(state)
  end

  # The input went out and the settle was cancelled under it: a refusal whose
  # receipt says `sent` and carries no check at all.
  test "a cancelled settle is a sent receipt with no check" do
    {:ok, state} = PortDriver.start(binary_path: @fake)

    assert {:error, {:action_failed, payload}} =
             PortDriver.execute(state, %{"action" => "cancel_check"})

    assert payload["error"] == "cancelled"
    assert payload["receipt"]["dispatch"] == "sent"
    refute Map.has_key?(payload["receipt"], "check")

    assert :ok = PortDriver.stop(state)
  end

  # References, at the wire (protocol 10). An accessibility action answers its own
  # input method and the effect its read-back earned — never the HID receipt a
  # click gets, which would make "the pointer did it" indistinguishable from "the
  # control did it".
  test "an accessibility action answers the ax input method and its own effect" do
    {:ok, state} = PortDriver.start(binary_path: @fake)

    assert {:ok, %{"receipt" => pressed, "element_after" => after_press}} =
             PortDriver.execute(state, %{
               "action" => "press",
               "observation_id" => "boot-fake-1",
               "element_ref" => "e1",
               "check" => "semantic"
             })

    # `present` first, always: the control still answers, and here is its state.
    assert after_press == %{
             "present" => true,
             "role" => "AXButton",
             "label" => "Save",
             "enabled" => true
           }

    assert pressed["input_method"] == "ax"
    assert pressed["dispatch"] == "sent"
    assert pressed["effect"] == "not_observed"
    assert pressed["foreground_changed"] == false
    # Its check is the control read again, never a picture.
    assert pressed["check"] == %{"kind" => "semantic"}

    assert {:ok, %{"receipt" => %{"effect" => "verified"}}} =
             PortDriver.execute(state, %{
               "action" => "set_value",
               "observation_id" => "boot-fake-1",
               "element_ref" => "e2",
               "value" => "chess"
             })

    # The secure field reads back masked, so the set is real and the read-back
    # proves nothing.
    assert {:ok, %{"receipt" => %{"effect" => "not_observed"}}} =
             PortDriver.execute(state, %{
               "action" => "set_value",
               "observation_id" => "boot-fake-1",
               "element_ref" => "e3",
               "value" => "hunter2"
             })

    assert :ok = PortDriver.stop(state)
  end

  # Each refusal the references bring, with the receipt that says nothing was
  # dispatched. A fake that refused less than the helper would let a shape the
  # helper rejects pass every test in this repo.
  test "the reference refusals all arrive with a not_sent receipt" do
    {:ok, state} = PortDriver.start(binary_path: @fake)

    refusals = [
      {%{"action" => "press", "observation_id" => "boot-fake-1"}, "element_required"},
      {%{"action" => "press", "observation_id" => "boot-fake-1", "element_ref" => "e99"},
       "stale_element"},
      {%{
         "action" => "left_click",
         "observation_id" => "boot-fake-1",
         "element_ref" => "e1",
         "x" => 1,
         "y" => 2
       }, "addressing_conflict"},
      {%{"action" => "type", "text" => "hi", "element_ref" => "e1"}, "unknown_field"}
    ]

    for {request, code} <- refusals do
      assert {:error, {:action_failed, payload}} = PortDriver.execute(state, request)
      assert payload["error"] == code
      assert payload["receipt"]["dispatch"] == "not_sent"
    end

    assert :ok = PortDriver.stop(state)
  end

  for code <- ~w(element_disabled ax_action_unsupported) do
    test "the helper's #{code} arrives with a not_sent receipt" do
      {:ok, state} =
        PortDriver.start(
          binary_path: @fake,
          env: [{~c"FAKE_ELEMENT_ERROR", ~c"#{unquote(code)}"}]
        )

      assert {:error, {:action_failed, payload}} =
               PortDriver.execute(state, %{
                 "action" => "press",
                 "observation_id" => "boot-fake-1",
                 "element_ref" => "e1"
               })

      assert payload["error"] == unquote(code)
      assert payload["receipt"]["dispatch"] == "not_sent"

      assert :ok = PortDriver.stop(state)
    end
  end

  test "an elements reply names its controls, what they support, and what it left out" do
    {:ok, state} = PortDriver.start(binary_path: @fake)

    assert {:ok, %{"elements" => [first | _rest] = elements} = reply} =
             PortDriver.execute(state, %{"action" => "elements"})

    assert is_binary(reply["observation_id"])
    assert reply["truncated"] == "nodes"
    assert first["element_ref"] == "e1"
    assert first["label"] == "Save"
    assert first["actions"] == ["press"]
    assert Enum.any?(elements, &(&1["enabled"] == false)), "a disabled control is still listed"

    assert :ok = PortDriver.stop(state)
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
