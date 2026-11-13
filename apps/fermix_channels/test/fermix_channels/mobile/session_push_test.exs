defmodule FermixChannels.Mobile.SessionPushTest do
  # M99 §14: what a phone's session tells it of Web Push, and how it stores
  # the phone's one push registration. The live codec reads and writes every
  # frame; the crypto passes plaintext through, and the device store is a
  # process of the test's own that keeps one row as the store writes it.
  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.Session

  @peer {10, 0, 0, 9}
  # webpush_vectors.json's sender key, and its phone's key and secret.
  @key "BOC040NY-Wa7NnlnRwJhanrMzTYWTN_8UoR4WcB_BhPV-5yD87nEpL76jaSvM5r5n_BtHMUhI0dsbjmnfXMuFws"
  @subscription %{
    "service" => "fcm",
    "token" => "dK3vQ8pLmX2:APA91bH7xZ_qR4tWv9yN-cE1sJ6uMkT0aLgB5oPiFdShV3nYw",
    "p256dh" =>
      "BA-tjEx2wOT1eHWq5MqZhSnLAWPkYti3100PmZD9lbt_6TM7fBWzl6NLxE5ZSS70gcsibTTIqjHkNTQeZP5yKRI",
    "auth" => "kG0joyQGxf9iMIqP95PJlw"
  }
  @cleared %{push_token: nil, push_service: nil, push_p256dh: nil, push_auth: nil}

  describe "hello_ack" do
    test "at 3 it names webpush, after apns when APNs runs, and carries the home's key" do
      for {services, told} <- [{[], ["webpush"]}, {["apns"], ["apns", "webpush"]}] do
        {[ack], _ready} = hello(3, web_push_key: @key, push_services: services)

        assert header(ack)["caps"]["push"] == told
        assert header(ack)["push_key"] == @key
      end
    end

    test "at 2 it is what it was before Web Push, byte for byte, key or no key" do
      for services <- [[], ["apns"]] do
        {[keyed], _ready} = hello(2, web_push_key: @key, push_services: services)
        {[before], _ready} = hello(2, push_services: services)

        assert same_but_session_id(keyed, before)
        assert header(keyed)["caps"]["push"] == services
        refute Map.has_key?(header(keyed), "push_key")
      end
    end

    test "with no key it names no webpush at 3 either, and carries no key" do
      for services <- [[], ["apns"]] do
        {[ack], _ready} = hello(3, push_services: services)

        assert header(ack)["caps"]["push"] == services
        refute Map.has_key?(header(ack), "push_key")
      end
    end
  end

  test "pair_approved names webpush at 3 when the home has its key, and never at 2" do
    for {version, key, told} <- [
          {3, @key, ["apns", "webpush"]},
          {3, nil, ["apns"]},
          {2, @key, ["apns"]},
          {2, nil, ["apns"]}
        ] do
      {:ok, state} = pairing_state(version, key)
      decision = {:mobile_pair_decision, "pair-session", {:ok, new_device()}}

      assert {:push, [approved], _state} = Session.handle_info(decision, state)
      assert %{"t" => "pair_approved", "v" => ^version, "push" => ^told} = header(approved)
      refute Map.has_key?(header(approved), "push_key")
    end
  end

  describe "push_subscribe" do
    test "stores the whole subscription once, writes nothing for the same one, and a changed one" do
      {_frames, ready} = hello(3, web_push_key: @key)
      assert_received {:device_updated, %{last_seen: %DateTime{}}}

      assert {:ok, ready} =
               Session.handle_frame(frame(3, "push_subscribe", 2, @subscription), ready)

      assert_received {:device_updated, attrs}
      assert attrs == stored(@subscription)

      assert {:ok, ready} =
               Session.handle_frame(frame(3, "push_subscribe", 3, @subscription), ready)

      refute_received {:device_updated, _attrs}

      changed = %{@subscription | "token" => "eR8wN2:APA91bF-new_token"}
      assert {:ok, _ready} = Session.handle_frame(frame(3, "push_subscribe", 4, changed), ready)
      assert_received {:device_updated, attrs}
      assert attrs == stored(changed)
    end

    # The phone sends it after every hello_ack: the row the hello read is the
    # one it is held to, so a reconnect with nothing new writes nothing.
    test "a reconnect whose row already holds the subscription writes nothing" do
      {_frames, ready} = hello(3, web_push_key: @key, row: stored(@subscription))
      assert_received {:device_updated, %{last_seen: %DateTime{}}}

      assert {:ok, _ready} =
               Session.handle_frame(frame(3, "push_subscribe", 2, @subscription), ready)

      refute_received {:device_updated, _attrs}
    end

    test "each field outside its shape is a malformed frame, and nothing is stored" do
      {_frames, ready} = hello(3, web_push_key: @key)
      assert_received {:device_updated, %{last_seen: %DateTime{}}}

      for {field, value} <- [
            {"service", "apns"},
            {"token", "has spaces"},
            {"p256dh", @subscription["auth"]},
            # 65 bytes whose first is 0x04, and no point on P-256.
            {"p256dh", Base.url_encode64(<<4, 1::256, 1::256>>, padding: false)},
            {"auth", @subscription["p256dh"]}
          ] do
        malformed = frame(3, "push_subscribe", 2, %{@subscription | field => value})

        assert {:stop, {:invalid_field, ^field}, {1002, "mobile protocol error"}, _state} =
                 Session.handle_frame(malformed, ready)
      end

      refute_received {:device_updated, _attrs}
    end

    test "at protocol 2 it is answered as any event protocol 2 does not know" do
      {_frames, ready} = hello(2, web_push_key: @key)

      answers =
        for {type, payload} <- [{"push_subscribe", @subscription}, {"not_an_event", %{}}] do
          assert {:stop, {:unknown_event, ^type}, {1002, "mobile protocol error"}, [error], _} =
                   Session.handle_frame(frame(2, type, 2, payload), ready)

          Map.take(header(error), ~w(v t seq code))
        end

      assert [%{"code" => "unsupported", "v" => 2}, same] = answers
      assert same == hd(answers)
      refute_received {:device_updated, %{push_token: _token}}
    end

    test "a daemon with no key refuses it by name, and the session stays open" do
      {_frames, ready} = hello(3, push_services: ["apns"])

      assert {:push, [error], ready} =
               Session.handle_frame(frame(3, "push_subscribe", 2, @subscription), ready)

      assert %{"t" => "error", "code" => "webpush_unavailable"} = header(error)
      assert ready.phase == :ready
      refute_received {:device_updated, %{push_token: _token}}
    end
  end

  # One registration per phone, the last written winning (M99 §14).
  test "push_register replaces a subscription whole, and push_unregister clears all four" do
    {_frames, ready} = hello(3, web_push_key: @key, push_environment: :production)
    assert_received {:device_updated, %{last_seen: %DateTime{}}}

    assert {:ok, ready} =
             Session.handle_frame(frame(3, "push_subscribe", 2, @subscription), ready)

    assert_received {:device_updated, attrs}
    assert attrs == stored(@subscription)

    register = %{"apns_token" => "0123456789abcdef", "environment" => "production"}
    assert {:ok, ready} = Session.handle_frame(frame(3, "push_register", 3, register), ready)
    assert_received {:device_updated, attrs}
    assert attrs == %{@cleared | push_token: "0123456789abcdef"}

    assert {:ok, ready} =
             Session.handle_frame(frame(3, "push_subscribe", 4, @subscription), ready)

    assert_received {:device_updated, attrs}
    assert attrs == stored(@subscription)

    assert {:ok, _ready} = Session.handle_frame(frame(3, "push_unregister", 5, %{}), ready)
    assert_received {:device_updated, attrs}
    assert attrs == @cleared
  end

  # -- a paired phone's session --------------------------------------------------------

  # A paired phone's session after its hello at `version`: the frames it
  # answered with and the session, ready.
  defp hello(version, overrides) do
    {row, overrides} = Keyword.pop(overrides, :row, %{})
    state = hello_state(store!(row), overrides)

    assert {:push, frames, ready} = Session.handle_frame(hello_frame(version), state)
    assert ready.phase == :ready
    {frames, ready}
  end

  # The row the store holds for the phone, written as `DeviceStore.update/3`
  # writes it: the update's fields over the row, the row answered.
  defp store!(row) do
    store =
      start_supervised!({Agent, fn -> Map.merge(%{device_id: "paired-device"}, row) end},
        id: make_ref()
      )

    test_pid = self()

    fn :store, "paired-device", attrs ->
      send(test_pid, {:device_updated, attrs})
      {:ok, Agent.get_and_update(store, &{Map.merge(&1, attrs), Map.merge(&1, attrs)})}
    end
  end

  defp hello_state(update_device, overrides) do
    {:ok, state} =
      %{
        peer: @peer,
        phase: :await_hello,
        primary_epoch: 3,
        authenticated_device: %{device_id: "paired-device"},
        device_registry: :registry,
        device_store: :store,
        profile_name: "Fermix",
        noise: :noise,
        decrypt: fn :noise, frame -> {:ok, frame, :noise} end,
        encrypt: fn :noise, plaintext -> {:ok, plaintext, :noise} end,
        update_device: update_device,
        attach_socket: fn :registry, "paired-device", _pid, profile_id: "main" -> :ok end,
        authorize_socket: fn :registry, "paired-device", _pid -> :ok end,
        history_head: fn "main" -> {:ok, 0} end,
        read_frontier: fn "main" -> {:ok, 0} end,
        discover: fn -> {:ok, []} end,
        iroh_candidate: fn -> :none end,
        pending_approvals: fn "main" -> [] end,
        schedule_handshake_deadline: fn _message, _delay_ms -> make_ref() end,
        cancel_handshake_deadline: fn _ref -> false end,
        schedule_session_timer: fn _message, _delay_ms -> make_ref() end
      }
      |> Map.merge(Map.new(overrides))
      |> Session.init()

    state
  end

  # A phone the owner is deciding on, its pair request read at `version`.
  defp pairing_state(version, key) do
    Session.init(%{
      peer: @peer,
      phase: :await_pair_decision,
      pairing_session_id: "pair-session",
      primary_epoch: 5,
      negotiated_version: version,
      push_services: ["apns"],
      web_push_key: key,
      noise: :noise,
      encrypt: fn :noise, plaintext -> {:ok, plaintext, :noise} end,
      discover: fn -> {:ok, []} end,
      iroh_candidate: fn -> :none end,
      profile_name: "Fermix",
      schedule_handshake_deadline: fn _message, _delay_ms -> make_ref() end,
      cancel_handshake_deadline: fn _ref -> false end
    })
  end

  defp new_device, do: %{device_id: "new-device", apns_key_salt: <<3::256>>}

  defp hello_frame(version) do
    frame(version, "hello", 1, %{
      "device_id" => "paired-device",
      "app_version" => "1.0.0",
      "last_server_seq" => 0,
      "protocol_v" => version
    })
  end

  defp frame(version, type, seq, payload) do
    json = payload |> Map.merge(%{"v" => version, "t" => type, "seq" => seq}) |> Jason.encode!()
    <<byte_size(json)::32, json::binary>>
  end

  defp header(<<size::32, json::binary-size(size), _bytes::binary>>), do: Jason.decode!(json)

  # The subscription as the store holds it: its two keys decoded.
  defp stored(subscription) do
    %{
      push_token: subscription["token"],
      push_service: subscription["service"],
      push_p256dh: Base.url_decode64!(subscription["p256dh"], padding: false),
      push_auth: Base.url_decode64!(subscription["auth"], padding: false)
    }
  end

  # Two hello_acks differ only in their random session id, which has one
  # length, so the bytes match once one id stands in for the other.
  defp same_but_session_id(frame, other) do
    String.replace(frame, header(frame)["session_id"], header(other)["session_id"]) == other
  end
end
