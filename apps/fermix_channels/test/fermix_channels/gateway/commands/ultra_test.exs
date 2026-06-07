defmodule FermixChannels.Gateway.Commands.UltraTest do
  # async: false — the dispatch test mutates the global :commands config because
  # Ultra is intentionally not in the default registry until turn routing lands.
  use ExUnit.Case, async: false

  alias FermixChannels.Gateway.Authorization, as: IngressAuthorization
  alias FermixChannels.Gateway.Commands
  alias FermixChannels.Gateway.Commands.Ultra
  alias FermixChannels.Gateway.Message

  defp message(content) do
    Message.new!(%{
      id: "m1",
      content: content,
      sender: "a",
      channel: "telegram",
      chat_id: "c1",
      reply_target: "c1",
      metadata: %{}
    })
  end

  defp reply_fn(pid), do: fn {:text, text} -> send(pid, {:reply, text}) end

  defp operator_ctx,
    do: %{authorization: %IngressAuthorization{role: :operator, trust: :operator}}

  describe "execute/3" do
    test "a blank prompt replies usage and does not enqueue" do
      assert :ok = Ultra.execute(message(""), reply_fn(self()), operator_ctx())
      assert_receive {:reply, "Usage: /ultra <prompt>"}
    end

    test "tags run_profile: :ultra and returns an enqueue result" do
      assert {:enqueue, tagged} =
               Ultra.execute(message("plan a trip"), reply_fn(self()), operator_ctx())

      assert tagged.content == "plan a trip"
      assert tagged.metadata[:run_profile] == :ultra
      refute_receive {:reply, _text}, 100
    end
  end

  describe "authorize/3 (owner-only)" do
    test "operator passes" do
      assert :ok = Ultra.authorize(message("x"), %{}, operator_ctx())
    end

    test "missing authorization fails closed" do
      assert {:error, :unauthorized} = Ultra.authorize(message("x"), %{}, %{})
    end
  end

  describe "through Commands.dispatch/3" do
    setup do
      # Ultra is not in the default registry yet (gated until turn routing lands),
      # so register it just for this dispatch test.
      previous = Application.get_env(:fermix_channels, :commands)
      Application.put_env(:fermix_channels, :commands, [Ultra])

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:fermix_channels, :commands)
          value -> Application.put_env(:fermix_channels, :commands, value)
        end
      end)
    end

    test "/ultra <prompt> dispatches to an enqueue with the stripped prompt + tag" do
      msg = message("/ultra plan a trip")

      assert {:enqueue, tagged} =
               Commands.dispatch(Commands.parse(msg), reply_fn(self()), operator_ctx())

      assert tagged.content == "plan a trip"
      assert tagged.metadata[:run_profile] == :ultra
    end
  end
end
