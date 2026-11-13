defmodule FermixChannels.Mobile.SessionBlocksTest do
  @moduledoc """
  EVENTS_DRAWN_AS_CARDS §04 and M89 §06 on a phone's session: mobile 3 is
  the version in which a row may carry any number of block types, so every
  frame a session writes leaves by the one filter (`ReplyBlocks.for_session/4`)
  and a session at mobile 2 is sent only `places` and `checklists` blocks,
  wherever a reply reaches it: its `text_done`, its `row` and a history
  page's messages. A phone's turn says it draws events from mobile 3. The
  phone's real `Mobile.Session` runs through the Noise `IK` handshake and
  codec; the trust store's row, the hello's facts and the router a `msg` is
  handed to are stood in for.
  """

  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.DeviceRegistry
  alias FermixChannels.Mobile.Noise
  alias FermixChannels.Mobile.Protocol
  alias FermixChannels.Test.SessionDriver, as: Driver

  @phone_id "7c1e2d3f-4a5b-4c6d-8e7f-9a0b1c2d3e4f"
  @seen ~U[2026-11-12 15:00:00Z]

  @places %{
    "type" => "places",
    "places" => [
      %{"name" => "Example Coffee", "location" => %{"latitude" => 1, "longitude" => 2}}
    ]
  }
  @events %{
    "type" => "events",
    "events" => [
      %{
        "event_id" => "evt_k2m4q7xd3np5rtwa",
        "title" => "Dentist",
        "kind" => "appointment",
        "date" => "2026-11-13",
        "time" => "10:30",
        "timezone" => "America/New_York",
        "status" => "active",
        "change" => "stored",
        "when" => "Friday, November 13 at 10:30 AM EST",
        "reminds" => "1 day and 1 hour before",
        "rings" => "on Telegram"
      }
    ]
  }

  setup do
    suffix = System.unique_integer([:positive])

    registry =
      start_supervised!(
        {DeviceRegistry,
         name: Module.concat(__MODULE__, "Registry#{suffix}"),
         authorize_device: fn _store, id -> {:ok, row(id)} end,
         delete_device: fn _store, _id -> :ok end,
         revoke_requests: fn _id -> :ok end}
      )

    %{gateway: Noise.generate_keypair(), phone: Noise.generate_keypair(), registry: registry}
  end

  describe "a reply's blocks leave by the session's version" do
    test "a phone at mobile 2 is sent no events in a text_done, a row or a history page", ctx do
      {driver, client} = ready_phone!(ctx, 2)
      [done, row, page] = deliver!(driver, client, 2)

      assert done["v"] == 2
      assert done["blocks"] == [@places]
      refute Map.has_key?(row, "blocks")
      assert [%{"blocks" => [@places]}, message] = page["messages"]
      refute Map.has_key?(message, "blocks")
    end

    test "a phone at mobile 3 is sent every block, events included", ctx do
      {driver, client} = ready_phone!(ctx, 3)
      [done, row, page] = deliver!(driver, client, 3)

      assert done["v"] == 3
      assert done["blocks"] == [@places, @events]
      assert row["blocks"] == [@events]
      assert [%{"blocks" => [@places, @events]}, %{"blocks" => [@events]}] = page["messages"]
    end
  end

  describe "what a phone's turn is told it draws" do
    test "events from mobile 3, and nothing at mobile 2 before its lists are pulled", ctx do
      for version <- [2, 3] do
        {driver, client} = ready_phone!(ctx, version)

        msg = %{
          "client_msg_id" => "phone-#{version}",
          "profile_id" => "main",
          "text" => "Remind me about the dentist.",
          "attach_ids" => []
        }

        _client = Driver.client_send_at(driver, client, version, "msg", msg, 2)
        assert_receive {:routed, %{type: "msg"} = routed}, 10_000
        assert Map.get(routed, :draws_events) == (version == 3 || nil)
        refute Map.get(routed, :draws_lists)
      end
    end
  end

  # The three exits of a reply, handed to the session as the device registry
  # hands it a broadcast, and each frame it writes, decoded.
  defp deliver!(driver, client, version) do
    done = %{
      "t" => "text_done",
      "turn_id" => "turn-phone-1",
      "server_seq" => 41,
      "text" => "Done.",
      "ts" => "2026-11-12T15:05:12.000000Z",
      "blocks" => [@places, @events]
    }

    row = %{
      "t" => "row",
      "profile_id" => "main",
      "server_seq" => 42,
      "role" => "assistant",
      "text" => "Moved.",
      "ts" => "2026-11-12T15:06:00.000000Z",
      "media_refs" => [],
      "blocks" => [@events]
    }

    page = %{
      "t" => "history_page",
      "profile_id" => "main",
      "messages" => [
        message(41, "Done.", [@places, @events]),
        message(42, "Moved.", [@events])
      ],
      "next_after_seq" => 42,
      "history_head_seq" => 42
    }

    {headers, _client} =
      Enum.reduce([done, row, page], {[], client}, fn event, {headers, client} ->
        send(driver, {:mobile_event, event})
        {[{header, <<>>}], client} = Driver.client_receive(driver, client)
        assert header["v"] == version
        {headers ++ [header], client}
      end)

    headers
  end

  defp message(seq, content, blocks) do
    %{
      "server_seq" => seq,
      "role" => "assistant",
      "content" => content,
      "ts" => "2026-11-12T15:05:12.000000Z",
      "media_refs" => [],
      "kind" => "text",
      "blocks" => blocks
    }
  end

  defp ready_phone!(ctx, version) do
    test_pid = self()
    keys = %{ctx.phone.public => @phone_id}

    driver =
      Driver.start!(
        peer: {127, 0, 0, 1},
        gateway_keypair: ctx.gateway,
        primary_epoch: 4,
        device_store: :store,
        device_registry: ctx.registry,
        find_device: fn :store, key -> {:ok, row(Map.fetch!(keys, key))} end,
        update_device: fn :store, id, %{last_seen: _seen} -> {:ok, row(id)} end,
        wall_clock: fn -> @seen end,
        hello_ack_builder: fn _state -> {:ok, hello_ack()} end,
        pending_approvals: fn "main" -> [] end,
        history_head: fn "main" -> {:ok, 0} end,
        read_frontier: fn "main" -> {:ok, 0} end,
        discover: fn -> {:ok, []} end,
        iroh_candidate: fn -> :none end,
        call_caps: fn _device ->
          %{
            "available" => false,
            "reason" => "voice_off",
            "min_version" => 2,
            "max_version" => 3,
            "camera" => false
          }
        end,
        event_router: fn event, _context, _opts ->
          send(test_pid, {:routed, event})
          :ok
        end,
        run_request: &Task.start(&1)
      )

    {:ok, client} =
      Noise.initialize(:initiator, :ik,
        static_keypair: ctx.phone,
        remote_static: ctx.gateway.public
      )

    client = Driver.handshake!(driver, client)

    hello = %{
      "device_id" => @phone_id,
      "app_version" => "0.19.0",
      "last_server_seq" => 0,
      "protocol_v" => version
    }

    client = Driver.client_send_at(driver, client, version, "hello", hello, 1)

    assert {[{%{"t" => "hello_ack", "v" => ^version}, <<>>}], client} =
             Driver.client_receive(driver, client)

    {driver, client}
  end

  defp row(id), do: %{device_id: id, name: "Garden phone", kind: :phone}

  defp hello_ack do
    {min_version, max_version} = Protocol.supported_version_range()

    %{
      "session_id" => "phone-session",
      "min_version" => min_version,
      "max_version" => max_version,
      "profiles" => [%{"id" => "main", "name" => "Fermix"}],
      "candidates" => [],
      "history_head_seq" => 0,
      "read_up_to_seq" => 0,
      "caps" => %{"commands" => [], "max_media_bytes" => 20_971_520, "lists" => true},
      "primary_epoch" => 4
    }
  end
end
