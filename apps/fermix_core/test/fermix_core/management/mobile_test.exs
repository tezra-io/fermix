defmodule FermixCore.Management.MobileTest do
  @moduledoc """
  The `mobile.*` adapter: the atom-keyed facts the phone channel answers with
  become the fixed-record wire, and every sentence on it is this module's.

  The provider is a fake that answers whatever the case hands it through the
  provider's own options, so no case starts the phone channel or reads global
  state.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias FermixCore.Management.Mobile

  defmodule FakeProvider do
    @moduledoc false

    def status(opts), do: answer(opts)
    def pair_start(opts), do: answer(opts)
    def pair_get(_session_id, opts), do: answer(opts)
    def pair_decide(_session_id, _approved, opts), do: answer(opts)
    def pair_cancel(_session_id, opts), do: answer(opts)
    def devices_list(opts), do: answer(opts)
    def devices_revoke(_device_id, opts), do: answer(opts)
    def apply_enabled(_enabled?, opts), do: answer(opts)

    defp answer(opts) do
      case Keyword.fetch!(opts, :reply) do
        reply when is_function(reply, 0) -> reply.()
        reply -> reply
      end
    end
  end

  @endpoint_id "79b5562e8fe654f94078b112e8a98ba7901f853ae695bed7e0e3910bad049664"
  @session_id "5b0c7d2e-8f41-4a6b-9c3d-2e7f1a8b4c60"
  @device_id "3f4a1a55-69a0-4f8a-9132-17d6ac728f84"
  @session_keys ~w(failure outcome request session_id state ttl_ms)
  @request_keys ~w(app_version attestation boot_state build_role device_name model platform sas)
  @device_keys ~w(boot_state created_at device_id last_seen model name platform push_registered
                  signer_role)
  @unavailable {:error, {:unavailable, "mobile"}}

  # The switch is live (M51 §5.5): settings call this once the switch is
  # written, and publish its sentence when the channel did not follow it.
  describe "apply_enabled/2" do
    test "a channel that started or stopped answers ok" do
      assert Mobile.apply_enabled(true, fake({:ok, :started})) == :ok
      assert Mobile.apply_enabled(false, fake({:ok, :stopped})) == :ok
    end

    test "a channel that did not follow its switch answers the daemon's sentence" do
      assert {:error, not_started} = Mobile.apply_enabled(true, fake({:ok, :not_started}))
      assert not_started == "The phone channel is on but could not start. See the daemon log."

      assert {:error, not_ready} = Mobile.apply_enabled(true, fake({:error, :not_ready}))
      assert not_ready == "The phone channel starts the next time Fermix starts."

      assert {:error, waiting} = Mobile.apply_enabled(true, fake({:error, :waiting_for_setup}))
      assert waiting == "The phone channel starts once setup is finished."

      for sentence <- [not_started, not_ready, waiting],
          do: assert(sentence in Mobile.sentences())
    end

    test "a failure is logged and answered with a fixed sentence" do
      log =
        capture_log(fn ->
          assert {:error, sentence} = Mobile.apply_enabled(true, fake({:error, {:boom, "/x"}}))

          assert sentence ==
                   "The phone channel's switch could not be applied. See the daemon log."

          assert sentence in Mobile.sentences()
        end)

      assert log =~ "apply_enabled"
      assert {:error, _sentence} = Mobile.apply_enabled(true, provider: nil)
    end
  end

  describe "the session view" do
    test "every state renders every field, null where it does not apply" do
      for {state, session} <- every_state() do
        assert {:ok, view} = Mobile.pair_get(@session_id, fake({:ok, session}))

        assert Enum.sort(Map.keys(view)) == @session_keys, "#{state} is not a fixed record"
        assert view["state"] == Atom.to_string(state)
        assert view["session_id"] == @session_id
      end
    end

    test "a window with no phone yet has a countdown and nothing else" do
      assert {:ok, view} = Mobile.pair_get(@session_id, fake({:ok, session(:awaiting_scan)}))

      assert view == %{
               "session_id" => @session_id,
               "state" => "awaiting_scan",
               "ttl_ms" => 112_000,
               "request" => nil,
               "outcome" => nil,
               "failure" => nil
             }
    end

    test "a waiting phone carries its request and what its attestation proved" do
      session = session(:awaiting_decision, request: request())

      assert {:ok, view} = Mobile.pair_get(@session_id, fake({:ok, session}))

      assert Enum.sort(Map.keys(view["request"])) == @request_keys

      assert view["request"] == %{
               "device_name" => "Sam's phone",
               "model" => "Google Pixel 9 Pro",
               "platform" => "android",
               "app_version" => "1.0.0",
               "sas" => "481062",
               "build_role" => "development",
               "boot_state" => %{"verified" => true, "locked" => true},
               "attestation" => %{
                 "status" => "verified",
                 "sentence" => "Secure hardware, locked bootloader, official Fermix build."
               }
             }

      assert view["outcome"] == nil and view["failure"] == nil
    end

    # The fields a verified phone carries are published as given.
    test "a request's platform, build role and boot state are published as given" do
      verified =
        request()
        |> Map.merge(%{
          platform: "android",
          build_role: :release,
          boot_state: %{verified: true, locked: false}
        })

      session = session(:awaiting_decision, request: verified)
      assert {:ok, %{"request" => request}} = Mobile.pair_get(@session_id, fake({:ok, session}))

      assert request["platform"] == "android"
      assert request["build_role"] == "release"
      assert request["boot_state"] == %{"verified" => true, "locked" => false}
    end

    test "an approved session names the paired device and keeps the request" do
      session =
        session(:approved, ttl_ms: nil, request: request(), outcome: %{device_id: @device_id})

      assert {:ok, view} = Mobile.pair_decide(@session_id, true, fake({:ok, session}))

      assert view["outcome"] == %{"device_id" => @device_id, "reason" => nil}
      assert view["ttl_ms"] == nil
      assert view["request"]["sas"] == "481062"
    end

    test "a denied, expired or cancelled session names its reason and no device" do
      for {state, reason} <- [denied: :denied, expired: :timeout, cancelled: :cancelled] do
        session = session(state, ttl_ms: nil, outcome: %{reason: reason})

        assert {:ok, view} = Mobile.pair_cancel(@session_id, fake({:ok, session}))

        assert view["outcome"] == %{"device_id" => nil, "reason" => Atom.to_string(reason)}
        assert view["failure"] == nil
      end
    end

    test "a failed session carries the daemon's own sentence for each reason" do
      refused = "The phone's secure-hardware proof was refused: "

      failures = [
        {%{reason: :device_disconnected}, "refused",
         "The phone disconnected before you decided. Start pairing again."},
        {%{reason: :attestation, check: :key}, "refused",
         refused <> "the key it proved is not the key it connected with."},
        {%{reason: :attestation, check: :chain}, "refused",
         refused <> "it is not signed by Google's attestation root."},
        {%{reason: :attestation, check: :key_properties}, "refused",
         refused <> "its key was not made in the phone's secure hardware for this use."},
        {%{reason: :attestation, check: :challenge}, "refused",
         refused <> "it was not made for this pairing."},
        {%{reason: :attestation, check: :root_of_trust}, "refused",
         refused <> "the phone's bootloader is unlocked or its system is not verified."},
        {%{reason: :attestation, check: :application}, "refused",
         refused <> "the app is not an official Fermix build."},
        {%{reason: :attestation, check: :revocation}, "refused",
         refused <> "Google revoked one of its certificates, or one has expired."},
        {%{reason: :platform_unsupported, check: :platform}, "refused",
         refused <> "only an Android phone can pair."},
        {%{reason: :attestation_unavailable, check: :revocation}, "unavailable",
         "Google's attestation service could not be reached."}
      ]

      for {failure, code, sentence} <- failures do
        session = session(:failed, ttl_ms: nil, failure: failure)

        assert {:ok, view} = Mobile.pair_get(@session_id, fake({:ok, session}))

        assert view["failure"] == %{"code" => code, "sentence" => sentence}
        assert view["outcome"] == nil
        assert view["request"] == nil
        assert sentence in Mobile.sentences()
      end
    end

    # Only a verified phone reaches the owner, so a request whose attestation
    # is anything else is a defect between the two apps, refused loudly.
    test "a request whose attestation was not verified is refused loudly" do
      for attestation <- [:unavailable, :refused] do
        session = session(:awaiting_decision, request: %{request() | attestation: attestation})

        assert_raise FunctionClauseError, fn ->
          Mobile.pair_get(@session_id, fake({:ok, session}))
        end
      end
    end

    # A failed handshake refuses only its own address and never ends a window,
    # so no session fails as rate limited, and the adapter publishes no word
    # for it.
    test "a failure reason the channel never produces is refused loudly" do
      session = session(:failed, ttl_ms: nil, failure: %{reason: :rate_limited})

      assert_raise FunctionClauseError, fn ->
        Mobile.pair_get(@session_id, fake({:ok, session}))
      end
    end
  end

  describe "opening the pairing window" do
    test "answers the session plus the pairing link, once" do
      uri = "fermix://pair?v=2&secret=EXAMPLE"
      reply = {:ok, %{session: session(:awaiting_scan, ttl_ms: 120_000), uri: uri}}

      assert {:ok, view} = Mobile.pair_start(fake(reply))

      assert Enum.sort(Map.keys(view)) == Enum.sort(["uri" | @session_keys])
      assert view["uri"] == uri
      assert view["state"] == "awaiting_scan"
      assert view["ttl_ms"] == 120_000
    end

    test "a window already open is busy, and nothing else is" do
      assert Mobile.pair_start(fake({:error, :pairing_active})) ==
               {:error, {:busy, "mobile.pair"}}
    end

    # Nothing was opened, so there is no session to poll and no link to show:
    # the refusal is a failed view carrying the sentence, not an envelope.
    test "a refusal with a sentence is a failed view that opened nothing" do
      refusals = [
        mobile_disabled: {"unavailable", "The mobile channel is turned off."},
        mobile_surface_refused:
          {"unavailable", "The mobile channel could not start this boot. See the daemon log."},
        mobile_not_started:
          {"unavailable",
           "The mobile channel has not started yet. Restart Fermix to apply the change."},
        mobile_waiting_for_setup:
          {"unavailable", "The phone channel starts once setup is finished."},
        identity_unavailable:
          {"refused", "The gateway identity files are incomplete; nothing was regenerated."},
        listener_unavailable:
          {"internal_error", "The phone listener could not start. See the daemon log."},
        device_store_unavailable:
          {"internal_error", "The paired-device list could not be read. See the daemon log."}
      ]

      for {reason, {code, sentence}} <- refusals do
        assert {:ok, view} = Mobile.pair_start(fake({:error, reason}))
        assert view == failed_start(code, sentence), "#{reason} did not answer a failed view"
      end
    end

    test "any other refusal is logged and answered with the fixed sentence" do
      log =
        capture_log(fn ->
          assert {:ok, view} = Mobile.pair_start(fake({:error, {:enoent, "/Users/sam/.fermix"}}))

          assert view ==
                   failed_start(
                     "internal_error",
                     "The pairing window could not be opened. See the daemon log."
                   )
        end)

      assert log =~ "pairing window refused"
      assert log =~ ":enoent"
    end

    test "a malformed success is refused without logging the link it carried" do
      no_session = %{uri: "fermix://pair?secret=SHOULD-NOT-LOG"}
      oversized = %{session: session(:awaiting_scan), uri: String.duplicate("x", 2_049)}

      log =
        capture_log(fn ->
          assert Mobile.pair_start(fake({:ok, no_session})) == @unavailable
          assert Mobile.pair_start(fake({:ok, oversized})) == @unavailable
        end)

      refute log =~ "SHOULD-NOT-LOG"
      assert log =~ "pair_start answered a shape"
    end
  end

  describe "refusals on an open session" do
    test "a session this daemon does not retain names the id it was asked for" do
      reply = {:error, :unknown_pairing_session}

      assert Mobile.pair_get("0d9e8f7a-6b5c-4d3e-8f2a-1b0c9d8e7f6a", fake(reply)) ==
               {:error, {:unknown_pairing_session, "0d9e8f7a-6b5c-4d3e-8f2a-1b0c9d8e7f6a"}}

      assert Mobile.pair_decide("0d9e8f7a-6b5c-4d3e-8f2a-1b0c9d8e7f6a", false, fake(reply)) ==
               {:error, {:unknown_pairing_session, "0d9e8f7a-6b5c-4d3e-8f2a-1b0c9d8e7f6a"}}

      assert Mobile.pair_cancel("0d9e8f7a-6b5c-4d3e-8f2a-1b0c9d8e7f6a", fake(reply)) ==
               {:error, {:unknown_pairing_session, "0d9e8f7a-6b5c-4d3e-8f2a-1b0c9d8e7f6a"}}
    end

    test "a decision with no phone waiting is refused in the daemon's words" do
      assert Mobile.pair_decide(@session_id, true, fake({:error, :request_missing})) ==
               {:error, {:invalid_params, "session_id", "No phone is waiting for a decision."}}
    end

    test "a channel that is off, refused this boot, or not started yet cannot answer" do
      for reason <- [
            :mobile_disabled,
            :mobile_surface_refused,
            :mobile_not_started,
            :mobile_waiting_for_setup
          ] do
        assert Mobile.pair_get(@session_id, fake({:error, reason})) == @unavailable
        assert Mobile.pair_decide(@session_id, true, fake({:error, reason})) == @unavailable
        assert Mobile.pair_cancel(@session_id, fake({:error, reason})) == @unavailable
        assert Mobile.devices_revoke(@device_id, fake({:error, reason})) == @unavailable
      end
    end

    test "a refusal the contract does not name is logged and answered unavailable" do
      log =
        capture_log(fn ->
          assert Mobile.pair_decide(@session_id, true, fake({:error, :surprise})) == @unavailable
        end)

      assert log =~ "pair_decide refused"
    end
  end

  describe "the paired devices" do
    test "every row is a fixed record" do
      assert {:ok, %{"devices" => [row]}} = Mobile.devices_list(fake({:ok, [device()]}))

      assert Enum.sort(Map.keys(row)) == Enum.sort(@device_keys)

      assert row == %{
               "device_id" => @device_id,
               "name" => "Sam's phone",
               "model" => "Google Pixel 9 Pro",
               "platform" => nil,
               "signer_role" => nil,
               "boot_state" => nil,
               "push_registered" => false,
               "created_at" => "2026-09-26T12:01:05Z",
               "last_seen" => nil
             }
    end

    test "no paired phone is an empty list, not a refusal" do
      assert Mobile.devices_list(fake({:ok, []})) == {:ok, %{"devices" => []}}
    end

    test "a list above the published bound is refused rather than truncated" do
      devices = List.duplicate(device(), 65)

      capture_log(fn ->
        assert Mobile.devices_list(fake({:ok, devices})) == @unavailable
      end)
    end

    test "a revoke answers the id, and an unknown id is refused in the daemon's words" do
      assert Mobile.devices_revoke(@device_id, fake({:ok, %{device_id: @device_id}})) ==
               {:ok, %{"device_id" => @device_id, "revoked" => true}}

      assert Mobile.devices_revoke("nope", fake({:error, :device_not_found})) ==
               {:error, {:invalid_params, "device_id", "No paired phone has that id."}}
    end
  end

  describe "the channel status" do
    test "every field is published, with the pairing session in flight" do
      assert {:ok, view} = Mobile.status(fake({:ok, status()}))

      assert view == %{
               "enabled" => true,
               "started" => true,
               "refused" => false,
               "refusal" => nil,
               "hold" => nil,
               "listener" => %{
                 "status" => "ready",
                 "reason" => nil,
                 "port" => 4031,
                 "bind" => "0.0.0.0",
                 "candidates" => ["wss://192.168.1.20:4031/ws"]
               },
               "mdns" => "advertising",
               "tailnet" => %{"detected" => false, "candidates" => []},
               "identity" => %{"present" => true, "fingerprint" => "3f9a 1c2e"},
               "apns" => %{
                 "enabled" => false,
                 "credentials" => "missing",
                 "delivery" => "down",
                 "reason" => nil
               },
               "fcm" => %{
                 "enabled" => false,
                 "credentials" => "missing",
                 "delivery" => "down",
                 "reason" => nil
               },
               "remote" => %{
                 "state" => "ready",
                 "endpoint_id" => @endpoint_id,
                 "relay" => "https://us1.relay.fermix.ai/",
                 "connected" => true,
                 "relay_error" => nil,
                 "failure" => nil,
                 "refused" => %{"busy" => 0, "alpn" => 0, "bridge_unreachable" => 0}
               },
               "paired_devices" => 1,
               "protocol_version" => 1,
               "pairing" => %{"session_id" => @session_id, "state" => "awaiting_decision"}
             }
    end

    # Reach from anywhere (M62) is said as the rail reports it: switched off it
    # is `off` with nothing else, and a failed rail carries the helper's words.
    test "reach from anywhere is published off, or failed in the helper's words" do
      off = Map.put(status(), :remote, %{state: :off})
      assert {:ok, %{"remote" => remote}} = Mobile.status(fake({:ok, off}))

      assert remote == %{
               "state" => "off",
               "endpoint_id" => nil,
               "relay" => nil,
               "connected" => false,
               "relay_error" => nil,
               "failure" => nil,
               "refused" => %{"busy" => 0, "alpn" => 0, "bridge_unreachable" => 0}
             }

      failed =
        Map.put(status(), :remote, %{
          state: :failed,
          failure: "fermix-iroh speaks protocol 2; this Fermix speaks 1",
          refused: %{busy: 2, alpn: 1, bridge_unreachable: 0}
        })

      assert {:ok, %{"remote" => remote}} = Mobile.status(fake({:ok, failed}))
      assert remote["state"] == "failed"
      assert remote["failure"] == "fermix-iroh speaks protocol 2; this Fermix speaks 1"
      assert remote["refused"] == %{"busy" => 2, "alpn" => 1, "bridge_unreachable" => 0}
    end

    test "a channel that is off still answers, with no pairing and no identity" do
      off =
        status()
        |> Map.merge(%{enabled: false, started: false, mdns: :disabled, pairing: nil})
        |> Map.put(:identity, %{present: false, fingerprint: nil})

      assert {:ok, view} = Mobile.status(fake({:ok, off}))

      assert view["enabled"] == false
      assert view["refused"] == false
      assert view["pairing"] == nil
      assert view["identity"] == %{"present" => false, "fingerprint" => nil}
      assert view["mdns"] == "disabled"
    end

    test "a surface refused this boot is published as refused, not as off" do
      refused =
        Map.merge(status(), %{started: false, refused: true, refusal: :trust_store, pairing: nil})

      assert {:ok, view} = Mobile.status(fake({:ok, refused}))

      assert view["enabled"] == true
      assert view["started"] == false
      assert view["refused"] == true
      assert view["refusal"] == "trust_store"
    end

    # A boot whose setup was not finished registers no transport: the channel is
    # on, not running and not refused, and what it waits for is published.
    test "a channel held until setup is finished is published as held for setup" do
      held = Map.merge(status(), %{started: false, hold: :setup, pairing: nil})

      assert {:ok, view} = Mobile.status(fake({:ok, held}))
      assert view["enabled"] == true
      assert view["started"] == false
      assert view["refused"] == false
      assert view["hold"] == "setup"
    end

    # STB-16: memory off refuses the surface, and the refusal is named.
    test "each refusal class is published by its word" do
      for word <- ~w(memory_disabled identity attachment_manifest trust_store)a do
        refused = Map.merge(status(), %{started: false, refused: true, refusal: word})
        assert {:ok, %{"refusal" => published}} = Mobile.status(fake({:ok, refused}))
        assert published == Atom.to_string(word)
      end
    end

    # STB-6: a listener that cannot bind stays up and says why.
    test "a listener that cannot bind is published as unavailable with its reason" do
      for reason <- ~w(address_unavailable address_in_use permission_denied listen_failed)a do
        listener = %{status(:listener) | status: :unavailable, reason: reason}
        assert {:ok, view} = Mobile.status(fake({:ok, %{status() | listener: listener}}))
        assert view["listener"]["status"] == "unavailable"
        assert view["listener"]["reason"] == Atom.to_string(reason)
      end
    end

    # STB-5: APNs unreachable degrades push rather than stopping the channel.
    # R1-9: a connect under way is its own reason.
    test "push delivery is published as ready, degraded with its reason, or down" do
      for {delivery, reason} <- [
            ready: nil,
            degraded: :connecting,
            degraded: :connect_failed,
            degraded: :connection_lost,
            down: nil
          ] do
        apns = %{enabled: true, credentials: :ready, delivery: delivery, reason: reason}
        assert {:ok, view} = Mobile.status(fake({:ok, %{status() | apns: apns}}))

        assert view["apns"] == %{
                 "enabled" => true,
                 "credentials" => "ready",
                 "delivery" => Atom.to_string(delivery),
                 "reason" => reason && Atom.to_string(reason)
               }
      end
    end

    # M51 §10: FCM keeps no connection; its last batch says how it is doing.
    test "FCM delivery is published as ready, degraded with its reason, or down" do
      for {delivery, reason} <- [
            ready: nil,
            degraded: :auth_failed,
            degraded: :unreachable,
            down: nil
          ] do
        fcm = %{enabled: true, credentials: :ready, delivery: delivery, reason: reason}
        assert {:ok, view} = Mobile.status(fake({:ok, %{status() | fcm: fcm}}))

        assert view["fcm"] == %{
                 "enabled" => true,
                 "credentials" => "ready",
                 "delivery" => Atom.to_string(delivery),
                 "reason" => reason && Atom.to_string(reason)
               }
      end
    end
  end

  describe "a provider that cannot answer" do
    test "no provider at all is the capability being unavailable" do
      capture_log(fn ->
        assert Mobile.status(provider: nil) == @unavailable
        assert Mobile.pair_start(provider: nil) == @unavailable
      end)
    end

    test "a provider without the function is unavailable rather than a crash" do
      capture_log(fn ->
        assert Mobile.pair_get(@session_id, provider: Enum) == @unavailable
        assert Mobile.devices_list(provider: Enum) == @unavailable
      end)
    end

    # The pairing manager is a process in another app. Its exit reason names that
    # app's internals, so it goes to the log and never onto the wire.
    test "a call that exits is logged, redacted, and answered unavailable" do
      exits = fn -> exit({:timeout, {GenServer, :call, [:pair_manager, :status]}}) end

      log =
        capture_log(fn ->
          assert Mobile.status(fake(exits)) == @unavailable
        end)

      assert log =~ "status exited"
      assert log =~ ":timeout"
    end
  end

  test "the channel-off sentence a client can name the switch for is the published one" do
    assert Mobile.off_sentence() == "The mobile channel is turned off."
    assert Mobile.off_sentence() in Mobile.sentences()
  end

  test "every sentence this module publishes is the one the contract names" do
    assert Mobile.sentences() == [
             "The mobile channel is turned off.",
             "The mobile channel could not start this boot. See the daemon log.",
             "The mobile channel has not started yet. Restart Fermix to apply the change.",
             "The phone channel starts once setup is finished.",
             "The gateway identity files are incomplete; nothing was regenerated.",
             "The phone listener could not start. See the daemon log.",
             "The paired-device list could not be read. See the daemon log.",
             "The pairing window could not be opened. See the daemon log.",
             "The phone disconnected before you decided. Start pairing again.",
             "Secure hardware, locked bootloader, official Fermix build.",
             "The phone's secure-hardware proof was refused: the key it proved is not the key it connected with.",
             "The phone's secure-hardware proof was refused: it is not signed by Google's attestation root.",
             "The phone's secure-hardware proof was refused: its key was not made in the phone's secure hardware for this use.",
             "The phone's secure-hardware proof was refused: it was not made for this pairing.",
             "The phone's secure-hardware proof was refused: the phone's bootloader is unlocked or its system is not verified.",
             "The phone's secure-hardware proof was refused: the app is not an official Fermix build.",
             "The phone's secure-hardware proof was refused: Google revoked one of its certificates, or one has expired.",
             "The phone's secure-hardware proof was refused: only an Android phone can pair.",
             "Google's attestation service could not be reached.",
             "No phone is waiting for a decision.",
             "No paired phone has that id.",
             "Only the owner can pair or forget a phone; run this from your own terminal.",
             "The phone channel is on but could not start. See the daemon log.",
             "The phone channel starts the next time Fermix starts.",
             "The phone channel's switch could not be applied. See the daemon log.",
             "Reach from anywhere is on but could not start. See the daemon log.",
             "Reach from anywhere could not be switched. See the daemon log."
           ]
  end

  defp fake(reply), do: [provider: FakeProvider, reply: reply]

  defp every_state do
    [
      awaiting_scan: session(:awaiting_scan),
      awaiting_decision: session(:awaiting_decision, request: request()),
      approved: session(:approved, ttl_ms: nil, outcome: %{device_id: @device_id}),
      denied: session(:denied, ttl_ms: nil, outcome: %{reason: :denied}),
      expired: session(:expired, ttl_ms: nil, outcome: %{reason: :timeout}),
      cancelled: session(:cancelled, ttl_ms: nil, outcome: %{reason: :cancelled}),
      failed: session(:failed, ttl_ms: nil, failure: %{reason: :device_disconnected})
    ]
  end

  defp session(state, fields \\ []) do
    Map.merge(
      %{
        session_id: @session_id,
        state: state,
        ttl_ms: 112_000,
        request: nil,
        outcome: nil,
        failure: nil
      },
      Map.new(fields)
    )
  end

  defp request do
    %{
      device_name: "Sam's phone",
      model: "Google Pixel 9 Pro",
      platform: "android",
      app_version: "1.0.0",
      sas: "481062",
      build_role: :development,
      boot_state: %{verified: true, locked: true},
      attestation: :verified
    }
  end

  defp device do
    %{
      device_id: @device_id,
      name: "Sam's phone",
      model: "Google Pixel 9 Pro",
      platform: nil,
      signer_role: nil,
      boot_state: nil,
      push_registered: false,
      created_at: "2026-09-26T12:01:05Z",
      last_seen: nil
    }
  end

  defp status do
    %{
      enabled: true,
      started: true,
      refused: false,
      refusal: nil,
      hold: nil,
      listener: %{
        status: :ready,
        reason: nil,
        port: 4031,
        bind: "0.0.0.0",
        candidates: ["wss://192.168.1.20:4031/ws"]
      },
      mdns: :advertising,
      tailnet: %{detected: false, candidates: []},
      identity: %{present: true, fingerprint: "3f9a 1c2e"},
      apns: %{enabled: false, credentials: :missing, delivery: :down, reason: nil},
      fcm: %{enabled: false, credentials: :missing, delivery: :down, reason: nil},
      remote: %{
        state: :ready,
        endpoint_id: @endpoint_id,
        relay: "https://us1.relay.fermix.ai/",
        connected: true,
        relay_error: nil,
        refused: %{busy: 0, alpn: 0, bridge_unreachable: 0}
      },
      paired_devices: 1,
      protocol_version: 1,
      pairing: %{session_id: @session_id, state: :awaiting_decision}
    }
  end

  defp status(:listener), do: status().listener

  defp failed_start(code, sentence) do
    %{
      "session_id" => nil,
      "state" => "failed",
      "ttl_ms" => nil,
      "request" => nil,
      "outcome" => nil,
      "failure" => %{"code" => code, "sentence" => sentence},
      "uri" => nil
    }
  end
end
