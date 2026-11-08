defmodule FermixTestSupport.AccessoryGoldens do
  @moduledoc """
  The `accessories.status` goldens (`success.jsonl`) and the facts behind
  them, one per family of the setup and call states the Mac's Pet screens
  draw (M91 E3): off, a device-role engine, a port that gave no Fermix answer,
  a robot whose firmware lacks what this Fermix needs, pairing with the code
  on both screens, a paired robot in a Grok call while the saved voice is
  Live, the same call settling, the moment a pairing is done, naming the
  robot it paired, and StackChan turned off with the robot still chosen. Each is the status `Management.Accessories` builds from invented
  facts through `FermixTestSupport.AccessoryGoldens.Provider`, which answers
  as the channels app's provider does, so a golden can only say what the
  engine says.
  """

  alias FermixCore.Accessories.P256
  alias FermixCore.Accessories.Record
  alias FermixCore.Management.Accessories
  alias FermixCore.Realtime.Config, as: RealtimeConfig

  defmodule Provider do
    @moduledoc """
    Answers as `FermixChannels.Accessories.Management` does, from its
    options: `:status` (the facts `status/1` answers, or a function that
    reads them), `:replies` (an action's
    reply by its function name, `:ok` when absent) and `:test` (told each
    action as `{:accessories_called, function, args}`).
    """

    def status(opts) do
      case Keyword.fetch!(opts, :status) do
        read when is_function(read, 0) -> {:ok, read.()}
        status -> {:ok, status}
      end
    end

    def subscribe(pid, opts), do: reply(opts, :subscribe, [pid], {:error, :not_running})
    def unsubscribe(pid, opts), do: reply(opts, :unsubscribe, [pid], :ok)
    def touch(opts), do: reply(opts, :touch, [], :ok)
    def apply_enabled(on?, opts), do: reply(opts, :apply_enabled, [on?], {:ok, :started})

    for {name, arity} <- [
          pair_start: 1,
          pair_begin: 2,
          pair_decide: 3,
          pair_cancel: 2,
          retry: 1,
          release: 1,
          reconnect: 1,
          forget: 1,
          revoke: 1,
          call_start: 1,
          call_end: 2,
          call_interrupt: 2,
          call_mute: 3,
          call_task_cancel: 3,
          check_start: 3,
          check_stop: 1,
          calibrate: 3,
          set: 2
        ] do
      args = Macro.generate_arguments(arity, __MODULE__)

      def unquote(name)(unquote_splicing(args), opts),
        do: reply(opts, unquote(name), unquote(args), :ok)
    end

    defp reply(opts, name, args, default) do
      if test = Keyword.get(opts, :test), do: send(test, {:accessories_called, name, args})

      case Map.get(Keyword.get(opts, :replies, %{}), name, default) do
        fun when is_function(fun, 1) -> fun.(args)
        value -> value
      end
    end
  end

  @path "/dev/cu.usbmodem1101"
  @serial "80:45:6B:54:87:FC"

  @doc "Each golden's name and the `accessories.status` result it holds."
  @spec rows() :: [{String.t(), map()}]
  def rows do
    [
      {"accessories_status", status(off())},
      {"accessories_status_needs_local_primary", status(device_role())},
      {"accessories_status_needs_firmware", status(needs_firmware())},
      {"accessories_status_incompatible", status(incompatible())},
      {"accessories_status_pairing", status(pairing())},
      {"accessories_status_in_call", status(in_call())},
      {"accessories_status_paired_now", status(paired_now())},
      {"accessories_status_call_ending", status(in_call(:ending))},
      {"accessories_status_off_robot_chosen", status(off_robot_chosen())}
    ]
  end

  @doc """
  One router case per `accessories.*` method: its params, the options its
  family reads (`operation_opts: [accessories: _]`), and the golden its answer
  is, by name. The status an action answers is the picture after it.
  """
  @spec cases() :: [{String.t(), map(), keyword(), String.t()}]
  def cases do
    id = record().accessory_id
    call = %{"accessory_id" => id, "call_id" => "voice-7c2e41d9"}
    attempt = "5d1f0c2b9a8e47d6b3c1a0f9e8d7c6b5"

    [
      {"accessories.status", %{}, off(), "accessories_status"},
      {"accessories.pair.start", %{"path" => @path}, needs_firmware(), "accessories_pair_start"},
      {"accessories.pair.begin", %{"path" => @path, "name" => "Desk StackChan"}, pairing(),
       "accessories_pair_begin"},
      {"accessories.pair.decide", %{"path" => @path, "attempt" => attempt, "matches" => true},
       pairing(), "accessories_pair_decide"},
      {"accessories.pair.cancel", %{"path" => @path, "attempt" => attempt}, empty(),
       "accessories_pair_cancel"},
      {"accessories.retry", %{"path" => @path}, needs_firmware(), "accessories_retry"},
      {"accessories.release", %{"path" => @path}, released(), "accessories_release"},
      {"accessories.reconnect", %{"path" => @path}, paired(), "accessories_reconnect"},
      {"accessories.forget", %{"accessory_id" => id}, empty(), "accessories_forget"},
      {"accessories.revoke", %{"accessory_id" => id}, empty(), "accessories_revoke"},
      {"accessories.voice_device.set", %{"device" => "accessory:" <> id},
       Keyword.put(paired(), :put_voice_device, fn _home, _device -> :ok end),
       "accessories_voice_device_set"},
      {"accessories.call.start", %{"accessory_id" => id}, in_call(), "accessories_call_start"},
      {"accessories.call.end", call, paired(), "accessories_call_end"},
      {"accessories.call.mute", Map.put(call, "muted", true), in_call(), "accessories_call_mute"},
      {"accessories.call.interrupt", call, in_call(), "accessories_call_interrupt"},
      {"accessories.call.task.cancel", Map.put(call, "task", "dlg_3f9a"), in_call(),
       "accessories_call_task_cancel"},
      {"accessories.check.start", %{"accessory_id" => id, "check" => "mic", "seconds" => 5},
       paired(), "accessories_check_start"},
      {"accessories.check.stop", %{"accessory_id" => id}, paired(), "accessories_check_stop"},
      {"accessories.calibrate",
       %{"accessory_id" => id, "op" => "nudge", "axis" => "pan", "steps" => 4}, paired(),
       "accessories_calibrate"},
      {"accessories.set", %{"accessory_id" => id, "volume" => 60}, paired(), "accessories_set"}
    ]
  end

  @doc "The status `Management.Accessories` answers for `opts`."
  @spec status(keyword()) :: map()
  def status(opts) do
    {:ok, status} = Accessories.status(opts)
    status
  end

  @doc "The invented robot every golden that has one pairs."
  @spec record() :: Record.t()
  def record do
    {:ok, public} = P256.public_key(:crypto.hash(:sha256, "invented desk robot"))

    %Record{
      accessory_id: P256.id(public),
      accessory_pk: public,
      kind: "stackchan",
      name: "Desk StackChan",
      port_hint: @serial,
      enrolled_at: ~U[2026-11-07 22:04:22Z]
    }
  end

  @doc "The options of a local Mac primary with accessories on, and `overrides` over them."
  @spec base(keyword()) :: keyword()
  def base(overrides \\ []) do
    Keyword.merge(
      [
        provider: Provider,
        provider_opts: [status: running([])],
        engine_role: %{role: :primary},
        os_type: {:unix, :darwin},
        enabled?: true,
        records: {:ok, []},
        voice_device: {:ok, :desktop},
        call_holder: :none,
        readiness: :ready,
        realtime_config: realtime("xai_realtime", "grok-voice-3.0", "eve"),
        home: "/nonexistent/invented-home"
      ],
      overrides
    )
  end

  @doc "A running subtree's facts with these port entries."
  @spec running([map()], keyword()) :: map()
  def running(ports, opts \\ []) do
    %{
      running: true,
      watcher: %{version: 3, selected: Keyword.get(opts, :selected), ports: ports},
      last_calls: Keyword.get(opts, :last_calls, %{})
    }
  end

  @doc "One watcher entry, linked to `link` when it is a map."
  @spec entry(atom(), map() | nil, keyword()) :: map()
  def entry(state, link \\ nil, opts \\ []) do
    %{
      path: Keyword.get(opts, :path, @path),
      serial: Keyword.get(opts, :serial, @serial),
      state: state,
      pid: nil,
      link: link,
      busy: Keyword.get(opts, :busy),
      failures: 0
    }
  end

  @doc "One link's view, as `FermixChannels.Accessories.Link` publishes it, with `fields` over it."
  @spec link(map()) :: map()
  def link(fields \\ %{}) do
    Map.merge(
      %{
        path: @path,
        serial: @serial,
        mode: :attach,
        phase: :hello,
        gen: 4,
        accessory_id: nil,
        name: nil,
        kind: nil,
        firmware: nil,
        wire: nil,
        caps: [],
        accessory_state: nil,
        refusal: nil,
        refused_range: nil,
        voice: nil,
        enrollment: nil,
        call: nil,
        check: nil,
        fault: nil
      },
      fields
    )
  end

  defp realtime(engine, model, voice),
    do: %RealtimeConfig{engine: engine, model: model, voice: voice}

  defp off, do: base(enabled?: false, records: {:ok, [record()]}, provider_opts: [status: idle()])

  defp idle, do: %{running: false, watcher: nil, last_calls: %{}}

  # StackChan turned off while the robot is still the voice device: the
  # choice stays, and the status says what it costs the Mac and the fix.
  defp off_robot_chosen do
    robot = record()

    base(
      enabled?: false,
      records: {:ok, [robot]},
      voice_device: {:ok, {:accessory, robot.accessory_id}},
      provider_opts: [status: idle()]
    )
  end

  defp device_role,
    do:
      base(
        engine_role: %{role: :device, primary: "studio-mac"},
        records: {:ok, [record()]},
        provider_opts: [status: idle()]
      )

  defp needs_firmware,
    do: base(provider_opts: [status: running([entry(:no_answer)], selected: @path)])

  defp incompatible do
    link =
      link(%{
        mode: :pairing,
        phase: :refused,
        kind: "stackchan",
        firmware: "0.0.3",
        wire: 1,
        refusal: :capability_missing
      })

    base(provider_opts: [status: running([entry(:linked, link)], selected: @path)])
  end

  defp empty, do: base()

  defp released do
    base(
      records: {:ok, [record()]},
      provider_opts: [status: running([entry(:released)])]
    )
  end

  defp paired do
    robot = record()

    link =
      link(%{
        phase: :attached,
        accessory_id: robot.accessory_id,
        name: robot.name,
        kind: "stackchan",
        firmware: "0.1.0",
        wire: 1,
        caps: [:mic, :speaker, :screen, :touch, :pet, :motion, :battery],
        accessory_state: %{
          battery: nil,
          power: "usb",
          brownout: false,
          volume: 60,
          brightness: 70,
          motion: "off",
          calibration: "missing"
        },
        voice: :ready,
        check: %{check: :mic, status: :running, code: nil, level: 1_842}
      })

    base(
      records: {:ok, [robot]},
      voice_device: {:ok, {:accessory, robot.accessory_id}},
      provider_opts: [status: running([entry(:linked, link)])]
    )
  end

  defp pairing do
    enrollment = %{
      attempt: "5d1f0c2b9a8e47d6b3c1a0f9e8d7c6b5",
      round: 1,
      phase: :revealed,
      code: "382614",
      accessory_confirmed?: false,
      owner_confirmed?: false,
      closed_reason: nil,
      accessory_id: nil,
      expires_at: ~U[2026-11-08 15:02:00Z]
    }

    link =
      link(%{
        mode: :pairing,
        phase: :unenrolled,
        kind: "stackchan",
        firmware: "0.1.0",
        wire: 1,
        caps: [:mic, :speaker, :screen, :touch, :pet, :motion, :battery],
        enrollment: enrollment
      })

    base(provider_opts: [status: running([entry(:linked, link)], selected: @path)])
  end

  # The pairing just committed: the record is written and the link greets the
  # robot again, now as the paired one.
  defp paired_now do
    robot = record()

    enrollment = %{
      attempt: "5d1f0c2b9a8e47d6b3c1a0f9e8d7c6b5",
      round: 1,
      phase: :done,
      code: "382614",
      accessory_confirmed?: true,
      owner_confirmed?: true,
      closed_reason: nil,
      accessory_id: robot.accessory_id,
      expires_at: ~U[2026-11-08 15:02:00Z]
    }

    link = link(%{mode: :pairing, phase: :hello, kind: "stackchan", enrollment: enrollment})

    base(
      records: {:ok, [robot]},
      provider_opts: [status: running([entry(:linked, link)], selected: @path)]
    )
  end

  defp in_call(phase \\ :active) do
    robot = record()

    link =
      link(%{
        phase: :attached,
        accessory_id: robot.accessory_id,
        name: robot.name,
        kind: "stackchan",
        firmware: "0.1.0",
        wire: 1,
        caps: [:mic, :speaker, :screen, :touch, :pet, :motion, :battery],
        accessory_state: %{
          battery: 82,
          power: "usb",
          brownout: false,
          volume: 60,
          brightness: 70,
          motion: "ready",
          calibration: "valid"
        },
        voice: :ready,
        call: %{call() | phase: phase}
      })

    base(
      records: {:ok, [robot]},
      voice_device: {:ok, {:accessory, robot.accessory_id}},
      call_holder: {:ok, %{endpoint: "accessory:" <> robot.accessory_id}},
      realtime_config: realtime("openai_live", "gpt-live-1", "marin"),
      provider_opts: [status: running([entry(:linked, link)])]
    )
  end

  defp call do
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
        call_uuid: "0b9e7f6a-4c3d-4e2f-9a1b-8c7d6e5f4a3b",
        conversation: "chat",
        started_at: ~U[2026-11-08 15:00:36Z],
        transcript: [
          %{speaker: :user, text: "Summarize the document I shared in the chat.", final?: true},
          %{speaker: :assistant, text: "On it. I'll put the summary in the chat.", final?: true}
        ],
        tasks: [
          %{
            task: "dlg_3f9a",
            revision: 1,
            status: "running",
            summary: "Summarizing the shared document",
            in_chat?: false
          }
        ],
        usage: %{cost_cents: 4.125, voice_seconds: 84.0, accounting: "running"}
      }
    }
  end
end
