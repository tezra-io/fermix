defmodule FermixChannels.Companion.TurnsTest do
  # The shared request path end to end on both transports: the real Gateway,
  # `Companion.Turns` as its agent, the request coordinator and the timeline on
  # a throwaway repo. Only the queue is a stand-in, so a turn's outcome is
  # fired here the way the queue fires it. `Companion.Turns`, the companion
  # registry and the mobile trust store run under their application names, so
  # the tests run alone.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixChannels.Channels.Companion
  alias FermixChannels.Channels.Mobile
  alias FermixChannels.Companion.Approvals
  alias FermixChannels.Companion.Connection
  alias FermixChannels.Companion.Fanout
  alias FermixChannels.Companion.Output
  alias FermixChannels.Companion.Requests
  alias FermixChannels.Companion.Supervisor, as: CompanionSupervisor
  alias FermixChannels.Companion.Turns
  alias FermixChannels.Gateway.Message
  alias FermixChannels.Gateway.WorkRegistry
  alias FermixChannels.Mobile.DeviceRegistry
  alias FermixChannels.Mobile.DeviceStore
  alias FermixChannels.Mobile.EventRouter
  alias FermixChannels.Mobile.Management
  alias FermixChannels.Mobile.Protocol, as: MobileProtocol
  alias FermixChannels.Mobile.RequestCoordinator
  alias FermixCore.Companion.Protocol, as: CompanionProtocol
  alias FermixCore.Companion.Timeline
  alias FermixCore.Memory.Repo

  @repo :companion_turns_test_repo
  @work_registry :companion_turns_test_work

  # The timeline on this module's repo, the one store every writer here is
  # handed: the request path, `Companion.Turns` and both channel adapters.
  defmodule RepoTimeline do
    @opts [repo: :companion_turns_test_repo]

    def append(p, attrs, o), do: Timeline.append(p, attrs, o ++ @opts)

    def append_client_message(p, id, a, o),
      do: Timeline.append_client_message(p, id, a, o ++ @opts)

    def append_proactive(p, key, a, o), do: Timeline.append_proactive(p, key, a, o ++ @opts)
    def history_page(p, o), do: Timeline.history_page(p, o ++ @opts)
    def get_client_request(p, id, o), do: Timeline.get_client_request(p, id, o ++ @opts)
    def cancel_client_request(p, id, o), do: Timeline.cancel_client_request(p, id, o ++ @opts)
    def cancel_device_requests(device, o), do: Timeline.cancel_device_requests(device, o ++ @opts)
    def start_client_request(p, id, e, o), do: Timeline.start_client_request(p, id, e, o ++ @opts)

    def claim_client_request(p, id, type, payload, o),
      do: Timeline.claim_client_request(p, id, type, payload, o ++ @opts)

    def complete_client_request(p, id, n, f, o),
      do: Timeline.complete_client_request(p, id, n, f, o ++ @opts)

    def fail_client_request(p, id, n, f, o),
      do: Timeline.fail_client_request(p, id, n, f, o ++ @opts)

    def abandon_client_request(p, id, n, o),
      do: Timeline.abandon_client_request(p, id, n, o ++ @opts)

    def append_client_output(p, id, n, key, a, o),
      do: Timeline.append_client_output(p, id, n, key, a, o ++ @opts)

    def append_client_response(p, id, n, a, o),
      do: Timeline.append_client_response(p, id, n, a, o ++ @opts)

    def update_client_message(p, id, n, a, o),
      do: Timeline.update_client_message(p, id, n, a, o ++ @opts)
  end

  # The queue a turn is handed to: it reports each message and each stop.
  defmodule QueueSink do
    use GenServer

    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)

    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def handle_cast({:enqueue, message}, test_pid) do
      send(test_pid, {:enqueued, message})
      {:noreply, test_pid}
    end

    @impl true
    def handle_call({:stop_turn, key, message_id}, _from, test_pid) do
      send(test_pid, {:stop_turn, key, message_id})
      {:reply, {:ok, :dequeued}, test_pid}
    end
  end

  # Runs a message's slash command as the gateway's command path does: the
  # reply goes out through the channel's own delivery, and the context carries
  # the owner's authorization and the request's own hooks. Only /background's
  # seams are this test's, its work registry and a run the test releases, so no
  # model runs.
  defmodule CommandGateway do
    alias FermixChannels.Gateway.Authorization
    alias FermixChannels.Gateway.Commands
    alias FermixChannels.Gateway.Delivery
    alias FermixChannels.Gateway.ReplyContext

    def ingest([message], opts) do
      reply_fn = Delivery.build_deliver(ReplyContext.new(Keyword.fetch!(opts, :channel), message))

      context = %{
        authorization: %Authorization{role: :operator, trust: :operator},
        conversation_key: {message.channel, message.chat_id, :root},
        work_registry: :companion_turns_test_work,
        background_run: FermixChannels.Companion.TurnsTest.HeldBackgroundRun,
        defer_command_fn: Keyword.get(opts, :defer_command_fn)
      }

      Commands.dispatch(Commands.parse(message), reply_fn, context)
    end
  end

  # A background run that tells the test it started, then answers what the
  # test releases it with.
  defmodule HeldBackgroundRun do
    def run(%{prompt: prompt}) do
      send(:companion_turns_test, {:background_running, prompt, self()})

      receive do
        {:release, result} -> result
      after
        5_000 -> {:error, :never_released}
      end
    end
  end

  # `Companion.Turns`' own store, whose settling writes exit as a Repo call
  # that timed out does; a request whose id starts `exit-` cannot even be read.
  defmodule ExitingStore do
    @timeout {:timeout, {GenServer, :call, [:memory_repo, :settle, 5_000]}}

    def get_client_request(_profile, "exit-" <> _id, _opts), do: exit(@timeout)

    def get_client_request(_profile, "defect-" <> _id, _opts),
      do: raise(ArgumentError, "a store-code defect")

    def get_client_request(p, id, o), do: RepoTimeline.get_client_request(p, id, o)

    def append_client_output(p, id, n, key, a, o),
      do: RepoTimeline.append_client_output(p, id, n, key, a, o)

    def complete_client_request(_p, _id, _n, _f, _o), do: exit(@timeout)
    def fail_client_request(_p, _id, _n, _f, _o), do: exit(@timeout)
    def cancel_device_requests(_device_id, _opts), do: exit(@timeout)
  end

  # The request path's store, whose completion of a request answered without a
  # turn fails by its id's prefix: `unsettled-` and `unfailable-` exit as a Repo
  # call that timed out does, `refused-` returns an error, and `defect-` raises,
  # as a bug in settle code would. `unfailable-` cannot be failed either, and
  # every failure write is reported to the test.
  defmodule UnsettlingStore do
    @timeout {:timeout, {GenServer, :call, [:memory_repo, :settle, 5_000]}}

    defdelegate claim_client_request(p, id, type, payload, o), to: RepoTimeline
    defdelegate append_client_message(p, id, a, o), to: RepoTimeline
    defdelegate update_client_message(p, id, n, a, o), to: RepoTimeline
    defdelegate get_client_request(p, id, o), to: RepoTimeline
    defdelegate history_page(p, o), to: RepoTimeline

    def complete_client_request(_p, "unsettled-" <> _id, _n, _f, _o), do: exit(@timeout)
    def complete_client_request(_p, "unfailable-" <> _id, _n, _f, _o), do: exit(@timeout)
    def complete_client_request(_p, "refused-" <> _id, _n, _f, _o), do: {:error, :disk_io}

    def complete_client_request(_p, "defect-" <> _id, _n, _f, _o),
      do: raise(ArgumentError, "a settle-code defect")

    def complete_client_request(p, id, n, f, o),
      do: RepoTimeline.complete_client_request(p, id, n, f, o)

    def fail_client_request(p, id, n, f, o) do
      send(:companion_turns_test, {:fail_write, id, n})
      if String.starts_with?(id, "unfailable-"), do: exit(@timeout)
      RepoTimeline.fail_client_request(p, id, n, f, o)
    end
  end

  # A queue busy in its stop: it reports the stop and never answers it, so
  # only its death ends the wait.
  defmodule StallingQueue do
    use GenServer

    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)

    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def handle_cast({:enqueue, message}, test_pid) do
      send(test_pid, {:enqueued, message})
      {:noreply, test_pid}
    end

    @impl true
    def handle_call({:stop_turn, _key, message_id}, _from, test_pid) do
      send(test_pid, {:stop_waiting, message_id, self()})
      {:noreply, test_pid}
    end
  end

  @app_env ~w(companion_store mobile_store mobile_event_sink mobile_push mobile_push_launcher
              mobile_unfurl_launcher companion_approvals mobile_approval_push)a

  setup do
    test_pid = self()
    previous = Map.new(@app_env, &{&1, Application.fetch_env(:fermix_channels, &1)})
    Application.put_env(:fermix_channels, :companion_store, RepoTimeline)
    Application.put_env(:fermix_channels, :mobile_store, RepoTimeline)

    Application.put_env(:fermix_channels, :mobile_event_sink, fn profile, event ->
      send(test_pid, {:mobile_event, profile, event})
      :ok
    end)

    Application.put_env(:fermix_channels, :mobile_push, fn profile, seq, _preview ->
      send(test_pid, {:push, profile, seq})
      {:ok, %{status: :sent, sent: 1}}
    end)

    Application.put_env(:fermix_channels, :mobile_push_launcher, fn task -> task.() end)
    Application.put_env(:fermix_channels, :mobile_unfurl_launcher, fn _task -> :ok end)

    Application.put_env(:fermix_channels, :mobile_approval_push, fn profile ->
      send(test_pid, {:approval_push, profile})
      {:ok, %{status: :sent, sent: 1}}
    end)

    approvals =
      start_supervised!({Approvals, name: nil, schedule: fn _message, _delay -> make_ref() end})

    Application.put_env(:fermix_channels, :companion_approvals, approvals)
    on_exit(fn -> Enum.each(previous, &restore_env/1) end)

    dir = FermixTestSupport.SafeRm.make_tmp_dir!("companion-turns")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(dir) end)

    start_supervised!(
      {Repo, name: @repo, enabled: true, database_path: Path.join(dir, "memory.db")}
    )

    start_supervised!(Turns)
    {:ok, _owner} = Registry.register(Companion.registry(), "main", nil)
    queue = start_supervised!({QueueSink, test_pid})

    coordinator =
      start_supervised!(
        {RequestCoordinator,
         name: nil, store: RepoTimeline, boot_epoch: "boot-#{unique()}", recover?: false}
      )

    %{queue: queue, coordinator: coordinator, device_id: pair_device!(), approvals: approvals}
  end

  describe "a command that becomes a turn (STB-3)" do
    test "on the Mac, /ultra is answered and settled by its turn", ctx do
      id = unique()
      command = %{type: "command", payload: command_payload(id, "ultra", "think it through")}

      assert :ok = Requests.request(command, companion_transport(), request_opts(ctx))
      assert_receive {:enqueued, turn}
      assert {:ok, %{status: "running"}} = request(id)

      assert :ok = turn.reply_fn.({:text, "the thorough answer"})
      turn.turn_result_fn.({:completed})

      assert_receive {:companion_event, %{"t" => "text_done", "text" => "the thorough answer"}}
      assert {:ok, %{status: "completed", result_server_seq: seq}} = request(id)
      assert is_integer(seq)

      # The phones never saw the Mac's turn start, so its reply reaches them as a
      # row, carrying what a phone renders a row it did not write with (R1-6).
      assert_receive {:mobile_event, "main",
                      %{
                        "t" => "row",
                        "server_seq" => ^seq,
                        "text" => "the thorough answer",
                        "kind" => "text",
                        "media_refs" => [],
                        "in_reply_to" => ^id,
                        "metadata" => %{"turn_id" => "turn-" <> ^id}
                      }}
    end

    test "on the phone, an unregistered command is answered and settled by its turn", ctx do
      id = unique()
      command = decoded("command", command_payload(id, "model", "fast"))

      assert :ok = EventRouter.route(command, mobile_context(ctx), request_opts(ctx))
      assert_receive {:enqueued, %{content: "/model fast"} = turn}
      assert {:ok, %{status: "running"}} = request(id)

      assert :ok = turn.reply_fn.({:text, "switched"})
      turn.turn_result_fn.({:completed})

      assert {:ok, %{status: "completed", result_server_seq: seq}} = request(id)
      assert_receive {:mobile_event, "main", %{"t" => "text_done", "server_seq" => ^seq}}
      assert_receive {:push, "main", ^seq}
    end
  end

  describe "a request the gateway answers without a turn (STB-4)" do
    test "a slash command typed as text is completed at once on the Mac", ctx do
      id = unique()
      msg = %{type: "msg", payload: msg_payload(id, "/help")}

      assert :ok = Requests.request(msg, companion_transport(), request_opts(ctx))
      drain(ctx)
      refute_received {:enqueued, _turn}
      assert {:ok, %{status: "completed", result_server_seq: seq}} = request(id)
      assert is_integer(seq)

      # Its answer reaches both transports as a row.
      assert_receive {:companion_event, %{"t" => "row", "server_seq" => ^seq}}
      assert_receive {:mobile_event, "main", %{"t" => "row", "server_seq" => ^seq}}
    end

    test "a slash command typed as text and an empty message are completed on the phone", ctx do
      for {id, text} <- [{unique(), "/help"}, {unique(), ""}] do
        assert :ok =
                 EventRouter.route(
                   decoded("msg", msg_payload(id, text)),
                   mobile_context(ctx),
                   request_opts(ctx)
                 )

        drain(ctx)
        refute_received {:enqueued, _turn}
        assert {:ok, %{status: "completed"}} = request(id)
      end
    end
  end

  test "a dead queue fails its phone turns once, never releasing them to run again (STB-7)",
       ctx do
    id = unique()
    msg = decoded("msg", msg_payload(id, "a long question"))

    assert :ok = EventRouter.route(msg, mobile_context(ctx), request_opts(ctx))
    assert_receive {:enqueued, _turn}

    ref = Process.monitor(ctx.queue)
    Process.exit(ctx.queue, :kill)
    assert_receive {:DOWN, ^ref, :process, _pid, :killed}

    assert_receive {:mobile_event, "main", %{"t" => "turn_error", "code" => "interrupted"}}
    refute_received {:companion_event, %{"t" => "turn_error"}}
    _epoch = RequestCoordinator.epoch(ctx.coordinator)
    assert {:ok, %{status: "failed"}} = request(id)
  end

  test "the phone cancels one request's turn in the queue (STB-10)", ctx do
    id = unique()
    msg = decoded("msg", msg_payload(id, "stop me"))
    assert :ok = EventRouter.route(msg, mobile_context(ctx), request_opts(ctx))
    assert_receive {:enqueued, _turn}

    cancel = decoded("cancel", %{"profile_id" => "main", "client_msg_id" => id})
    assert :ok = EventRouter.route(cancel, mobile_context(ctx), request_opts(ctx))
    assert_receive {:stop_turn, {"mobile", "main", :root}, ^id}
  end

  describe "a revoked device (SEC-3)" do
    test "its handed-off turn is stopped and its later work never runs", ctx do
      registry =
        start_supervised!({DeviceRegistry, name: :"sec3_registry_#{unique()}"})

      running = unique()

      assert :ok =
               EventRouter.route(
                 decoded("msg", msg_payload(running, "go")),
                 mobile_context(ctx),
                 request_opts(ctx)
               )

      assert_receive {:enqueued, _turn}

      waiting = unique()
      claim = [transport: "mobile", authenticated_device_id: ctx.device_id]

      assert {:ok, {:claimed, _request}} =
               RepoTimeline.claim_client_request(
                 "main",
                 waiting,
                 "msg",
                 msg_payload(waiting, "later"),
                 claim
               )

      assert :ok = DeviceRegistry.revoke(registry, ctx.device_id)
      assert_receive {:stop_turn, {"mobile", "main", :root}, ^running}
      assert {:ok, %{cancelled_at: %DateTime{}}} = request(waiting)

      late = unique()

      assert :ok =
               EventRouter.route(
                 decoded("msg", msg_payload(late, "still here")),
                 mobile_context(ctx),
                 request_opts(ctx)
               )

      drain(ctx)
      refute_received {:enqueued, _turn}
    end

    # With the phone channel off its trust store is a file, and a revocation
    # from it stops the device's work by the same revocation (R4-1).
    test "revoked with the phone channel off, its work is stopped the same way" do
      device_id = new_device_id()
      root = FermixTestSupport.SafeRm.make_tmp_dir!("turns-offline-devices")
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(root) end)
      {:ok, _device} = DeviceStore.add(device_attrs(device_id), root: root)

      waiting = unique()
      claim = [transport: "mobile", authenticated_device_id: device_id]

      assert {:ok, {:claimed, _request}} =
               RepoTimeline.claim_client_request(
                 "main",
                 waiting,
                 "msg",
                 msg_payload(waiting, "later"),
                 claim
               )

      assert {:ok, %{device_id: ^device_id}} =
               Management.devices_revoke(device_id, root: root, whereis: fn _name -> nil end)

      _state = :sys.get_state(Turns)
      assert {:ok, %{cancelled_at: %DateTime{}}} = request(waiting)
    end
  end

  # A grant is confirmed only on the transport that raised it, and resumes its
  # request on that request's own channel, through this agent: another
  # channel's resume is queued as that channel's turn, and never tracked here.
  test "another channel's resumed request goes to the queue untracked", ctx do
    test_pid = self()
    resume = %{id: "grant-resume-1", channel: "telegram", chat_id: "chat-1", content: "go on"}
    assert :ok = Turns.handle_message(resume, ctx.queue)
    assert_receive {:enqueued, %{id: "grant-resume-1"}}

    settlement = %{
      settle: fn ->
        send(test_pid, :settled_here)
        :ok
      end,
      fail: fn cause -> send(test_pid, {:failed_here, cause}) end,
      report: fn cause -> send(test_pid, {:reported_here, cause}) end
    }

    :ok = Turns.settle_unless_handed_off(Turns, "chat-1", "grant-resume-1", 1, settlement)
    assert_receive :settled_here
    _state = :sys.get_state(Turns)
    refute_received {:failed_here, _cause}
    refute_received {:reported_here, _cause}
  end

  describe "a command that replies after ingest returns (R2-1)" do
    setup do
      Process.register(self(), :companion_turns_test)
      work = start_supervised!({Task.Supervisor, []}, id: :background_work)
      start_supervised!({WorkRegistry, name: @work_registry, work_supervisor: work})
      :ok
    end

    test "on the Mac, a /bg typed as a message posts its result, and settles only then", ctx do
      id = unique()
      msg = %{type: "msg", payload: msg_payload(id, "/bg reply with the word pong")}

      assert :ok =
               Requests.request(msg, companion_transport(settled_to: self()), command_opts(ctx))

      assert_receive {:companion_event, %{"t" => "row", "text" => "Started background work" <> _}}
      assert_receive {:background_running, "reply with the word pong", run}
      assert {:ok, %{status: "running"}} = request(id)

      send(run, {:release, {:ok, "pong"}})

      assert_receive {:companion_event,
                      %{"t" => "row", "server_seq" => seq, "text" => "Background work " <> done}}

      assert done =~ "pong"
      assert_receive {:settled, ^id, "completed"}
      assert {:ok, %{status: "completed", result_server_seq: ^seq}} = request(id)
    end

    test "on the phone, a /bg typed as a message posts its result, and settles only then", ctx do
      id = unique()
      msg = decoded("msg", msg_payload(id, "/bg reply with the word pong"))

      assert :ok = EventRouter.route(msg, mobile_context(ctx), command_opts(ctx))

      assert_receive {:mobile_event, "main",
                      %{"t" => "text_done", "text" => "Started background work" <> _}}

      assert_receive {:background_running, "reply with the word pong", run}
      assert {:ok, %{status: "running"}} = request(id)

      send(run, {:release, {:ok, "pong"}})

      assert_receive {:mobile_event, "main",
                      %{
                        "t" => "text_done",
                        "server_seq" => seq,
                        "text" => "Background work " <> _
                      }}

      # The request settles once the result is written, and its push follows.
      assert_receive {:push, "main", ^seq}
      assert {:ok, %{status: "completed", result_server_seq: ^seq}} = request(id)
    end
  end

  # Turns is the settlement fence of both transports: nothing a store or the
  # queue does may crash it, or every fenced request is released to run again
  # and every tracked turn loses its ending (R1-3).
  describe "a Turns that cannot crash" do
    test "a cancel that reaches a dead queue ahead of its DOWN ends the turn once", ctx do
      id = unique()

      assert :ok =
               EventRouter.route(
                 decoded("msg", msg_payload(id, "a long question")),
                 mobile_context(ctx),
                 request_opts(ctx)
               )

      assert_receive {:enqueued, _turn}
      turns = Process.whereis(Turns)

      # The device's revocation is in Turns' mailbox before the queue dies, so
      # its stop reaches the dead queue ahead of the queue's DOWN.
      :ok = :sys.suspend(turns)
      :ok = Turns.revoke_device(turns, ctx.device_id)
      ref = Process.monitor(ctx.queue)
      Process.exit(ctx.queue, :kill)
      assert_receive {:DOWN, ^ref, :process, _pid, :killed}

      log =
        capture_log(fn ->
          :ok = :sys.resume(turns)

          assert_receive {:mobile_event, "main", %{"t" => "turn_error", "code" => "interrupted"}},
                         1_000

          _state = :sys.get_state(turns)
        end)

      assert log =~ "could not stop"
      assert Process.whereis(Turns) == turns
      refute_received {:mobile_event, "main", %{"t" => "turn_error"}}
      assert {:ok, %{status: "failed"}} = request(id)
    end

    # The stop waits for the queue however busy it is, so the one other way
    # that wait ends is the queue dying in it (R3-2): that queue took the turn
    # with it, and its :DOWN ends the turn.
    test "a queue that dies in its stop leaves the :DOWN to end the turn once", ctx do
      queue = start_supervised!({StallingQueue, self()}, id: :stalling_queue)
      opts = Keyword.put(request_opts(ctx), :agent_server, queue)
      id = unique()

      assert :ok =
               EventRouter.route(
                 decoded("msg", msg_payload(id, "a long question")),
                 mobile_context(ctx),
                 opts
               )

      assert_receive {:enqueued, %{id: ^id}}
      turns = Process.whereis(Turns)
      cancel = Task.async(fn -> Turns.cancel(Turns, "main", id) end)
      assert_receive {:stop_waiting, ^id, ^queue}

      log =
        capture_log(fn ->
          Process.exit(queue, :kill)
          assert :ok = Task.await(cancel)

          assert_receive {:mobile_event, "main",
                          %{"t" => "turn_error", "turn_id" => "turn-" <> ^id, "code" => code}}

          assert code == "interrupted"
          _state = :sys.get_state(turns)
        end)

      assert log =~ "the queue that held it is gone"
      assert Process.whereis(Turns) == turns
      refute_received {:mobile_event, "main", %{"t" => "turn_error"}}
      assert {:ok, %{status: "failed"}} = request(id)
    end

    test "a store call that exits is logged, and every turn still ends once", ctx do
      stop_supervised!(Turns)
      turns = start_supervised!({Turns, store: ExitingStore})
      mac = unique()
      phone = unique()
      unread = "exit-" <> unique()

      assert :ok =
               Requests.request(
                 %{type: "msg", payload: msg_payload(mac, "hi from the Mac")},
                 companion_transport(),
                 request_opts(ctx)
               )

      assert_receive {:enqueued, %{id: ^mac} = mac_turn}

      assert :ok =
               EventRouter.route(
                 decoded("msg", msg_payload(phone, "hi from the phone")),
                 mobile_context(ctx),
                 request_opts(ctx)
               )

      assert_receive {:enqueued, %{id: ^phone} = phone_turn}

      log =
        capture_log(fn ->
          assert :ok = mac_turn.turn_result_fn.({:failed, :provider_down})
          assert :ok = phone_turn.turn_result_fn.({:completed})

          # A hand-off whose cancel mark cannot be read never reaches the queue.
          assert :ok =
                   EventRouter.route(
                     decoded("msg", msg_payload(unread, "unreadable")),
                     mobile_context(ctx),
                     request_opts(ctx)
                   )

          assert_receive {:mobile_event, "main",
                          %{"t" => "turn_error", "turn_id" => "turn-" <> ^unread}}
        end)

      assert log =~ "exited"
      assert_receive {:companion_event, %{"t" => "turn_error", "turn_id" => "turn-" <> ^mac}}
      refute_received {:enqueued, %{id: ^unread}}
      assert Process.whereis(Turns) == turns

      # A late outcome finds each turn ended, and no request was released to
      # run again: each is still this boot's, fenced on the live Turns.
      assert :ok = mac_turn.turn_result_fn.({:completed})
      refute_received {:companion_event, %{"t" => "text_done"}}
      _epoch = RequestCoordinator.epoch(ctx.coordinator)
      assert {:ok, %{status: "running"}} = request(mac)
      assert {:ok, %{status: "running"}} = request(phone)
    end
  end

  # A device's revocation reaches the store from Turns, where an exit is the
  # revocation's logged failure, never from the device registry, whose crash
  # would restart every phone's socket with it (R4-1).
  test "a revocation whose store exits is logged, and crashes neither the registry nor Turns",
       ctx do
    stop_supervised!(Turns)
    turns = start_supervised!({Turns, store: ExitingStore})

    registry =
      start_supervised!(
        {DeviceRegistry,
         name: :"r41_registry_#{unique()}", delete_device: fn _store, _id -> :ok end}
      )

    log =
      capture_log(fn ->
        assert :ok = DeviceRegistry.revoke(registry, ctx.device_id)
        _state = :sys.get_state(turns)
      end)

    assert log =~ "companion device revocation for #{ctx.device_id} failed: ** (exit)"
    assert log =~ "mobile device #{ctx.device_id} was revoked but its requests were not stopped"
    assert Process.whereis(Turns) == turns
    assert DeviceRegistry.list(registry) == []
  end

  # Turns survives a store that fails, by an error or an exit, but a raise in
  # its own store calls is a defect, not a store failure: it is not caught as
  # one, and crashes Turns to its supervisor, where it shows (R3-4).
  test "a raise in one of its store calls is a defect it does not catch", ctx do
    stop_supervised!(Turns)
    turns = start_supervised!({Turns, store: ExitingStore})
    ref = Process.monitor(turns)
    id = "defect-" <> unique()

    capture_log(fn ->
      assert :ok =
               EventRouter.route(
                 decoded("msg", msg_payload(id, "hello")),
                 mobile_context(ctx),
                 request_opts(ctx)
               )

      assert_receive {:DOWN, ^ref, :process, ^turns,
                      {%ArgumentError{message: "a store-code defect"}, _stack}}
    end)

    refute_received {:enqueued, %{id: ^id}}
    refute_received {:mobile_event, "main", %{"t" => "turn_error"}}
  end

  # Its worker has returned, so Turns is the only one left to end a request
  # answered without a turn: left running, the next boot would run its command
  # again (R3-4).
  describe "an inline settlement that fails" do
    setup do
      Process.register(self(), :companion_turns_test)
      :ok
    end

    test "fails its request once for its attempt, and tells its client, on either wire", ctx do
      opts = Keyword.put(request_opts(ctx), :store, UnsettlingStore)
      mac = "unsettled-" <> unique()
      phone = "refused-" <> unique()

      log =
        capture_log(fn ->
          assert :ok =
                   Requests.request(
                     %{type: "msg", payload: msg_payload(mac, "/help")},
                     companion_transport(),
                     opts
                   )

          assert :ok =
                   EventRouter.route(
                     decoded("msg", msg_payload(phone, "/help")),
                     mobile_context(ctx),
                     opts
                   )

          drain(ctx)
        end)

      assert log =~ "exited"
      assert log =~ ":disk_io"

      for id <- [mac, phone] do
        assert_received {:fail_write, ^id, 1}
        refute_received {:fail_write, ^id, _attempt}
        assert {:ok, %{status: "failed"}} = request(id)
      end

      # Each client is told in its own wire's error: the Mac through its
      # connection's own builder, the phone as its socket builds one (R4-2).
      assert_received {:companion_request_failed, ^mac, {:request_failed, _cause}}

      phone_client = {:device, ctx.device_id}

      assert_received {:reply, ^phone_client,
                       %{"t" => "error", "code" => "request_failed", "client_msg_id" => ^phone} =
                         phone_error}

      assert {:ok, _frames} =
               MobileProtocol.encode_server_event(
                 "error",
                 Map.delete(phone_error, "t"),
                 1,
                 <<>>,
                 []
               )
    end

    test "a raise in its settle code is logged as the defect it is, and fails it", ctx do
      opts = Keyword.put(request_opts(ctx), :store, UnsettlingStore)
      id = "defect-" <> unique()
      turns = Process.whereis(Turns)

      log =
        capture_log([level: :error], fn ->
          assert :ok =
                   Requests.request(
                     %{type: "msg", payload: msg_payload(id, "/help")},
                     companion_transport(),
                     opts
                   )

          drain(ctx)
        end)

      assert log =~ "raised"
      assert log =~ "(ArgumentError) a settle-code defect"
      assert log =~ "UnsettlingStore.complete_client_request"
      assert Process.whereis(Turns) == turns
      assert_received {:fail_write, ^id, 1}
      assert {:ok, %{status: "failed"}} = request(id)

      assert_received {:companion_request_failed, ^id, {:request_failed, {:raised, _defect}}}
    end

    test "tells its client even when the store cannot record the failure either", ctx do
      opts = Keyword.put(request_opts(ctx), :store, UnsettlingStore)
      id = "unfailable-" <> unique()
      turns = Process.whereis(Turns)

      capture_log(fn ->
        assert :ok =
                 Requests.request(
                   %{type: "msg", payload: msg_payload(id, "/help")},
                   companion_transport(),
                   opts
                 )

        drain(ctx)
      end)

      assert_received {:fail_write, ^id, 1}
      refute_received {:fail_write, ^id, _attempt}

      assert_received {:companion_request_failed, ^id, {:request_failed, _cause}}
      assert Process.whereis(Turns) == turns

      # Neither ending reached the store, so the row is still this boot's
      # running attempt, fenced on the live Turns: the one case left for the
      # next boot, which only a store down for both writes reaches.
      assert {:ok, %{status: "running"}} = request(id)
    end
  end

  # A request's worker never waits on Turns for its hand-off or for whether it
  # had one, so a Turns that is slow to answer cannot fail a request whose turn
  # it may already hold (R1-4).
  describe "a Turns that has not answered yet" do
    test "never fails a request: its turn is queued, or it settles, once Turns runs", ctx do
      turns = Process.whereis(Turns)
      handed = unique()
      inline = unique()
      :ok = :sys.suspend(turns)

      assert :ok =
               Requests.request(
                 %{type: "msg", payload: msg_payload(handed, "think it through")},
                 companion_transport(),
                 request_opts(ctx)
               )

      assert :ok =
               EventRouter.route(
                 decoded("msg", msg_payload(inline, "/help")),
                 mobile_context(ctx),
                 request_opts(ctx)
               )

      assert {:ok, %{status: "running"}} = request(handed)
      assert {:ok, %{status: "running"}} = request(inline)

      :ok = :sys.resume(turns)
      assert_receive {:enqueued, %{id: ^handed}}
      _state = :sys.get_state(turns)
      assert {:ok, %{status: "running"}} = request(handed)
      assert {:ok, %{status: "completed"}} = request(inline)
    end
  end

  # Turns is shared settlement, not socket plumbing: a boot that serves no
  # daemon socket (`iex -S mix`) with the phone on still settles (R1-7).
  test "a boot that serves no companion socket still runs a phone request", ctx do
    stop_supervised!(Turns)
    n = System.unique_integer([:positive])

    start_supervised!(
      {CompanionSupervisor,
       name: nil,
       serve?: false,
       settle?: true,
       boot_epoch: "boot-source",
       registry: :"source_boot_registry_#{n}",
       approvals: :"source_boot_approvals_#{n}"}
    )

    assert is_pid(Process.whereis(Turns))
    id = unique()

    assert :ok =
             EventRouter.route(
               decoded("msg", msg_payload(id, "hello")),
               mobile_context(ctx),
               request_opts(ctx)
             )

    assert_receive {:enqueued, turn}
    assert :ok = turn.reply_fn.({:text, "hi"})
    assert :ok = turn.turn_result_fn.({:completed})
    assert {:ok, %{status: "completed"}} = request(id)
  end

  # Sandbox and soul tokens resolve only from the transport that raised them
  # (M19 §9.5), so a card, its re-send, its resolution and its push stay there
  # (R1-2).
  describe "an approval card" do
    test "reaches only the transport that raised it, and is kept for that one", ctx do
      assert :ok =
               Companion.send_approval(
                 approval_message("companion"),
                 "Mac? /confirm MAC-T",
                 "MAC-T"
               )

      assert_receive {:companion_event, %{"t" => "approval", "token" => "MAC-T"}}

      assert :ok =
               Mobile.send_approval(
                 approval_message("mobile"),
                 "Phone? /confirm PHONE-T",
                 "PHONE-T"
               )

      assert_receive {:mobile_event, "main", %{"t" => "approval", "token" => "PHONE-T"}}
      assert_receive {:approval_push, "main"}

      refute_received {:mobile_event, "main", %{"t" => "approval", "token" => "MAC-T"}}
      refute_received {:companion_event, %{"t" => "approval", "token" => "PHONE-T"}}
      refute_received {:approval_push, _profile}

      assert [%{"token" => "MAC-T"}] = Approvals.pending(ctx.approvals, "main", :companion)
      assert [%{"token" => "PHONE-T"}] = Approvals.pending(ctx.approvals, "main", :mobile)
    end
  end

  # One announcer for everyone watching a profile (STB-9).
  describe "fan-out across the transports" do
    test "a phone hears a row as the history message it renders, the Mac as always (R1-6)" do
      image = String.duplicate("c", 64)

      media = %{
        "ref" => image,
        "sha256" => image,
        "kind" => "image",
        "mime" => "image/png",
        "size_bytes" => 5
      }

      row = %{
        server_seq: 8,
        role: "user",
        content: "look at this",
        kind: "media",
        client_msg_id: "phone-1",
        in_reply_to: nil,
        media_refs: [media],
        metadata: %{"turn_id" => nil},
        link_previews: [],
        created_at: ~U[2026-09-27 09:00:00Z]
      }

      assert :ok = Fanout.announce("main", Output.row("main", row))

      assert_receive {:companion_event, mac_row}

      assert mac_row == %{
               "t" => "row",
               "profile_id" => "main",
               "server_seq" => 8,
               "role" => "user",
               "text" => "look at this",
               "ts" => "2026-09-27T09:00:00Z",
               "client_msg_id" => "phone-1"
             }

      assert_receive {:mobile_event, "main", phone_row}

      assert phone_row == %{
               "t" => "row",
               "profile_id" => "main",
               "server_seq" => 8,
               "role" => "user",
               "text" => "look at this",
               "ts" => "2026-09-27T09:00:00Z",
               "client_msg_id" => "phone-1",
               "kind" => "media",
               "media_refs" => [media]
             }

      assert {:ok, _frames} =
               MobileProtocol.encode_server_event("row", Map.delete(phone_row, "t"), 1, <<>>, [])
    end

    # R4-9: each user's row as its own transport writes it, through the
    # request path, reaches the other transport in that wire's shape.
    test "a Mac user's row reaches the phones as the history message a phone renders", ctx do
      id = unique()
      msg = %{type: "msg", payload: msg_payload(id, "hello from the Mac")}

      assert :ok = Requests.request(msg, companion_transport(), request_opts(ctx))

      assert_receive {:mobile_event, "main",
                      %{"t" => "row", "client_msg_id" => ^id, "server_seq" => seq} = phone_row}

      assert phone_row["text"] == "hello from the Mac"
      assert phone_row["kind"] == "text"
      assert phone_row["media_refs"] == []

      assert {:ok, _frames} =
               MobileProtocol.encode_server_event("row", Map.delete(phone_row, "t"), 1, <<>>, [])

      assert_receive {:companion_event, %{"t" => "row", "server_seq" => ^seq}}
    end

    test "a phone user's row reaches the Mac with only the fields its row carries", ctx do
      id = unique()
      msg = decoded("msg", msg_payload(id, "hello from the phone"))

      assert :ok = EventRouter.route(msg, mobile_context(ctx), request_opts(ctx))

      assert_receive {:companion_event, %{"t" => "row", "client_msg_id" => ^id} = mac_row}

      assert %{
               "profile_id" => "main",
               "server_seq" => seq,
               "role" => "user",
               "text" => "hello from the phone",
               "ts" => _ts
             } = mac_row

      assert Map.keys(mac_row) |> Enum.sort() ==
               ~w(client_msg_id profile_id role server_seq t text ts)

      assert {:ok, _line} = CompanionProtocol.encode_server_event("row", Map.delete(mac_row, "t"))

      assert_receive {:mobile_event, "main",
                      %{"t" => "row", "server_seq" => ^seq, "kind" => "text"}}
    end

    test "each wire hears only what it carries, and a turn's ending only its own transport" do
      preview = %{
        "t" => "link_preview",
        "in_reply_to" => 3,
        "url" => "u",
        "site" => "s",
        "title" => "t"
      }

      assert :ok = Fanout.announce("main", preview)
      assert_receive {:mobile_event, "main", %{"t" => "link_preview"}}
      refute_received {:companion_event, %{"t" => "link_preview"}}

      ending = %{
        "t" => "turn_error",
        "turn_id" => "turn-1",
        "code" => "cancelled",
        "message" => "x"
      }

      assert :ok = Fanout.announce("main", ending, audience: :companion)
      assert_receive {:companion_event, %{"t" => "turn_error"}}
      refute_received {:mobile_event, "main", %{"t" => "turn_error"}}
    end
  end

  # A reply to one client comes back here; a profile event goes to every
  # watcher, as both transports' sinks send it.
  defp request_opts(ctx) do
    test_pid = self()

    sink = fn
      {:profile, profile}, event ->
        Fanout.announce(profile, event)

      target, event ->
        send(test_pid, {:reply, target, event})
        :ok
    end

    [
      store: RepoTimeline,
      request_coordinator: ctx.coordinator,
      agent_server: ctx.queue,
      approvals: ctx.approvals,
      event_sink: sink
    ]
  end

  # The request path with the command-running gateway stand-in.
  defp command_opts(ctx), do: Keyword.put(request_opts(ctx), :gateway, CommandGateway)

  # The companion socket's own transport, with this test process as its
  # connection; `settled_to:` names a process told when a request settles
  # outside a turn.
  defp companion_transport(opts \\ []) do
    %{Connection.transport(self()) | after_settle: settled_to(Keyword.get(opts, :settled_to))}
  end

  defp settled_to(nil), do: nil

  defp settled_to(pid) do
    fn _profile, request, _opts ->
      send(pid, {:settled, request.client_msg_id, request.status})
      :ok
    end
  end

  defp approval_message(channel) do
    Message.new!(%{
      id: unique(),
      content: "go",
      sender: "owner",
      channel: channel,
      chat_id: "main",
      reply_target: "main",
      metadata: %{}
    })
  end

  defp mobile_context(ctx), do: %{transport: :mobile, authenticated_device_id: ctx.device_id}

  # Turns and the queue answer in order, so once both have answered, every
  # hand-off and settlement sent to them before is done.
  defp drain(ctx) do
    _turns = :sys.get_state(Turns)
    _queue = :sys.get_state(ctx.queue)
    :ok
  end

  defp request(id), do: RepoTimeline.get_client_request("main", id, [])

  defp msg_payload(id, text),
    do: %{"client_msg_id" => id, "profile_id" => "main", "text" => text, "attach_ids" => []}

  defp command_payload(id, name, args),
    do: %{"client_msg_id" => id, "profile_id" => "main", "name" => name, "args" => args}

  defp decoded(type, payload),
    do: %{type: type, payload: payload, seq: 1, version: 1, bytes: <<>>}

  # The application repo outlives a run, so every request id is new.
  defp unique, do: "e2e-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

  defp restore_env({key, {:ok, value}}), do: Application.put_env(:fermix_channels, key, value)
  defp restore_env({key, :error}), do: Application.delete_env(:fermix_channels, key)

  defp pair_device! do
    root = FermixTestSupport.SafeRm.make_tmp_dir!("turns-device")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(root) end)
    start_supervised!({DeviceStore, root: root, name: DeviceStore})
    id = new_device_id()
    {:ok, _device} = DeviceStore.add(DeviceStore, device_attrs(id))
    id
  end

  defp new_device_id do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    [{a, 8}, {b, 4}, {c, 4}, {d, 4}, {e, 12}]
    |> Enum.map_join("-", fn {part, width} ->
      part |> Integer.to_string(16) |> String.pad_leading(width, "0") |> String.downcase()
    end)
  end

  defp device_attrs(id) do
    %{
      device_id: id,
      name: "iPhone",
      model: "iPhone17,1",
      noise_pk: :crypto.strong_rand_bytes(32),
      created_at: ~U[2026-09-27 09:00:00Z],
      apns_key_salt: :crypto.strong_rand_bytes(32)
    }
  end
end
