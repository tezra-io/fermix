defmodule FermixChannels.ApplicationStopTest do
  # An orderly stop stops applications in reverse start order, and the
  # channels application (and the web application above it) starts after the
  # core, so it stops first: its `prep_stop/1` is where a phone call in
  # progress is asked to end, while its tree, and the call's backend, still
  # run (M94 §04). The real worker under the real Manager and subtree, over
  # the fakes (`FermixTestSupport.PhoneCallFakes`); the stop reaches this
  # test's Manager through `:phone_calls_stop_manager`. async: false: the
  # fakes report to a registered sink, and the seam is application
  # environment. Nothing here can reach a network.
  use ExUnit.Case, async: false

  alias FermixChannels.Application, as: ChannelsApplication
  alias FermixCore.Memory.Repo
  alias FermixCore.PhoneCalls.Brief
  alias FermixCore.PhoneCalls.Ledger
  alias FermixCore.PhoneCalls.Manager
  alias FermixTestSupport.PhoneCallFakes, as: Fakes

  # Every name, number and id here is invented.
  @t0 ~U[2031-03-04 15:00:00.000000Z]
  @session "sess_invented_stop"

  defmodule ShimCall do
    alias FermixCore.PhoneCalls.Call
    alias FermixTestSupport.PhoneCallFakes

    def start_link(args),
      do: Call.start_link(Map.merge(args, PhoneCallFakes.scripted(:seams, %{})))

    def cancel(pid, why), do: Call.cancel(pid, why)
    def prompt_version, do: "phone-stop-1"
  end

  defmodule SinkDispatcher do
    def dispatch(notice), do: FermixTestSupport.PhoneCallFakes.notify({:dispatched, notice})
  end

  setup do
    Process.flag(:trap_exit, true)
    Fakes.register_sink!()
    start_supervised!(Fakes.script_spec())
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-phone-stop-#{unique}.db")

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    repo = :"phone_stop_repo_#{unique}"
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path}, id: repo)

    names = %{
      supervisor: :"phone_stop_sup_#{unique}",
      call_registry: :"phone_stop_registry_#{unique}",
      handoff_supervisor: :"phone_stop_handoff_#{unique}",
      manager: :"phone_stop_manager_#{unique}",
      call_supervisor: :"phone_stop_calls_#{unique}",
      delivery_worker: :"phone_stop_delivery_#{unique}"
    }

    Fakes.script(:seams, Fakes.seams(:atomics.new(1, [])))

    start_supervised!(
      {FermixCore.PhoneCalls.Supervisor,
       call_module: ShimCall,
       hangup: fn _session -> {:error, {:not_sent, :never_here}} end,
       names: names,
       repo: repo,
       readiness: fn -> :ready end,
       config: &Fakes.config/0,
       now_fn: fn -> @t0 end,
       continuation_dispatcher: SinkDispatcher,
       timer_enabled: false}
    )

    previous = Application.fetch_env(:fermix_core, :phone_calls_stop_manager)
    Application.put_env(:fermix_core, :phone_calls_stop_manager, names.manager)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:fermix_core, :phone_calls_stop_manager, value)
        :error -> Application.delete_env(:fermix_core, :phone_calls_stop_manager)
      end
    end)

    %{names: names, repo: repo}
  end

  # OTP stops what started last first: the channels application starts after
  # the core because it needs it, so it stops before the core.
  test "the channels application needs the core, so it stops before the core does" do
    assert :fermix_core in Application.spec(:fermix_channels, :applications)
  end

  test "its stop asks the call in progress to hang up while its own tree still runs", ctx do
    call = ctx.names |> start_call!() |> live!()
    stopper = Task.async(fn -> ChannelsApplication.prep_stop(:state) end)

    assert_receive {:hangup, _task, @session}, 10_000
    assert is_pid(Process.whereis(FermixChannels.Supervisor))

    closed = %{reason: "close_requested", seconds: 12.0, event_id: nil}
    send(call.worker, {:phone_sideband, call.sideband, {:event, {:session_closed, closed}}})

    assert :state = Task.await(stopper, 15_000)

    assert {:ok, %{status: "ended", failure_reason: "engine_stopped"}} =
             Ledger.get(call.id, server: ctx.repo)

    # The core's own stop reaches the drain again later; it answers at once.
    assert :already_drained = Manager.drain(ctx.names.manager)
  end

  defp start_call!(names) do
    {:ok, brief} =
      Brief.new(
        %{
          "destination" => "+12125550101",
          "destination_kind" => "business",
          "number_source" => "The bistro's own website.",
          "contact_name" => "Calloway Bistro",
          "timezone" => "America/New_York",
          "goal" => "Ask for a table for two on Saturday at 19:30.",
          "completion_criteria" => ["The host confirms a table for two at 19:30."]
        },
        caller_number: Fakes.caller(),
        now: @t0
      )

    request = %{
      brief: brief,
      brief_hash: Brief.hash(brief),
      request_id: "req-stop-#{System.unique_integer([:positive])}",
      parent_session: "main-stop-#{System.unique_integer([:positive])}",
      owner_id: "default",
      operation: "phone_call.start",
      authorization: "direct",
      snapshot: %{
        origin_kind: "chat",
        delivery_mode: "origin",
        platform: "telegram",
        destination: "40017",
        thread: nil,
        send_opts: nil,
        origin_conversation: ["telegram", "40017", "root"]
      }
    }

    assert {:ok, %{call_id: id}} = Manager.start_call(request, names.manager)
    assert_receive {:create, task, _create_request}
    [{worker, _value}] = Registry.lookup(names.call_registry, id)
    %{id: id, worker: worker, create: task}
  end

  defp live!(call) do
    Fakes.answer(
      call.create,
      {:ok, %{session_id: @session, http_status: 201, transport_type: "sip"}}
    )

    assert_receive {:attach, sideband, @session, _api_key}
    send(call.worker, {:phone_sideband, sideband, :attached})

    send(
      call.worker,
      {:phone_sideband, sideband, {:event, {:answered, %{session_id: @session, event_id: nil}}}}
    )

    assert_receive {:said, nil, _opening}
    Map.put(call, :sideband, sideband)
  end
end
