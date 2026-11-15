defmodule FermixChannels.Channels.IMessage.CapabilityTest do
  @moduledoc """
  `imessage` (M97 §6.4) as both ends read it: which calls are effects, what
  the server may never ask, what a request may carry, what the journal is
  told, and which origins may send.
  """
  use ExUnit.Case, async: true

  alias FermixChannels.Channels.IMessage.Capability

  defp request(method, params \\ %{}, extra \\ %{}),
    do: Map.merge(%{"method" => method, "params" => params, "timeout_ms" => 15_000}, extra)

  test "a send is an effect, never sent twice; every other call and the watch are reads" do
    assert Capability.effect?("imessage.send")
    refute Capability.effect?("imessage.call")
    refute Capability.effect?("imessage.watch")
    assert Capability.long_lived?("imessage.watch")
    refute Capability.long_lived?("imessage.send")
    assert Capability.methods("imessage.send") == ["send.text", "send.file"]
    assert "attachment.fetch" in Capability.methods("imessage.call")
  end

  test "each operation carries only its own methods" do
    assert :ok = Capability.validate("imessage.call", request("probe"))

    assert :ok =
             Capability.validate("imessage.send", request("send.text", %{"to" => "+15550100"}))

    assert {:error, _sentence} = Capability.validate("imessage.call", request("send.text"))
    assert {:error, _sentence} = Capability.validate("imessage.send", request("messages.after"))
  end

  test "policy.set, grant, initialize and shutdown are never the server's to ask" do
    assert {:error, sentence} = Capability.validate("imessage.call", request("policy.set"))
    assert sentence == Capability.policy_sentence()
    assert {:error, ^sentence} = Capability.validate("imessage.send", request("policy.set"))

    for method <- ~w(grant initialize shutdown) do
      assert {:error, refused} = Capability.validate("imessage.call", request(method))
      assert refused =~ method
    end
  end

  test "a request names a bounded timeout, and a file only by its name" do
    assert {:error, _} =
             Capability.validate("imessage.call", request("probe", %{}, %{"timeout_ms" => 0}))

    assert {:error, _} =
             Capability.validate(
               "imessage.call",
               request("probe", %{}, %{"timeout_ms" => 180_001})
             )

    assert :ok =
             Capability.validate(
               "imessage.send",
               request("send.file", %{}, %{"file_name" => "chart.png"})
             )

    for name <- ["../chart.png", "folder/chart.png", ".", ""] do
      assert {:error, _} =
               Capability.validate(
                 "imessage.send",
                 request("send.file", %{}, %{"file_name" => name})
               )
    end

    assert {:error, _} =
             Capability.validate("imessage.call", request("probe", %{}, %{"path" => "/etc"}))
  end

  test "the watch names the last event it took and the watch it took it from" do
    assert :ok = Capability.validate("imessage.watch", %{"after" => nil, "boot" => nil})
    assert :ok = Capability.validate("imessage.watch", %{"after" => 12, "boot" => "abc"})
    assert {:error, _} = Capability.validate("imessage.watch", %{"after" => "12", "boot" => nil})
    assert Capability.deadline_ms("imessage.watch", %{}) == 0
    assert Capability.deadline_ms("imessage.send", request("send.text")) == 20_000
  end

  test "the journal is told a method and a shortened handle, never the text" do
    send_text = request("send.text", %{"to" => "+15551234567", "text" => "meet at the pier at 6"})

    assert Capability.target("imessage.send", send_text) == "send.text to +1555…4567"
    assert Capability.target("imessage.call", request("probe")) == "probe"
    assert Capability.target("imessage.watch", %{"after" => 1, "boot" => "b"}) == "imessage.watch"

    email = request("send.text", %{"to" => "friend@example.org", "text" => "hi"})
    assert Capability.target("imessage.send", email) == "send.text to f…@example.org"
  end

  # Unattended turns send (a reply nobody watches, a reminder at its hour);
  # a delegated worker's reply goes through the turn that started it.
  test "every turn's origin may send except a delegated worker's" do
    for origin <- [:chat, :voice, :scheduled, :cue, :background] do
      assert :ok = Capability.admit("imessage.send", %{}, %{origin: origin})
    end

    assert {:refused, :unavailable, sentence} =
             Capability.admit("imessage.send", %{}, %{origin: :worker})

    assert sentence =~ "delegated worker"
    assert :ok = Capability.admit("imessage.call", %{}, %{origin: :worker})
  end

  test "a file is never larger than the invocation's part" do
    assert Capability.bounds("imessage.call").part_bytes == 20 * 1_024 * 1_024
    assert Capability.bounds("imessage.send").part_bytes == 0
    assert Capability.max_part_bytes() == 20 * 1_024 * 1_024
  end
end
