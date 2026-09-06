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

  # A channel that renders a one-tap approve affordance: records the
  # (message, text, token) it was asked to deliver an approval for.
  defmodule ApprovingChannel do
    def build_text_reply(_message), do: fn _text -> :ok end
    def build_media_reply(_message), do: fn _media -> :ok end

    def send_approval(%Message{id: id}, text, token) do
      send(self(), {:approval_sent, id, text, token})
      :ok
    end
  end

  # A channel without send_approval/3: the approval prompt must degrade to the
  # plain text closure (the prompt text still carries the `/confirm` command).
  defmodule TextOnlyChannel do
    def build_text_reply(_message),
      do: fn text ->
        send(self(), {:text_sent, text})
        :ok
      end

    def build_media_reply(_message), do: fn _media -> :ok end
  end

  defmodule RichApprovalChannel do
    def build_text_reply(_message), do: fn _text -> :ok end
    def build_media_reply(_message), do: fn _media -> :ok end

    def send_approval(%Message{id: id}, spec) do
      send(self(), {:rich_approval_sent, id, spec})
      :ok
    end
  end

  # Stands in for the CLI sync-capture / bench override: it handles exactly the
  # `Reply.outbound()` shapes an override is expected to, and fails loud on the rest.
  defp capturing_override(test_pid) do
    fn
      {:text, text} ->
        send(test_pid, {:override_part, {:text, text}})
        :ok

      {:approval_prompt, text, token} ->
        send(test_pid, {:override_part, {:approval_prompt, text, token}})
        :ok

      other ->
        {:error, {:invalid_reply_part, other}}
    end
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

  describe "build_deliver/1 — {:approval_prompt, text, token}" do
    test "routes to the channel's send_approval/3 with the prompt text and token" do
      deliver = Delivery.build_deliver(ReplyContext.new(ApprovingChannel, message()))

      assert :ok = deliver.({:approval_prompt, "Approve with /confirm AB12CD34", "AB12CD34"})
      assert_received {:approval_sent, "42", "Approve with /confirm AB12CD34", "AB12CD34"}
    end

    test "falls back to the text closure when the channel has no send_approval/3" do
      deliver = Delivery.build_deliver(ReplyContext.new(TextOnlyChannel, message()))

      assert :ok = deliver.({:approval_prompt, "Approve with /confirm AB12CD34", "AB12CD34"})
      assert_received {:text_sent, "Approve with /confirm AB12CD34"}
    end

    test "is not rejected as an invalid reply part" do
      deliver = Delivery.build_deliver(ReplyContext.new(TextOnlyChannel, message()))

      refute match?({:error, {:invalid_reply_part, _}}, deliver.({:approval_prompt, "x", "TOK"}))
    end

    test "routes a structured approval without inferring its kind from text" do
      deliver = Delivery.build_deliver(ReplyContext.new(RichApprovalChannel, message()))
      spec = %{kind: :soul, text: "Apply persona update?", token: "SOUL", ttl_s: 300}

      assert :ok = deliver.({:approval_prompt, spec})
      assert_received {:rich_approval_sent, "42", ^spec}
    end
  end

  describe "build_deliver/2 — reply_fn override" do
    test "flattens a structured approval to the text+token shape an override handles" do
      deliver =
        Delivery.build_deliver(
          ReplyContext.new(TextOnlyChannel, message()),
          capturing_override(self())
        )

      spec = %{
        kind: :sandbox,
        text: "Confirm sandbox change with /confirm AB12CD34",
        token: "AB12CD34",
        detail: "allowed_roots + /tmp/project",
        ttl_s: 60
      }

      assert :ok = deliver.({:approval_prompt, spec})

      assert_received {:override_part,
                       {:approval_prompt, "Confirm sandbox change with /confirm AB12CD34",
                        "AB12CD34"}}
    end

    test "leaves every other part untouched for the override" do
      deliver =
        Delivery.build_deliver(
          ReplyContext.new(TextOnlyChannel, message()),
          capturing_override(self())
        )

      assert :ok = deliver.({:text, "plain"})
      assert_received {:override_part, {:text, "plain"}}

      assert :ok = deliver.({:approval_prompt, "Approve with /confirm TOK12345", "TOK12345"})
      assert_received {:override_part, {:approval_prompt, _text, "TOK12345"}}
    end

    test "fails loud on a structured approval whose kind is not a known approval kind" do
      deliver =
        Delivery.build_deliver(
          ReplyContext.new(TextOnlyChannel, message()),
          capturing_override(self())
        )

      spec = %{kind: :bogus, text: "Confirm?", token: "TOK12345"}

      assert {:error, {:invalid_reply_part, {:approval_prompt, ^spec}}} =
               deliver.({:approval_prompt, spec})
    end
  end
end
