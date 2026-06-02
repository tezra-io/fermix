defmodule FermixChannels.Gateway.TypingTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias FermixChannels.Gateway.Typing

  defp drain_ticks do
    receive do
      :tick -> drain_ticks()
    after
      0 -> :ok
    end
  end

  test "runs the typing indicator while work runs and stops it afterward" do
    test_pid = self()
    typing_fn = fn -> send(test_pid, :tick) end

    result =
      Typing.with_indicator(typing_fn, [interval_ms: 10, timeout_ms: 1_000], fn ->
        Process.sleep(60)
        :work_done
      end)

    assert result == :work_done
    assert_received :tick
    drain_ticks()

    # The indicator is stopped once the work returns — no further ticks.
    Process.sleep(30)
    refute_received :tick
  end

  test "returns the work result and skips typing when no typing_fn is given" do
    assert :work_done = Typing.with_indicator(nil, [], fn -> :work_done end)
  end

  test "force-stopping a stuck typing indicator does not kill the work process" do
    test_pid = self()

    {pid, ref} =
      spawn_monitor(fn ->
        result =
          Typing.with_indicator(
            fn ->
              send(test_pid, :typing_started)

              receive do
                :never -> :ok
              end
            end,
            [interval_ms: 10, timeout_ms: 1_000],
            fn ->
              Process.sleep(20)
              :work_done
            end
          )

        send(test_pid, {:typing_result, result})
      end)

    assert_receive :typing_started, 500
    assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 1_000
    assert reason == :normal
    assert_received {:typing_result, :work_done}
  end

  test "tolerates a typing_fn that reports an expected transport error" do
    capture_log(fn ->
      result =
        Typing.with_indicator(
          fn -> {:error, %Req.TransportError{reason: :econnrefused}} end,
          [interval_ms: 10],
          fn -> :work_done end
        )

      assert result == :work_done
    end)
  end

  test "an unexpected typing_fn exception crashes the work instead of being swallowed" do
    test_pid = self()

    capture_log(fn ->
      {pid, ref} =
        spawn_monitor(fn ->
          Typing.with_indicator(
            fn ->
              send(test_pid, :typing_called)
              raise ArgumentError, "broken typing callback"
            end,
            [interval_ms: 10],
            fn -> Process.sleep(2_000) end
          )
        end)

      assert_receive :typing_called, 500
      assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 2_000
      refute reason == :normal
    end)
  end
end
