defmodule FermixCore.SoulCuration.UnreviewedEditNoticeTest do
  use ExUnit.Case, async: true

  alias FermixCore.SoulCuration.UnreviewedEditNotice

  # Adapters are modules, so the recording one reports to the test process
  # through a name only this test module registers.
  defmodule RecordingChannel do
    @recipient FermixCore.SoulCuration.UnreviewedEditNoticeTest

    def send_message(destination, text, _opts) do
      send(@recipient, {:sent, destination, text})
      :ok
    end
  end

  @event %{path: "/home/owner/.fermix/bootstrap/main/SOUL.md", revision: 4}

  setup do
    FermixTestSupport.NamedTest.register!(__MODULE__)
    :ok
  end

  test "the line names the new revision and the /soul command that undoes it" do
    text = UnreviewedEditNotice.text(@event)

    assert text =~ "SOUL.md changed on disk outside /soul"
    assert text =~ "revision 4"
    assert text =~ "/soul revert 3"
    assert text =~ "/soul history"
  end

  test "deliver sends the line to the owner's private inbox" do
    assert :ok =
             UnreviewedEditNotice.deliver(@event,
               configured_owners: %{"telegram" => "owner-1"},
               jobs_config: [],
               adapter: RecordingChannel
             )

    expected = UnreviewedEditNotice.text(@event)
    assert_received {:sent, "owner-1", ^expected}
  end

  # M106 §8, D3: with a phone paired the owner's inbox is the Fermix app's
  # chat; `/soul revert` is typed there as anywhere else.
  test "with a phone paired deliver sends the line to the app's chat" do
    assert :ok =
             UnreviewedEditNotice.deliver(
               @event,
               FermixTestSupport.AppInbox.opts() ++ [adapter: RecordingChannel]
             )

    expected = UnreviewedEditNotice.text(@event)
    assert_received {:sent, "main", ^expected}
  end

  test "deliver never falls back to a group chat when no owner inbox exists" do
    assert :no_delivery_target =
             UnreviewedEditNotice.deliver(@event,
               configured_owners: %{},
               jobs_config: [default_delivery_target: [channel: "telegram", chat_id: "group-7"]],
               adapter: RecordingChannel
             )

    refute_received {:sent, _destination, _text}
  end
end
