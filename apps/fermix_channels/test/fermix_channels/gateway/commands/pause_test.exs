defmodule FermixChannels.Gateway.Commands.PauseTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Gateway.Authorization, as: IngressAuthorization
  alias FermixChannels.Gateway.Commands.Pause
  alias FermixChannels.Gateway.Commands.Resume
  alias FermixChannels.Gateway.Message

  defp message,
    do:
      Message.new!(%{
        id: "m1",
        content: "",
        sender: "a",
        channel: "telegram",
        chat_id: "c1",
        reply_target: "c1"
      })

  defp reply_fn(pid), do: fn {:text, text} -> send(pid, {:reply, text}) end

  describe "metadata" do
    test "distinct triggers, no aliases" do
      assert Pause.name() == "pause"
      assert Resume.name() == "resume"
      assert Pause.aliases() == []
      assert Resume.aliases() == []
    end
  end

  describe "authorize/3 (owner-only)" do
    test "operator passes; missing authorization fails closed" do
      ctx = %{authorization: %IngressAuthorization{role: :operator, trust: :operator}}
      assert :ok = Pause.authorize(message(), %{}, ctx)
      assert :ok = Resume.authorize(message(), %{}, ctx)
      assert {:error, :unauthorized} = Pause.authorize(message(), %{}, %{})
      assert {:error, :unauthorized} = Resume.authorize(message(), %{}, %{})
    end
  end

  describe "execute/3 with no running session" do
    # Computer-use isn't running in this async test, so the facade reports
    # :no_session and the command replies with the friendly no-op copy.
    test "pause reports no active session" do
      ctx = %{conversation_key: {"telegram", "c1", :root}}
      assert :ok = Pause.execute(message(), reply_fn(self()), ctx)
      assert_receive {:reply, "No active computer-use session to pause."}
    end

    test "resume reports no paused session" do
      ctx = %{conversation_key: {"telegram", "c1", :root}}
      assert :ok = Resume.execute(message(), reply_fn(self()), ctx)
      assert_receive {:reply, "No paused computer-use session to resume."}
    end
  end
end
