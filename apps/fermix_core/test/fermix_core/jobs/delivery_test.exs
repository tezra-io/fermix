defmodule FermixCore.Jobs.DeliveryTest do
  use ExUnit.Case, async: false

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
end
