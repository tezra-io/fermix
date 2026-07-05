defmodule FermixCore.Jobs.DeliveryTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixCore.Jobs.Delivery

  @counter :delivery_test_counter

  @job %{delivery_mode: "channel", delivery_target: %{platform: "telegram", chat_id: "c1"}}

  defmodule FlakyAdapter do
    # A transient pool-checkout timeout for the first two attempts, then success.
    @pool_timeout %RuntimeError{
      message:
        "Finch was unable to provide a connection within the timeout due to excess " <>
          "queuing for connections."
    }

    def send_message(_destination, _text, _opts) do
      n = Agent.get_and_update(:delivery_test_counter, fn c -> {c + 1, c + 1} end)
      if n < 3, do: {:error, @pool_timeout}, else: :ok
    end
  end

  defmodule HardFailAdapter do
    def send_message(_destination, _text, _opts) do
      Agent.update(:delivery_test_counter, &(&1 + 1))
      {:error, :permanent}
    end
  end

  defmodule RaisingAdapter do
    # Some send paths surface the Finch pool-checkout timeout as a *raise*
    # (RuntimeError), not an {:error, _} tuple. Unwrapped, that raise crashes
    # the spawned delivery process and the run silently drops the message
    # (the `{:delivery_crashed, %RuntimeError{}}` failures seen in the live
    # DB). Raises the transient twice, then succeeds — the FlakyAdapter case
    # via raise instead of return.
    @pool_timeout_message "Finch was unable to provide a connection within the timeout due to " <>
                            "excess queuing for connections."

    def send_message(_destination, _text, _opts) do
      n = Agent.get_and_update(:delivery_test_counter, fn c -> {c + 1, c + 1} end)
      if n < 3, do: raise(RuntimeError, @pool_timeout_message), else: :ok
    end
  end

  defmodule RaisingBugAdapter do
    # A non-transient programming error (not a RuntimeError) must still crash
    # loud — the transient rescue must not swallow real bugs.
    def send_message(_destination, _text, _opts) do
      Agent.update(:delivery_test_counter, &(&1 + 1))
      raise ArgumentError, "bad arg"
    end
  end

  defmodule RaisingNonTransientRuntimeAdapter do
    # A RuntimeError whose message is NOT the pool-checkout marker: rescued
    # (so the spawned run does not crash), returned as {:error, _}, NOT retried
    # (fails fast), and logged so the signal is not swallowed.
    def send_message(_destination, _text, _opts) do
      Agent.update(:delivery_test_counter, &(&1 + 1))
      raise RuntimeError, "adapter bug"
    end
  end

  setup do
    start_supervised!(%{
      id: @counter,
      start: {Agent, :start_link, [fn -> 0 end, [name: @counter]]}
    })

    :ok
  end

  test "retries channel delivery on a transient pool timeout, then succeeds" do
    assert {:ok, "sent"} =
             Delivery.deliver(@job, "hi", adapter: FlakyAdapter, delivery_backoff_ms: 0)

    assert Agent.get(@counter, & &1) == 3
  end

  test "does not retry a non-transient delivery error (fails fast)" do
    assert {:error, :permanent} =
             Delivery.deliver(@job, "hi", adapter: HardFailAdapter, delivery_backoff_ms: 0)

    assert Agent.get(@counter, & &1) == 1
  end

  test "retries a raised (not returned) transient pool timeout, then succeeds" do
    assert {:ok, "sent"} =
             Delivery.deliver(@job, "hi", adapter: RaisingAdapter, delivery_backoff_ms: 0)

    assert Agent.get(@counter, & &1) == 3
  end

  test "a raised programming error is not rescued — it crashes loud" do
    assert_raise ArgumentError, "bad arg", fn ->
      Delivery.deliver(@job, "hi", adapter: RaisingBugAdapter, delivery_backoff_ms: 0)
    end

    assert Agent.get(@counter, & &1) == 1
  end

  test "a raised non-transient RuntimeError is returned and logged, not retried or swallowed" do
    log =
      capture_log(fn ->
        assert {:error, %RuntimeError{message: "adapter bug"}} =
                 Delivery.deliver(@job, "hi",
                   adapter: RaisingNonTransientRuntimeAdapter,
                   delivery_backoff_ms: 0
                 )
      end)

    assert Agent.get(@counter, & &1) == 1
    assert log =~ "Delivery send raised"
  end
end
