defmodule FermixChannels.Gateway.DeliveryTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Gateway.Delivery
  alias FermixChannels.Gateway.Message
  alias FermixChannels.Gateway.ReplyContext

  # A reaction-capable channel: records the (message, emoji) it was asked to react
  # with. Text/media replies are stubbed to satisfy build_deliver's other clauses.
  defmodule ReactingChannel do
    def build_text_reply(_message), do: fn _text -> :ok end
    def build_media_reply(_message), do: fn _media -> :ok end

    def react(%Message{id: id}, emoji) do
      send(self(), {:reacted, id, emoji})
      :ok
    end
  end

  # A channel with no react/2 — the gate must refuse a reaction, not crash on an
  # undefined callback (defense-in-depth; capability-gating should prevent this).
  defmodule NoReactChannel do
    def build_text_reply(_message), do: fn _text -> :ok end
    def build_media_reply(_message), do: fn _media -> :ok end
  end

  defp message do
    Message.new!(%{
      id: "42",
      content: "thanks",
      sender: "user",
      channel: "telegram",
      chat_id: "c1",
      reply_target: "c1"
    })
  end

  describe "build_deliver/1 — {:react, emoji}" do
    test "dispatches to the channel's react/2 with the closed-over message" do
      deliver = Delivery.build_deliver(ReplyContext.new(ReactingChannel, message()))

      assert :ok = deliver.({:react, "🙏"})
      assert_received {:reacted, "42", "🙏"}
    end

    test "fails loud when the channel does not implement react/2" do
      deliver = Delivery.build_deliver(ReplyContext.new(NoReactChannel, message()))

      assert {:error, :reaction_unsupported} = deliver.({:react, "🙏"})
    end

    test "emits a channel reply telemetry event tagged :reaction" do
      handler_id = "delivery-reaction-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler_id,
          [:fermix, :channel, :reply],
          fn _event, _measurements, metadata, pid -> send(pid, {:reply_telemetry, metadata}) end,
          self()
        )

      try do
        deliver = Delivery.build_deliver(ReplyContext.new(ReactingChannel, message()))
        assert :ok = deliver.({:react, "🎉"})

        assert_receive {:reply_telemetry, %{reply_type: :reaction, status: :ok}}
      after
        :telemetry.detach(handler_id)
      end
    end
  end
end
