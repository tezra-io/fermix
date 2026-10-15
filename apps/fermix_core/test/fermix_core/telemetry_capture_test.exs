defmodule FermixCore.TelemetryCaptureTest do
  @moduledoc """
  `FermixTestSupport.TelemetryCapture` is how an async test observes telemetry
  without seeing another test's events. Each pin case emits the events that must
  NOT arrive before the one that must, each from a process whose emission has
  provably finished, so a handler that forwarded everything puts a wrong event
  first in the mailbox and fails both the match and the refute, with no wait.
  """
  use ExUnit.Case, async: true

  alias FermixTestSupport.TelemetryCapture

  @event [:fermix_test, :telemetry_capture, :probe]
  @detach_event [:fermix_test, :telemetry_capture, :detach_probe]

  describe "an :emitter pin" do
    test "forwards the test's own event and not another process's" do
      TelemetryCapture.attach([@event], :emitter)

      emit_elsewhere(@event, %{from: :elsewhere})
      :telemetry.execute(@event, %{n: 1}, %{from: :test})

      assert {:telemetry, @event, %{n: 1}, %{from: :test}} = first_forwarded()
      refute_received {:telemetry, @event, _measurements, %{from: :elsewhere}}
    end
  end

  describe "a metadata pin" do
    test "forwards an event carrying every pinned value, from any process" do
      session_id = "capture-#{System.unique_integer([:positive])}"
      TelemetryCapture.attach([@event], session_id: session_id, kind: :turn)

      emit_elsewhere(@event, %{session_id: "someone-else", kind: :turn})
      emit_elsewhere(@event, %{session_id: session_id, kind: :tool})
      emit_elsewhere(@event, %{session_id: session_id, kind: :turn})

      assert {:telemetry, @event, _measurements, %{session_id: ^session_id, kind: :turn}} =
               first_forwarded()

      refute_received {:telemetry, @event, _measurements, %{session_id: "someone-else"}}
      refute_received {:telemetry, @event, _measurements, %{kind: :tool}}
    end
  end

  test "the handler is attached during the test and detached after it" do
    # on_exit callbacks run last-registered first, so this one, registered
    # before attach/2 registers its own, runs after the detach.
    on_exit(fn -> assert :telemetry.list_handlers(@detach_event) == [] end)

    id = TelemetryCapture.attach([@detach_event], :emitter)

    assert [%{id: ^id}] = :telemetry.list_handlers(@detach_event)
  end

  test "a pin that names nothing is refused" do
    assert_raise ArgumentError, fn -> TelemetryCapture.attach([@event], []) end
    assert_raise ArgumentError, fn -> TelemetryCapture.attach([@event], :anyone) end
    assert_raise ArgumentError, fn -> TelemetryCapture.attach([], :emitter) end
  end

  # The handler runs in the emitting process and sends before `execute/3`
  # returns, and messages between two processes arrive in send order: once
  # `:emitted` is here, any forward of that event is already in the mailbox.
  defp emit_elsewhere(event, metadata) do
    test = self()

    spawn_link(fn ->
      :telemetry.execute(event, %{n: 0}, metadata)
      send(test, {:emitted, metadata})
    end)

    assert_receive {:emitted, ^metadata}
  end

  # The first forwarded event in the mailbox, whatever it is.
  defp first_forwarded do
    assert_receive {:telemetry, _event, _measurements, _metadata} = forwarded
    forwarded
  end
end
