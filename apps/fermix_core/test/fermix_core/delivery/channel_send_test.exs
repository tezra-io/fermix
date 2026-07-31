defmodule FermixCore.Delivery.ChannelSendTest do
  # The retry/rescue loop is exercised end-to-end through the Jobs.Delivery
  # delegation tests; this covers the new public surface directly.
  use ExUnit.Case, async: true

  alias FermixCore.Delivery.ChannelSend

  defmodule OkAdapter do
    def send_message(_destination, _text, _opts), do: :ok
  end

  defmodule FailAdapter do
    def send_message(_destination, _text, _opts), do: {:error, :permanent}
  end

  describe "send/5" do
    test "resolves an injected adapter and passes send_opts through" do
      assert :ok = ChannelSend.send("telegram", "c1", "hi", [thread_ts: "9"], adapter: OkAdapter)
    end

    test "fails fast on a non-transient error with a single attempt" do
      assert {:error, :permanent} =
               ChannelSend.send("telegram", "c1", "hi", [],
                 adapter: FailAdapter,
                 delivery_max_attempts: 1
               )
    end

    test "reports an unsupported platform when no adapter is configured" do
      assert {:error, {:unsupported_delivery_platform, "telegram"}} =
               ChannelSend.send("telegram", "c1", "hi", [], channels: %{})
    end
  end

  describe "resolve_adapter/2" do
    test "prefers an explicit adapter" do
      assert {:ok, OkAdapter} = ChannelSend.resolve_adapter("telegram", adapter: OkAdapter)
    end

    test "reads the channels map by platform" do
      assert {:ok, OkAdapter} =
               ChannelSend.resolve_adapter("telegram", channels: %{"telegram" => OkAdapter})
    end

    test "rejects an adapter lacking send_message/3" do
      assert {:error, {:invalid_delivery_adapter, Enum}} =
               ChannelSend.resolve_adapter("telegram", adapter: Enum)
    end
  end

  describe "with_timeout/2" do
    test "returns the function result inline for a zero timeout" do
      assert :done = ChannelSend.with_timeout(0, fn -> :done end)
    end

    test "returns the function result within the timeout" do
      assert {:ok, 42} = ChannelSend.with_timeout(1_000, fn -> {:ok, 42} end)
    end

    test "returns a timeout error when the function overruns" do
      assert {:error, :delivery_timeout} =
               ChannelSend.with_timeout(20, fn -> Process.sleep(500) end)
    end

    test "returns a crash error when the function raises" do
      assert {:error, {:delivery_crashed, _reason}} =
               ChannelSend.with_timeout(1_000, fn -> raise "boom" end)
    end
  end
end
