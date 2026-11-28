defmodule FermixCore.PhoneCalls.Call.TimersTest do
  use ExUnit.Case, async: true

  alias FermixCore.PhoneCalls.Call.Timers

  # Tells this test what was scheduled and arms nothing.
  defp timers do
    test = self()

    Timers.new(fn message, ms ->
      send(test, {:scheduled, message, ms})
      make_ref()
    end)
  end

  test "an expiry fires once, with the token it was armed with" do
    timers = Timers.arm(timers(), :drain, 5_000)
    assert_received {:scheduled, {:phone_call_timer, :drain, token}, 5_000}

    assert {:fired, timers} = Timers.take(timers, :drain, token)
    assert :stale = Timers.take(timers, :drain, token)
  end

  test "arming a kind again, or disarming it, makes its earlier expiry stale" do
    timers = Timers.arm(timers(), :speech, 1_500)
    assert_received {:scheduled, {:phone_call_timer, :speech, first}, 1_500}
    timers = Timers.arm(timers, :speech, 1_500)
    assert_received {:scheduled, {:phone_call_timer, :speech, second}, 1_500}

    assert :stale = Timers.take(timers, :speech, first)
    assert :stale = timers |> Timers.disarm(:speech) |> Timers.take(:speech, second)
    assert {:fired, _timers} = Timers.take(timers, :speech, second)
  end

  test "disarming every kind leaves every expiry stale" do
    timers = timers() |> Timers.arm(:ringing, 1) |> Timers.arm({:settle, "del_1"}, 2)
    assert_received {:scheduled, {:phone_call_timer, :ringing, ringing}, 1}
    assert_received {:scheduled, {:phone_call_timer, {:settle, "del_1"}, settle}, 2}

    timers = Timers.disarm_all(timers)
    assert :stale = Timers.take(timers, :ringing, ringing)
    assert :stale = Timers.take(timers, {:settle, "del_1"}, settle)
  end

  test "a real timer is cancelled when it is disarmed" do
    timers = Timers.new(fn message, ms -> Process.send_after(self(), message, ms) end)
    timers = timers |> Timers.arm(:deadline, 60_000) |> Timers.disarm(:deadline)
    assert timers.armed == %{}
    refute_received {:phone_call_timer, :deadline, _token}
  end
end
