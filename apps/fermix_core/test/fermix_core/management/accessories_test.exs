defmodule FermixCore.Management.AccessoriesTest do
  # The `accessories.*` methods (M91 E3) over a stand-in for the channels
  # app's provider (`AccessoryGoldens.Provider`): every fact is injected, so
  # the projection, the refusals and the wait under test are the daemon's own.
  use ExUnit.Case, async: true

  alias FermixCore.Accessories.Store
  alias FermixCore.Accessories.VoiceDevice
  alias FermixCore.Management.Accessories
  alias FermixCore.Management.Copy
  alias FermixCore.Management.Settings.Voice
  alias FermixTestSupport.AccessoryGoldens, as: Goldens
  alias FermixTestSupport.SafeRm

  defp route(method, params, opts), do: Accessories.route(method, params, opts)

  defp status!(opts) do
    assert {:ok, status} = route("accessories.status", %{}, opts)
    status
  end

  defp with_status(facts, opts \\ []),
    do: Goldens.base(Keyword.put(opts, :provider_opts, status: facts, test: self()))

  defp attached_link(fields \\ %{}) do
    robot = Goldens.record()

    Goldens.link(
      Map.merge(
        %{
          phase: :attached,
          accessory_id: robot.accessory_id,
          kind: "stackchan",
          firmware: "0.1.0",
          wire: 1,
          caps: [:mic, :speaker, :screen, :motion, :battery],
          accessory_state: %{
            battery: nil,
            power: "usb",
            brownout: false,
            volume: 60,
            brightness: 70,
            motion: "off",
            calibration: "missing"
          }
        },
        fields
      )
    )
  end

  describe "where accessories run" do
    test "off, the status says so and every action is refused with its sentence" do
      opts = Goldens.base(enabled?: false)
      status = status!(opts)

      assert status["state"] == "off"
      assert status["sentence"] == "StackChan is off."
      assert status["ports"] == [] and status["call"] == nil

      assert {:error, :unavailable, %{"capability" => "accessories", "sentence" => sentence}} =
               route("accessories.pair.start", %{"path" => "/dev/cu.usbmodem1101"}, opts)

      assert sentence == "StackChan is off."
    end

    test "a device-role engine and a computer that is not a Mac need a local Mac primary" do
      for opts <- [
            Goldens.base(engine_role: %{role: :device, primary: "studio-mac"}),
            Goldens.base(engine_role: %{role: :candidate}),
            Goldens.base(os_type: {:unix, :linux})
          ] do
        status = status!(opts)
        assert status["state"] == "needs_local_primary"
        assert status["sentence"] == "StackChan setup needs a local Mac primary."

        assert {:error, :unavailable,
                %{"sentence" => "StackChan setup needs a local Mac primary."}} =
                 route(
                   "accessories.forget",
                   %{"accessory_id" => Goldens.record().accessory_id},
                   opts
                 )
      end
    end

    test "on but not started this boot asks for a restart" do
      opts =
        Goldens.base(provider_opts: [status: %{running: false, watcher: nil, last_calls: %{}}])

      assert status!(opts)["state"] == "not_running"

      assert {:error, :unavailable, %{"sentence" => sentence}} =
               route("accessories.retry", %{"path" => "/dev/cu.usbmodem1101"}, opts)

      assert sentence =~ "Restart Fermix"
    end

    test "a provider nobody registered reads as not started, never as a crash" do
      opts = Goldens.base(provider: nil)
      assert status!(opts)["state"] == "not_running"
    end
  end

  describe "ports" do
    # M1 finding 3: the app authors no state sentence, the empty list's included.
    test "no port says how to plug the robot in, and a port takes its place" do
      status = status!(with_status(Goldens.running([])))
      assert status["ports"] == []
      assert status["ports_sentence"] == "Plug your StackChan into this Mac with its USB-C cable."

      with_port = status!(with_status(Goldens.running([Goldens.entry(:unrelated)])))
      assert with_port["ports_sentence"] == nil
      assert status!(Goldens.base(enabled?: false))["ports_sentence"] == nil
    end

    test "a port that gave no Fermix answer links the kind's install guide" do
      facts = Goldens.running([Goldens.entry(:no_answer)], selected: "/dev/cu.usbmodem1101")
      [port] = status!(with_status(facts))["ports"]

      assert port["status"] == "needs_firmware"
      assert port["selected"]
      assert port["actions"] == ["open_install_guide", "retry"]

      assert port["install_guide"] ==
               "https://github.com/tezra-io/fermix-stackchan/blob/main/INSTALL.md"

      assert port["sentence"] =~ "isn't running Fermix firmware"
    end

    # Fable review 2: a range that is not two integers names no side.
    test "a robot's wire refusal without its range is not read as newer firmware" do
      link =
        Goldens.link(%{
          phase: :refused,
          refusal: {:accessory, :wire_version},
          refused_range: {nil, nil}
        })

      [port] = status!(with_status(Goldens.running([Goldens.entry(:linked, link)])))["ports"]
      refute port["update"] == "fermix"
      assert port["status"] == "failed"
    end

    test "firmware outside the range names the side to update" do
      newer = Goldens.link(%{phase: :refused, refusal: :wire_version, wire: 2, kind: "stackchan"})
      lacking = Goldens.link(%{phase: :refused, refusal: :capability_missing, wire: 1})

      older =
        Goldens.link(%{
          phase: :refused,
          refusal: {:accessory, :wire_version},
          refused_range: {0, 0},
          wire: nil
        })

      cases = [
        {newer, "fermix", ["update_fermix", "release"]},
        {lacking, "firmware", nil},
        {older, "firmware", nil}
      ]

      for {link, update, actions} <- cases do
        [port] = status!(with_status(Goldens.running([Goldens.entry(:linked, link)])))["ports"]
        assert port["status"] == "incompatible"
        assert port["update"] == update
        if actions, do: assert(port["actions"] == actions)
      end
    end

    test "a busy port says another app holds it and says when it is being opened again" do
      entry = Goldens.entry(:busy, nil, busy: %{attempts: 2, waiting?: true})
      [port] = status!(with_status(Goldens.running([entry])))["ports"]

      assert port["status"] == "busy"
      assert port["retrying"]
      assert port["actions"] == ["retry"]
    end

    test "a robot whose proof failed, or that forgot its pairing, is not paired with this Mac" do
      for link <- [
            Goldens.link(%{phase: :refused, refusal: :bad_proof}),
            Goldens.link(%{phase: :refused, refusal: {:accessory, :unknown_host}}),
            Goldens.link(%{phase: :unenrolled, mode: :attach})
          ] do
        [port] = status!(with_status(Goldens.running([Goldens.entry(:linked, link)])))["ports"]
        assert port["status"] == "not_paired"
        assert port["actions"] == ["pair"]
      end
    end

    # A robot paired with another Mac ignores a pairing request until it
    # forgets that Mac, so Pair alone would only wait.
    test "a robot paired with another Mac says to forget that Mac on the robot first" do
      sentence = fn link ->
        [port] = status!(with_status(Goldens.running([Goldens.entry(:linked, link)])))["ports"]
        port["sentence"]
      end

      elsewhere =
        sentence.(Goldens.link(%{phase: :refused, refusal: {:accessory, :unknown_host}}))

      assert elsewhere =~ "paired with another Mac"
      assert elsewhere =~ "tap Forget"

      for link <- [
            Goldens.link(%{phase: :refused, refusal: :bad_proof}),
            Goldens.link(%{phase: :unenrolled, mode: :attach})
          ] do
        assert sentence.(link) == "This robot isn't paired with this Mac."
      end
    end
  end

  describe "pairing" do
    test "the attempt shows its code, its round and its sentence" do
      status = Goldens.status(Goldens.base() |> Keyword.merge(pairing_opts()))
      pairing = status["pairing"]

      assert pairing["code"] == "382614"
      assert pairing["round"] == 1 and pairing["max_rounds"] == 3
      assert pairing["expires_at"] == "2026-11-08T15:02:00Z"
      assert pairing["sentence"] =~ "should match the code shown here"
      assert [%{"status" => "pairing", "actions" => ["pair_cancel"]}] = status["ports"]
    end

    # M1 finding 2: the pairing that committed names the robot it paired.
    test "a pairing that is done names the robot it paired" do
      id = Goldens.record().accessory_id

      enrollment = %{
        attempt: "5d1f0c2b9a8e47d6b3c1a0f9e8d7c6b5",
        round: 1,
        phase: :done,
        code: "382614",
        accessory_confirmed?: true,
        owner_confirmed?: true,
        closed_reason: nil,
        expires_at: ~U[2026-11-08 15:02:00Z],
        accessory_id: id
      }

      link = Goldens.link(%{mode: :pairing, phase: :hello, enrollment: enrollment})
      facts = Goldens.running([Goldens.entry(:linked, link)], selected: "/dev/cu.usbmodem1101")
      pairing = status!(with_status(facts))["pairing"]

      assert pairing["phase"] == "done"
      assert pairing["accessory_id"] == id
      assert pairing["expires_at"] == nil

      open_pairing = pairing_opts() |> Goldens.base() |> Goldens.status() |> Map.fetch!("pairing")

      assert open_pairing["accessory_id"] == nil
    end

    test "a stale attempt answers changed, and nothing is done" do
      opts =
        Keyword.update!(pairing_opts(), :provider_opts, fn provider ->
          Keyword.put(provider, :replies, %{pair_decide: {:error, :stale_attempt}})
        end)

      assert {:error, :changed, %{"sentence" => sentence}} =
               route(
                 "accessories.pair.decide",
                 %{
                   "path" => "/dev/cu.usbmodem1101",
                   "attempt" => String.duplicate("a", 32),
                   "matches" => true
                 },
                 Goldens.base(opts)
               )

      assert sentence =~ "pairing attempt has ended"
    end

    test "each step reaches the link with its own arguments" do
      opts = with_status(Goldens.running([]))
      path = "/dev/cu.usbmodem1101"
      attempt = String.duplicate("b", 32)

      assert {:ok, _status} = route("accessories.pair.start", %{"path" => path}, opts)
      assert_received {:accessories_called, :pair_start, [^path]}

      assert {:ok, _status} =
               route("accessories.pair.begin", %{"path" => path, "name" => "Desk robot"}, opts)

      assert_received {:accessories_called, :pair_begin, [^path, "Desk robot"]}

      assert {:ok, _status} =
               route(
                 "accessories.pair.decide",
                 %{"path" => path, "attempt" => attempt, "matches" => false},
                 opts
               )

      assert_received {:accessories_called, :pair_decide, [^path, ^attempt, false]}

      assert {:ok, _status} = route("accessories.pair.cancel", %{"path" => path}, opts)
      assert_received {:accessories_called, :pair_cancel, [^path, nil]}
    end

    defp pairing_opts do
      enrollment = %{
        attempt: "5d1f0c2b9a8e47d6b3c1a0f9e8d7c6b5",
        round: 1,
        phase: :revealed,
        code: "382614",
        accessory_confirmed?: false,
        owner_confirmed?: false,
        closed_reason: nil,
        expires_at: ~U[2026-11-08 15:02:00Z]
      }

      link = Goldens.link(%{mode: :pairing, phase: :unenrolled, enrollment: enrollment})
      facts = Goldens.running([Goldens.entry(:linked, link)], selected: "/dev/cu.usbmodem1101")
      [provider_opts: [status: facts, test: self()]]
    end
  end

  describe "accessories" do
    test "an attached robot offers what it can do, and Head movements waits for calibration" do
      robot = Goldens.record()
      facts = Goldens.running([Goldens.entry(:linked, attached_link())])
      [row] = status!(with_status(facts, records: {:ok, [robot]}))["accessories"]

      assert row["connection"] == "attached"

      assert row["actions"] ==
               ["start_call", "select", "check", "calibrate", "release", "forget", "revoke"]

      assert row["state"]["battery"] == nil
      assert row["state"]["calibration"] == "missing"

      assert row["calibration_sentence"] ==
               "Head movement is off until the robot is calibrated."

      assert row["capabilities"] == ["mic", "speaker", "screen", "motion", "battery"]
      assert row["short_id"] =~ ~r/^[0-9a-f]{4}( [0-9a-f]{4}){3}$/
      assert row["gen"] == 4
    end

    # M91 F3: the robot's own counters, since its boot, as it last reported
    # them this attach; null before a report, and on any robot not attached.
    test "an attached robot's diag counters are its row's diag, and null before a report" do
      robot = Goldens.record()

      counters = %{
        uptime_s: 61,
        frames_rx: 812,
        frames_tx: 940,
        crc_errors: 0,
        resync_bytes: 0,
        pcm_seq_gaps: 2,
        mic_overflows: 0,
        spk_underflows: 3
      }

      reported = Goldens.running([Goldens.entry(:linked, attached_link(%{diag: counters}))])
      [row] = status!(with_status(reported, records: {:ok, [robot]}))["accessories"]

      assert row["diag"] == %{
               "uptime_s" => 61,
               "frames_rx" => 812,
               "frames_tx" => 940,
               "crc_errors" => 0,
               "resync_bytes" => 0,
               "pcm_seq_gaps" => 2,
               "mic_overflows" => 0,
               "spk_underflows" => 3
             }

      silent = Goldens.running([Goldens.entry(:linked, attached_link())])
      [row] = status!(with_status(silent, records: {:ok, [robot]}))["accessories"]
      assert row["diag"] == nil
    end

    test "voice not ready keeps the robot attached and offers no call" do
      robot = Goldens.record()
      facts = Goldens.running([Goldens.entry(:linked, attached_link())])

      status =
        status!(
          with_status(facts,
            records: {:ok, [robot]},
            readiness: {:not_ready, "missing_key"}
          )
        )

      assert status["voice"]["ready"] == false
      assert status["voice"]["code"] == "missing_key"
      assert [row] = status["accessories"]
      refute "start_call" in row["actions"]
    end

    test "too little power, and the robot's own fault, are said first" do
      robot = Goldens.record()

      low =
        attached_link(%{
          accessory_state: %{
            battery: 9,
            power: "low",
            brownout: true,
            volume: 60,
            brightness: 70,
            motion: "off",
            calibration: "valid"
          }
        })

      [row] =
        status!(
          with_status(Goldens.running([Goldens.entry(:linked, low)]), records: {:ok, [robot]})
        )[
          "accessories"
        ]

      assert row["sentence"] =~ "needs more power"
      refute "start_call" in row["actions"]

      faulted = attached_link(%{fault: "pack_mismatch"})

      [row] =
        status!(
          with_status(Goldens.running([Goldens.entry(:linked, faulted)]), records: {:ok, [robot]})
        )["accessories"]

      assert row["fault"] == "pack_mismatch"
      assert row["sentence"] == "StackChan reports a problem: `pack_mismatch`. Check its screen."
    end

    test "a paired robot that is not plugged in says so, and the last call says why it ended" do
      robot = Goldens.record()

      last = %{
        robot.accessory_id => %{
          call_id: "voice-1",
          reason: "unplugged",
          ended_at: ~U[2026-11-08 15:10:00Z]
        }
      }

      [row] =
        status!(with_status(Goldens.running([], last_calls: last), records: {:ok, [robot]}))[
          "accessories"
        ]

      assert row["connection"] == "unplugged"
      assert row["sentence"] == "Plug StackChan into this Mac."
      assert row["last_call"]["sentence"] == "StackChan was unplugged, so the call ended."
      assert row["actions"] == ["select", "forget", "revoke"]
    end

    test "forget while the link is off erases the record here, and the choice with it" do
      home = SafeRm.make_tmp_dir!("accessories-forget")
      on_exit(fn -> SafeRm.rm_rf!(home) end)
      {:ok, _key} = Store.ensure_host_key(home)
      robot = Goldens.record()
      :ok = Store.put(home, robot)
      :ok = Store.put_voice_device(home, {:accessory, robot.accessory_id})

      opts =
        Goldens.base(enabled?: false, home: home)
        |> Keyword.drop([:records, :voice_device])

      assert {:ok, status} =
               route("accessories.forget", %{"accessory_id" => robot.accessory_id}, opts)

      assert status["accessories"] == []
      assert status["voice_device"]["device"] == "desktop"

      assert {:error, :invalid_params, %{"field" => "accessory_id", "sentence" => sentence}} =
               route("accessories.forget", %{"accessory_id" => robot.accessory_id}, opts)

      assert sentence == "No paired robot has that id."
    end
  end

  describe "the voice device" do
    # Fable review 3, 7: an unreadable choice and a robot chosen while
    # accessories are off are said, never read as this Mac.
    # M1: an app routes on the typed device, so an unreadable choice is its
    # own value, never `desktop`, and choosing again stays open.
    test "a voice device that cannot be read is typed unreadable, and can be chosen again" do
      opts = Goldens.base(voice_device: {:error, {:invalid_voice_device, "/invented"}})
      device = status!(opts)["voice_device"]

      assert device == %{
               "device" => "unreadable",
               "accessory_id" => nil,
               "changeable" => true,
               "sentence" => "The voice device could not be read. Choose one in Pet."
             }
    end

    test "a robot still chosen while accessories are off says so, and is not unchosen" do
      robot = Goldens.record()

      opts =
        Goldens.base(
          enabled?: false,
          records: {:ok, [robot]},
          voice_device: {:ok, {:accessory, robot.accessory_id}},
          provider_opts: [status: %{running: false, watcher: nil, last_calls: %{}}]
        )

      status = status!(opts)

      sentence =
        "StackChan is off but is still your voice device. Choose This Mac in Pet to talk here."

      assert status["sentence"] == sentence
      assert status["voice_device"]["sentence"] == sentence
      assert status["voice_device"]["device"] == "accessory:" <> robot.accessory_id
    end

    setup do
      home = SafeRm.make_tmp_dir!("accessories-voice-device")
      on_exit(fn -> SafeRm.rm_rf!(home) end)
      {:ok, _key} = Store.ensure_host_key(home)
      robot = Goldens.record()
      :ok = Store.put(home, robot)
      %{home: home, robot: robot}
    end

    defp device_opts(home, overrides \\ []) do
      Goldens.base(
        Keyword.merge([home: home, provider_opts: [status: Goldens.running([])]], overrides)
      )
      |> Keyword.drop([:records, :voice_device])
    end

    test "a choice that cannot be read can still be replaced", %{home: home} do
      File.write!(Store.voice_device_path(home), "not json")
      File.chmod!(Store.voice_device_path(home), 0o600)
      assert {:error, _unreadable} = Store.load_voice_device(home)
      assert status!(device_opts(home))["voice_device"]["device"] == "unreadable"

      assert {:ok, status} =
               route("accessories.voice_device.set", %{"device" => "desktop"}, device_opts(home))

      assert status["voice_device"]["device"] == "desktop"
      assert status["voice_device"]["sentence"] == nil
    end

    test "choosing a paired robot is stored and shown", %{home: home, robot: robot} do
      device = "accessory:" <> robot.accessory_id

      assert {:ok, status} =
               route("accessories.voice_device.set", %{"device" => device}, device_opts(home))

      assert status["voice_device"]["device"] == device
      assert [%{"selected" => true}] = status["accessories"]
      assert {:ok, {:accessory, _id}} = Store.load_voice_device(home)
    end

    test "it does not change while a call runs or settles", %{home: home} do
      opts = device_opts(home, call_holder: {:ok, %{endpoint: "desktop"}})
      status = status!(opts)

      refute status["voice_device"]["changeable"]

      assert status["voice_device"]["sentence"] ==
               "The voice device can change once the call has finished."

      assert {:error, :unavailable, %{"sentence" => sentence}} =
               route("accessories.voice_device.set", %{"device" => "desktop"}, opts)

      assert sentence == "The voice device can change once the call has finished."
    end

    test "an unknown robot cannot be chosen", %{home: home} do
      assert {:error, :invalid_params, %{"field" => "device"}} =
               route(
                 "accessories.voice_device.set",
                 %{"device" => "accessory:" <> String.duplicate("c", 64)},
                 device_opts(home)
               )
    end
  end

  # The app writes no state sentence of its own: each calibration state and
  # each call phase it shows comes with the daemon's.
  describe "the sentences beside a state" do
    test "every calibration state the app shows has its sentence, and none without motion" do
      robot = Goldens.record()

      sentences =
        for calibration <- ~w(missing valid calibrating failed absent) do
          link =
            attached_link(%{
              accessory_state: %{
                battery: nil,
                power: "usb",
                brownout: false,
                volume: 60,
                brightness: 70,
                motion: "off",
                calibration: calibration
              }
            })

          facts = Goldens.running([Goldens.entry(:linked, link)])
          [row] = status!(with_status(facts, records: {:ok, [robot]}))["accessories"]
          {calibration, row["calibration_sentence"]}
        end

      assert [
               {"missing", "Head movement is off until the robot is calibrated."},
               {"valid", valid},
               {"calibrating", calibrating},
               {"failed", failed},
               {"absent", nil}
             ] = sentences

      for sentence <- [valid, calibrating, failed], do: assert(is_binary(sentence))
    end

    test "a call that is starting or ending says so; an active one leaves it to its state" do
      for {phase, expected} <- [
            starting: "The call is starting.",
            active: nil,
            ending: "The call is ending."
          ] do
        call = %{in_call_call() | phase: phase}
        link = attached_link(%{call: call})
        facts = Goldens.running([Goldens.entry(:linked, link)])
        status = status!(with_status(facts, records: {:ok, [Goldens.record()]}))
        assert status["call"]["phase_sentence"] == expected, "#{phase}"
      end
    end
  end

  describe "the call" do
    test "the call is labelled with the voice it started with, never the saved one" do
      status = Goldens.status(in_call_opts())
      call = status["call"]

      assert call["engine"] == "xai_realtime"
      assert call["engine_label"] == Voice.engine_label("xai_realtime")
      assert call["voice"] == "eve"
      assert status["voice"]["engine"] == "openai_live"
      assert status["voice"]["engine_label"] == Voice.engine_label("openai_live")
      assert call["phase"] == "active"
      assert [%{"cancellable" => true}] = call["tasks"]
      assert call["transcript"] |> hd() |> Map.fetch!("speaker") == "user"
      refute status["voice_device"]["changeable"]
    end

    test "a refused start names its code and the daemon's sentence" do
      facts = Goldens.running([Goldens.entry(:linked, attached_link())])

      opts =
        Goldens.base(
          records: {:ok, [Goldens.record()]},
          provider_opts: [
            status: facts,
            replies: %{call_start: {:error, {:refused, "call_in_progress"}}}
          ]
        )

      assert {:error, :unavailable, details} =
               route(
                 "accessories.call.start",
                 %{"accessory_id" => Goldens.record().accessory_id},
                 opts
               )

      assert details == %{
               "capability" => "accessories",
               "code" => "call_in_progress",
               "sentence" => "Another voice call is in progress."
             }
    end

    test "a start refused for a voice device that cannot be read says so" do
      facts = Goldens.running([Goldens.entry(:linked, attached_link())])

      opts =
        Goldens.base(
          records: {:ok, [Goldens.record()]},
          provider_opts: [
            status: facts,
            replies: %{call_start: {:error, {:refused, "voice_device_unreadable"}}}
          ]
        )

      assert {:error, :unavailable, details} =
               route(
                 "accessories.call.start",
                 %{"accessory_id" => Goldens.record().accessory_id},
                 opts
               )

      assert details == %{
               "capability" => "accessories",
               "code" => "voice_device_unreadable",
               "sentence" => VoiceDevice.unreadable_sentence()
             }
    end

    test "a control for a call that ended answers changed" do
      opts =
        Goldens.base(
          provider_opts: [
            status: Goldens.running([]),
            replies: %{call_end: {:error, :stale_call}}
          ]
        )

      assert {:error, :changed, %{"sentence" => "That call has ended, so look at it again."}} =
               route(
                 "accessories.call.end",
                 %{"accessory_id" => Goldens.record().accessory_id, "call_id" => "voice-0"},
                 opts
               )
    end

    defp in_call_opts do
      robot = Goldens.record()
      link = attached_link(%{call: in_call_call()})

      Goldens.base(
        records: {:ok, [robot]},
        realtime_config: %FermixCore.Realtime.Config{
          engine: "openai_live",
          model: "gpt-live-1",
          voice: "marin"
        },
        provider_opts: [status: Goldens.running([Goldens.entry(:linked, link)])]
      )
    end
  end

  defp in_call_call do
    %{
      call_id: "voice-7c2e41d9",
      stream: 1,
      source: :screen_tap,
      phase: :active,
      view: %{
        state: "listening",
        muted_by: nil,
        engine: "xai_realtime",
        model: "grok-voice-3.0",
        voice: "eve",
        call_uuid: nil,
        conversation: "chat",
        started_at: ~U[2026-11-08 15:00:36Z],
        transcript: [%{speaker: :user, text: "Hello there.", final?: true}],
        tasks: [%{task: "dlg_1", revision: 1, status: "running", summary: nil, in_chat?: false}],
        usage: nil
      }
    }
  end

  describe "params" do
    test "each method refuses a field outside its own set, and a malformed value, by name" do
      opts = with_status(Goldens.running([]))
      id = Goldens.record().accessory_id

      refusals = [
        {"accessories.status", %{"after" => "nope", "wait_ms" => 10}, "after"},
        {"accessories.status", %{"after" => "0123456789abcdef", "wait_ms" => 25_001}, "wait_ms"},
        {"accessories.pair.start", %{"path" => ""}, "path"},
        {"accessories.pair.begin", %{"path" => "/dev/x", "name" => ""}, "name"},
        {"accessories.pair.decide", %{"path" => "/dev/x", "attempt" => "a", "matches" => true},
         "attempt"},
        {"accessories.forget", %{"accessory_id" => "ABC"}, "accessory_id"},
        {"accessories.voice_device.set", %{"device" => "phone:1"}, "device"},
        {"accessories.call.mute", %{"accessory_id" => id, "call_id" => "c"}, "muted"},
        {"accessories.check.start", %{"accessory_id" => id, "check" => "tone", "seconds" => 3},
         "seconds"},
        {"accessories.check.start", %{"accessory_id" => id, "check" => "smell"}, "check"},
        {"accessories.calibrate", %{"accessory_id" => id, "op" => "nudge", "axis" => "pan"},
         "steps"},
        {"accessories.calibrate", %{"accessory_id" => id, "op" => "begin", "steps" => 4},
         "steps"},
        {"accessories.calibrate",
         %{"accessory_id" => id, "op" => "nudge", "axis" => "pan", "steps" => 0}, "steps"},
        {"accessories.set", %{"accessory_id" => id}, "volume"},
        {"accessories.set", %{"accessory_id" => id, "volume" => 101}, "volume"},
        {"accessories.retry", %{"path" => "/dev/x", "extra" => 1}, "extra"}
      ]

      for {method, params, field} <- refusals do
        assert {:error, :invalid_params, %{"field" => ^field}} = route(method, params, opts),
               "#{method} #{inspect(params)} was not refused on #{field}"
      end
    end

    test "a mic check defaults to five seconds, and a nudge carries its axis and steps" do
      opts = with_status(Goldens.running([]))
      id = Goldens.record().accessory_id

      assert {:ok, _} =
               route("accessories.check.start", %{"accessory_id" => id, "check" => "mic"}, opts)

      assert_received {:accessories_called, :check_start, [^id, :mic, 5]}

      assert {:ok, _} =
               route(
                 "accessories.calibrate",
                 %{"accessory_id" => id, "op" => "nudge", "axis" => "tilt", "steps" => -8},
                 opts
               )

      assert_received {:accessories_called, :calibrate, [^id, :nudge, %{axis: :tilt, steps: -8}]}

      assert {:ok, _} = route("accessories.set", %{"accessory_id" => id, "motion" => true}, opts)
      assert_received {:accessories_called, :set, [^id, %{motion: true}]}
    end
  end

  describe "the wait" do
    test "the key moves with what the picture says and stays put otherwise" do
      quiet = Goldens.base()
      assert status!(quiet)["key"] == status!(quiet)["key"]

      refute status!(quiet)["key"] ==
               status!(Goldens.base(readiness: {:not_ready, "voice_disabled"}))["key"]
    end

    test "a wait on the current key answers when the watcher says something changed" do
      parent = self()
      {:ok, facts} = Agent.start_link(fn -> Goldens.running([]) end)
      watcher = spawn(fn -> receive do: (:stop -> :ok) end)
      on_exit(fn -> send(watcher, :stop) end)

      subscribe = fn [pid] ->
        send(parent, {:subscribed, pid})
        {:ok, watcher}
      end

      opts =
        Goldens.base(
          provider_opts: [
            status: fn -> Agent.get(facts, & &1) end,
            replies: %{subscribe: subscribe}
          ],
          wait_timer: fn _message, _ms -> make_ref() end
        )

      key = status!(opts)["key"]
      waiter = Task.async(fn -> Accessories.status_after(key, 25_000, opts) end)
      assert_receive {:subscribed, pid}

      Agent.update(facts, fn _ -> Goldens.running([Goldens.entry(:unrelated)]) end)
      send(pid, {:accessories_changed, 4})

      assert {:ok, status} = Task.await(waiter, 10_000)
      refute status["key"] == key
      assert [%{"status" => "unrelated"}] = status["ports"]
    end

    test "a wait ends when the watcher does: the switch turned off" do
      parent = self()
      watcher = spawn(fn -> receive do: (:stop -> :ok) end)

      subscribe = fn [pid] ->
        send(parent, {:subscribed, pid})
        {:ok, watcher}
      end

      opts =
        Goldens.base(
          provider_opts: [status: Goldens.running([]), replies: %{subscribe: subscribe}],
          wait_timer: fn _message, _ms -> make_ref() end
        )

      key = status!(opts)["key"]
      waiter = Task.async(fn -> Accessories.status_after(key, 25_000, opts) end)
      assert_receive {:subscribed, _pid}
      send(watcher, :stop)

      assert {:ok, %{"key" => ^key}} = Task.await(waiter, 10_000)
    end

    # Fable review 1: what changes between the first read and the subscribe is
    # read again at once, and what the watcher does not own (the call lease,
    # voice readiness, the switch) on a 2 s tick, so no change waits out the
    # whole wait.
    test "a change between the first read and the subscribe is answered at once" do
      {:ok, facts} = Agent.start_link(fn -> Goldens.running([]) end)
      watcher = spawn(fn -> receive do: (:stop -> :ok) end)
      on_exit(fn -> send(watcher, :stop) end)

      # The change lands while the wait subscribes, and no word follows it.
      subscribe = fn [_pid] ->
        Agent.update(facts, fn _ -> Goldens.running([Goldens.entry(:unrelated)]) end)
        {:ok, watcher}
      end

      opts =
        Goldens.base(
          provider_opts: [
            status: fn -> Agent.get(facts, & &1) end,
            replies: %{subscribe: subscribe}
          ],
          wait_timer: fn _message, _ms -> make_ref() end
        )

      key = status!(opts)["key"]
      waiter = Task.async(fn -> Accessories.status_after(key, 25_000, opts) end)

      assert {:ok, {:ok, status}} = Task.yield(waiter, 10_000)
      refute status["key"] == key
    end

    test "a change the watcher does not own is read again on the wait's tick" do
      test = self()
      {:ok, facts} = Agent.start_link(fn -> %{running: false, watcher: nil, last_calls: %{}} end)

      timer = fn message, ms ->
        send(test, {:timer, self(), message, ms})
        make_ref()
      end

      opts =
        Goldens.base(provider_opts: [status: fn -> Agent.get(facts, & &1) end], wait_timer: timer)

      %{"state" => "not_running", "key" => key} = status!(opts)
      waiter = Task.async(fn -> Accessories.status_after(key, 25_000, opts) end)
      assert_receive {:timer, pid, {:accessories_reread, _token} = tick, 2_000}

      # The switch's subtree started meanwhile, with no watcher to say so.
      Agent.update(facts, fn _ -> Goldens.running([]) end)
      send(pid, tick)

      assert {:ok, %{"state" => "on"}} = Task.await(waiter, 10_000)
    end

    test "a wait whose key does not move answers at its timer" do
      opts =
        Goldens.base(wait_timer: fn message, _ms -> send(self(), message) && make_ref() end)

      key = status!(opts)["key"]
      assert {:ok, status} = Accessories.status_after(key, 25_000, opts)
      assert status["key"] == key
    end
  end

  # The setup page follows a pairing by the watcher's own change notices, as
  # a status wait is woken by them.
  describe "following the watcher" do
    test "watch answers the watcher to monitor, and the subtree's word when there is none" do
      watcher = spawn(fn -> receive do: (:stop -> :ok) end)
      on_exit(fn -> send(watcher, :stop) end)

      opts =
        Goldens.base(
          provider_opts: [
            status: Goldens.running([]),
            replies: %{subscribe: fn [_pid] -> {:ok, watcher} end},
            test: self()
          ]
        )

      page = self()
      assert {:ok, ^watcher} = Accessories.watch(page, opts)
      assert_receive {:accessories_called, :subscribe, [^page]}

      assert {:error, :not_running} = Accessories.watch(page, Goldens.base())

      full =
        Goldens.base(provider_opts: [status: %{}, replies: %{subscribe: {:error, :too_many}}])

      assert {:error, :too_many} = Accessories.watch(page, full)

      assert {:error, :unavailable} = Accessories.watch(page, Goldens.base(provider: nil))
    end
  end

  # D15: the robot burns one eFuse key block when the owner confirms on it,
  # so a page that offers Matches says so first, in the daemon's words.
  test "the eFuse note is one of the daemon's sentences" do
    assert Accessories.efuse_sentence() ==
             "Tapping Matches on the robot burns one key on its chip for good; returning to " <>
               "stock still works."

    assert Accessories.efuse_sentence() in Accessories.sentences()
  end

  describe "the switch" do
    test "a link that followed is quiet, and one that did not says so" do
      assert :ok = Accessories.apply_enabled(true, Goldens.base())

      not_started =
        Goldens.base(provider_opts: [status: %{}, replies: %{apply_enabled: {:ok, :not_started}}])

      assert {:error, "StackChan is on but could not start. See the daemon log."} =
               Accessories.apply_enabled(true, not_started)

      assert {:error, "StackChan setup needs a local Mac primary."} =
               Accessories.apply_enabled(true, Goldens.base(os_type: {:unix, :linux}))
    end
  end

  test "every sentence obeys the copy rules" do
    for sentence <- Accessories.sentences() do
      assert Copy.violations(sentence, :prose) == [],
             "#{inspect(sentence)}: #{inspect(Copy.violations(sentence, :prose))}"
    end
  end
end
