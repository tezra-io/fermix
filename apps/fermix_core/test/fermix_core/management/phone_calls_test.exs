defmodule FermixCore.Management.PhoneCallsTest do
  @moduledoc """
  The Phone calls section of Settings, Voice and the `phone_calls.*` methods
  (M94 §12): the section's rows and their writes, the off switch applied with
  its write, the three facts and the summary, the calls, the stop and the
  recovery view, the hold on the credentials a call reads, and the
  independence of the phone section from Talk to Fermix.

  Each case runs in its own temporary FERMIX_HOME against the stub keychain,
  with its own ledger and, where a case needs one, its own call manager and a
  worker double that dials nothing. The application environment of both
  applications is put back afterwards, whole. Every name, number, id and
  credential here is invented.
  """

  # async: false: every write goes through the one restart state and the
  # settings file of the FERMIX_HOME this case sets, and the worker double
  # reports to a registered name.
  use ExUnit.Case, async: false

  alias FermixCore.Management.Lifecycle
  alias FermixCore.Management.PhoneCalls
  alias FermixCore.Management.Router
  alias FermixCore.Management.Secrets
  alias FermixCore.Management.Settings
  alias FermixCore.Management.Settings.PhoneCalls, as: PhoneCallsSection
  alias FermixCore.Management.Settings.Row
  alias FermixCore.Memory.Repo
  alias FermixCore.PhoneCalls.Brief
  alias FermixCore.PhoneCalls.Config
  alias FermixCore.PhoneCalls.Ledger
  alias FermixCore.PhoneCalls.Limits
  alias FermixCore.PhoneCalls.Manager
  alias FermixCore.PhoneCalls.Readiness
  alias FermixCore.PhoneCalls.Report
  alias FermixCore.Realtime.Config, as: RealtimeConfig
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.RestartState
  alias FermixCore.Setup.SecretWriter
  alias FermixCore.Setup.Wizard
  alias FermixCore.Tools.PhoneCall, as: PhoneCallTool
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.SecretWriterStub
  alias FermixTestSupport.TelemetryCapture

  @sink :management_phone_calls_test_sink
  @events [
    [:fermix, :phone_call, :run_start],
    [:fermix, :phone_call, :run_complete],
    [:fermix, :phone_call, :run_error]
  ]
  @t0 ~U[2031-03-04 15:00:00.000000Z]
  @caller "+14155550142"
  @destination "+12125550101"
  @username "fermixtrunk01"
  @password "invented-trunk-password"
  @openai_key "sk-invented-openai-key"
  @xai_key "xai-invented-voice-key"
  @apps [:fermix_core, :fermix_channels]
  # What a test host cannot settle for readiness: this engine runs as the
  # primary, durable memory is on, and the backend a call's turns run on is
  # wired (the test build configures none). Everything else is read as it is.
  @host [primary?: true, durable_memory?: true, call_backend?: true]
  @rows ~w(phone_calls_enabled phone_calls_status phone_calls_engine phone_calls_voice
           phone_calls_caller_number phone_calls_sip_username phone_calls_sip_password
           openai_api_key)

  # The per-call worker as the Manager's contract defines it: it announces its
  # start and reports a stop request, and dials nothing.
  defmodule FakeCall do
    use GenServer

    def start_link(args), do: GenServer.start_link(__MODULE__, args)
    def prompt_version, do: "phone-test-1"

    def cancel(pid, why) do
      send(pid, {:cancel, why})
      :ok
    end

    def run(pid, fun), do: GenServer.call(pid, {:run, fun})

    @impl true
    def init(args) do
      send(:management_phone_calls_test_sink, {:started, args.call_id, self()})
      {:ok, args}
    end

    @impl true
    def handle_call({:run, fun}, _from, args), do: {:reply, fun.(args), args}

    @impl true
    def handle_info({:cancel, why}, args) do
      send(:management_phone_calls_test_sink, {:cancel_asked, args.call_id, why})
      {:noreply, args}
    end
  end

  defmodule SinkDispatcher do
    def dispatch(notice) do
      send(:management_phone_calls_test_sink, {:dispatched, notice})
      :ok
    end
  end

  setup do
    Process.register(self(), @sink)
    envs = for app <- @apps, do: {app, Application.get_all_env(app)}
    fermix_home = System.get_env("FERMIX_HOME")
    home = SafeRm.make_tmp_dir!("management_phone_calls")
    unique = System.unique_integer([:positive])
    repo = :"management_phone_calls_repo_#{unique}"

    Application.put_env(:fermix_core, :secret_writer, SecretWriterStub)
    SecretWriterStub.reset()
    System.put_env("FERMIX_HOME", home)

    for key <- [:providers, :realtime, :phone_calls],
        do: Application.put_env(:fermix_core, key, [])

    :ok = RestartState.record_persisted_baseline()

    db_path = Path.join(home, "memory.db")
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path}, id: repo)

    on_exit(fn ->
      Enum.each(envs, fn {app, env} -> restore_all(app, env) end)
      SecretWriterStub.reset()

      case fermix_home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      SafeRm.rm_rf!(home)
      :ok = RestartState.record_persisted_baseline()
    end)

    %{home: home, repo: repo, unique: unique}
  end

  describe "the section" do
    test "publishes five settings and two facts, and no phone row asks for a restart", ctx do
      seed!(ctx, phone_calls: phone(true))
      rows = rows(ctx)

      assert Enum.map(rows, & &1["key"]) == @rows
      assert %{id: "phone_calls", pane: "voice", title: "Phone calls"} in Settings.sections()

      for row <- rows, row["key"] != "openai_api_key", do: refute(row["restart"], row["key"])

      # The OpenAI key's write is the provider's, so its rule is the
      # provider section's wherever its row is shown.
      assert row(rows, "openai_api_key")["restart"] == Row.restart?(:providers)

      assert %{"read_only" => true, "value" => "GPT-Live · gpt-live-1"} =
               row(rows, "phone_calls_engine")

      assert %{"read_only" => true, "kind" => "text"} = row(rows, "phone_calls_status")

      assert Enum.map(row(rows, "phone_calls_voice")["options"], & &1["value"]) ==
               Config.voices()

      assert row(rows, "phone_calls_enabled")["value"] == true
      assert row(rows, "phone_calls_caller_number")["value"] == @caller
      assert row(rows, "phone_calls_sip_username")["value"] == @username
      assert row(rows, "phone_calls_sip_password")["present"] == false
    end

    # Read at a glance: a text stays only where the owner would make a
    # mistake or miss something to act on without it; a constant says at
    # most one line; nothing is said twice.
    test "each row says only what prevents a mistake", ctx do
      seed!(ctx, [])
      footers = Map.new(rows(ctx), &{&1["key"], &1["footer"]})

      assert footers["phone_calls_enabled"] ==
               "Lets Fermix place calls from your Telnyx number when you ask."

      assert footers["phone_calls_engine"] == "Talk to Fermix keeps its own model."
      assert footers["phone_calls_voice"] == nil
      assert footers["phone_calls_caller_number"] == "The number you bought from Telnyx."

      assert footers["phone_calls_sip_username"] ==
               "Both come from your Telnyx credential connection, not your Telnyx login."

      assert footers["phone_calls_sip_password"] == nil

      assert footers["openai_api_key"] ==
               "The OpenAI provider's own key: changing it here changes it there."

      for {key, footer} <- footers, is_binary(footer) do
        refute footer =~ "\n", key
        assert length(String.split(footer, ". ")) == 1, key
      end
    end

    test "a home that never set phone calls up reads Disabled, and its fields are empty", ctx do
      seed!(ctx, [])
      rows = rows(ctx)

      assert %{"value" => "Disabled", "footer" => "Phone calls are off."} =
               row(rows, "phone_calls_status")

      assert row(rows, "phone_calls_enabled")["value"] == false
      assert row(rows, "phone_calls_caller_number")["value"] == ""
      assert row(rows, "phone_calls_voice")["value"] == Config.default_voice()
    end

    test "a Grok-only home shows the OpenAI key and reads Needs setup naming it", ctx do
      seed!(ctx,
        realtime: grok(true),
        phone_calls: phone(true),
        secrets: [{"xai_api_key", @xai_key}, {"phone_calls_sip_password", @password}]
      )

      rows = rows(ctx)
      assert row(rows, "openai_api_key")["present"] == false

      assert %{"value" => "Needs setup", "footer" => footer} = row(rows, "phone_calls_status")
      assert footer == Readiness.sentence(:openai_api_key_missing)

      assert {:ok, status} = route(ctx, "phone_calls.status")
      assert status["enabled"] == true
      assert status["summary"]["state"] == "needs_setup"

      assert status["readiness"] == %{
               "ready" => false,
               "missing" => [
                 %{
                   "requirement" => "openai_api_key_missing",
                   "sentence" => Readiness.sentence(:openai_api_key_missing)
                 }
               ]
             }

      # Storing OpenAI's existing secret makes phone calls ready, and leaves
      # Talk to Fermix on Grok exactly as it was.
      realtime = persisted!(:realtime)
      assert {:ok, %{"present" => true}} = set_secret(ctx, "openai_api_key", @openai_key)

      assert {:ok, %{"summary" => %{"state" => "ready"}, "readiness" => %{"ready" => true}}} =
               route(ctx, "phone_calls.status")

      assert persisted!(:realtime) == realtime
      assert SecretWriterStub.get(:xai_api_key) == {:ok, @xai_key}
    end

    test "with phone calls off, readiness still names what the setup lacks", ctx do
      seed!(ctx, phone_calls: [caller_number: @caller])

      assert {:ok, status} = route(ctx, "phone_calls.status")
      assert status["enabled"] == false

      assert status["summary"] == %{
               "state" => "disabled",
               "label" => "Disabled",
               "sentence" => "Phone calls are off."
             }

      assert Enum.map(status["readiness"]["missing"], & &1["requirement"]) ==
               ~w(openai_api_key_missing sip_username_missing sip_password_missing)

      assert status["engine"] == %{
               "name" => "GPT-Live",
               "model" => "gpt-live-1",
               "carrier" => "Telnyx"
             }
    end
  end

  describe "a write of the section" do
    test "writes each setting, reads it back, and asks for no restart", ctx do
      seed!(ctx, [])
      restart = Settings.restart()

      assert {:ok, result} =
               apply_phone(ctx, %{
                 "phone_calls_voice" => "cedar",
                 "phone_calls_caller_number" => " #{@caller} ",
                 "phone_calls_sip_username" => @username
               })

      assert Enum.sort(result["applied"]) ==
               ~w(phone_calls_caller_number phone_calls_sip_username phone_calls_voice)

      assert result["side_effects"] == []

      # The write adds no restart reason: the section is not boot-bound.
      assert result["restart"] == restart
      refute Enum.any?(result["restart"]["reasons"], &(&1["section"] == "phone_calls"))

      assert persisted!(:phone_calls) == [
               voice: "cedar",
               caller_number: @caller,
               sip_username: @username
             ]

      rows = rows(ctx)
      assert row(rows, "phone_calls_voice")["value"] == "cedar"
      assert row(rows, "phone_calls_caller_number")["value"] == @caller
      assert File.read!(Path.join(ctx.home, "config.toml")) =~ "[fermix_core.phone_calls]"
    end

    test "a number the section refuses is said in the owner's words and writes nothing", ctx do
      seed!(ctx, phone_calls: phone(false))

      for {number, reason} <- [
            {"4155550142", :not_e164},
            {"+18005550142", :emergency_or_special_number},
            {"+442071838750", :not_nanp_number}
          ] do
        assert {:error, {:invalid_params, "phone_calls_caller_number", sentence}} =
                 apply_phone(ctx, %{"phone_calls_caller_number" => number})

        assert sentence in PhoneCallsSection.refusal_sentences(), "#{number}: #{sentence}"
        refute sentence =~ "config.toml", "#{reason} reached the owner as the file's message"
      end

      assert persisted!(:phone_calls) == phone(false)
    end

    test "a username longer than a connection's is refused in the owner's words", ctx do
      seed!(ctx, [])

      assert {:error, {:invalid_params, "phone_calls_sip_username", sentence}} =
               apply_phone(ctx, %{"phone_calls_sip_username" => String.duplicate("u", 257)})

      assert sentence =~ "Copy it again from your Telnyx connection."
    end

    test "a write the settings file refuses is reported as failed and stops nothing", ctx do
      seed!(ctx, phone_calls: phone(true))
      edit_config!(ctx, ~s(caller_number = "#{@caller}"), ~s(caller_number = "+14155550143"))
      test = self()

      assert {:error, {:external_change, ["phone_calls"]}} =
               Settings.apply("phone_calls", %{"phone_calls_enabled" => false},
                 phone_calls: phone_opts(ctx),
                 phone_calls_switch: fn on? -> send(test, {:switched, on?}) && [] end
               )

      refute_received {:switched, _on?}
      assert Config.get().enabled
    end

    test "a secret row is stored only with secret.set" do
      assert {:error, {:invalid_params, "phone_calls_sip_password", sentence}} =
               Settings.apply("phone_calls", %{"phone_calls_sip_password" => @password})

      assert sentence =~ "secret.set"
    end
  end

  describe "the off switch" do
    test "ends a call not yet dialed, with nothing dialed, and refuses the next start", ctx do
      seed_ready!(ctx)
      manager = start_manager(ctx)
      call = start_call!(manager)

      assert {:ok, result} = apply_phone(ctx, %{"phone_calls_enabled" => false}, manager)

      assert result["side_effects"] == [
               "The call that had not been placed yet was stopped, and nothing was dialed."
             ]

      assert_receive {:cancel_asked, id, :disabled}
      assert id == call.id
      assert %{status: "failed", failure_reason: "phone_calls_disabled"} = row!(ctx, call.id)
      assert {:error, {:not_admitted, "failed"}} = claim!(call)
      assert {:error, :disabled} = Manager.start_call(request(), manager.name)

      # The credentials are kept: turning phone calls off forgets neither.
      assert SecretWriterStub.get(:phone_calls_sip_password) == {:ok, @password}
      assert SecretWriterStub.get(:openai_api_key) == {:ok, @openai_key}
      refute Keyword.has_key?(persisted!(:phone_calls), :enabled)
      assert Keyword.has_key?(persisted!(:phone_calls), :sip_password)
    end

    test "asks a live call to end, which then reads Stopping, and leaves local voice on", ctx do
      seed_ready!(ctx, realtime: grok(true))
      manager = start_manager(ctx)
      call = start_call!(manager)
      {:ok, _row} = session!(call, "sess_invented_off_1")

      assert {:ok, result} = apply_phone(ctx, %{"phone_calls_enabled" => false}, manager)

      assert result["side_effects"] == [
               "The call in progress was asked to end. It reads stopping until its end is known."
             ]

      assert_receive {:cancel_asked, _id, :disabled}

      assert {:ok, %{"enabled" => false, "summary" => %{"state" => "stopping"}, "call" => view}} =
               route(ctx, "phone_calls.status", %{}, manager)

      assert view["state"] == "stopping"
      assert row(rows(ctx, manager), "phone_calls_status")["value"] == "Stopping"
      assert RealtimeConfig.normalize(Application.get_env(:fermix_core, :realtime)).enabled?
    end

    test "turning them on again reopens admission, keeps an uncertain call's slot and dials nothing",
         ctx do
      seed_ready!(ctx)
      manager = start_manager(ctx)
      call = start_call!(manager)
      {:ok, _row} = claim!(call)

      assert {:ok, _off} = apply_phone(ctx, %{"phone_calls_enabled" => false}, manager)
      assert_receive {:cancel_asked, _id, :disabled}
      lose_worker!(call, manager)
      assert row!(ctx, call.id).status == "dispatch_unknown"

      # A lost dial has its own status word: it may never have been placed.
      assert {:ok,
              %{"summary" => %{"state" => "placement_unknown", "label" => "Placement unknown"}}} =
               route(ctx, "phone_calls.status", %{}, manager)

      assert {:ok, on} = apply_phone(ctx, %{"phone_calls_enabled" => true}, manager)

      assert on["side_effects"] == [
               "An earlier call's termination is unconfirmed, so a new call waits until you " <>
                 "confirm it ended or OpenAI's own limit on a call passes."
             ]

      assert {:error, {:slot_held, holder}} = Manager.start_call(request(), manager.name)
      assert holder == call.id
      refute_received {:started, _id, _pid}
    end

    test "a write that leaves the switch where it was does not touch the call manager", ctx do
      seed!(ctx, phone_calls: phone(true))
      test = self()

      assert {:ok, %{"side_effects" => []}} =
               Settings.apply("phone_calls", %{"phone_calls_voice" => "sage"},
                 phone_calls: phone_opts(ctx),
                 phone_calls_switch: fn on? -> send(test, {:switched, on?}) && [] end
               )

      refute_received {:switched, _on?}
    end

    test "where no call manager runs, the switch is saved and says nothing", ctx do
      seed!(ctx, phone_calls: phone(true))
      opts = Keyword.put(phone_opts(ctx), :manager, :"no_manager_#{ctx.unique}")

      assert {:ok, %{"side_effects" => []}} =
               Settings.apply("phone_calls", %{"phone_calls_enabled" => false},
                 phone_calls: opts,
                 phone_calls_switch: &PhoneCalls.apply_enabled(&1, opts)
               )

      refute Config.get().enabled
    end

    test "a reload that turns phone calls off applies the switch", ctx do
      seed!(ctx, phone_calls: phone(true))
      test = self()

      edit_config!(
        ctx,
        "[fermix_core.phone_calls]\nenabled = true\n",
        "[fermix_core.phone_calls]\n"
      )

      assert {:ok, %{"reloaded" => true}} =
               Settings.reload(
                 phone_calls_switch: fn on? -> send(test, {:switched, on?}) && [] end
               )

      assert_received {:switched, false}
      refute Config.get().enabled
    end
  end

  describe "the calls" do
    test "each is listed with its state, outcome, uncertainty and three costs apart", ctx do
      seed!(ctx, phone_calls: phone(true))
      ended = seed_call!(ctx, "main-list-1", [:claim, :session, {:end, "ended"}])
      unknown = seed_call!(ctx, "main-list-2", [:claim, {:end, "dispatch_unknown"}])

      assert {:ok, %{"calls" => [first, second]}} = route(ctx, "phone_calls.list")
      assert {first["call_id"], second["call_id"]} in [{unknown, ended}, {ended, unknown}]
      calls = Map.new([first, second], &{&1["call_id"], &1})

      assert %{
               "state" => "ended",
               "placed" => "yes",
               "uncertain" => false,
               "holds_slot" => false,
               "outcome" => "options",
               "contact_name" => "Calloway Bistro",
               "destination_kind" => "business",
               "sentence" => "The call ended.",
               "slot" => nil,
               "why_stopped" => nil
             } = calls[ended]

      assert calls[ended]["usage"] == %{
               "voice_seconds" => 95,
               "voice_state" => "voice_duration_confirmed",
               "voice" => "Voice time: 1 minute 35 seconds, confirmed by OpenAI.",
               "carrier" =>
                 "Carrier charges: Telnyx bills the minutes to the account the call went " <>
                   "through, and Fermix does not know them.",
               "backend_turns" => 0,
               "backend_tokens" => nil,
               "backend" => "Backend work: no backend turns."
             }

      assert %{
               "state" => "dispatch_unknown",
               "placed" => "unknown",
               "uncertain" => true,
               "holds_slot" => true
             } = calls[unknown]

      assert calls[unknown]["usage"]["voice"] == "Voice time is unknown."
      assert calls[unknown]["slot"] =~ "confirmed ended from the Telnyx portal"

      # A number reaches the owner only in the recovery view.
      refute Jason.encode!(calls) =~ @destination
    end

    test "with durable memory off, the list says why it has nothing to read" do
      assert {:error, :unavailable, %{"capability" => "phone_calls", "sentence" => sentence}} =
               Router.route(request("phone_calls.list"), [])

      assert sentence == Readiness.sentence(:durable_memory_off)
    end

    test "a parameter a method does not take is refused by name", ctx do
      assert {:error, :invalid_params, %{"field" => "limit"}} =
               route(ctx, "phone_calls.list", %{"limit" => 3})

      assert {:error, :invalid_params, %{"field" => "call_id"}} = route(ctx, "phone_calls.stop")
    end
  end

  describe "the stop" do
    # What left the setup page goes to the general log: one info line when a
    # call ends, in the daemon's own code words, never a name, a number, the
    # brief, anything said on the call or a credential.
    test "a call's end is one log line of codes, with no name or number", ctx do
      seed_ready!(ctx)
      manager = start_manager(ctx)
      call = start_call!(manager)
      previous = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous) end)

      log =
        ExUnit.CaptureLog.capture_log([level: :info], fn ->
          assert {:ok, %{"stop" => "cancelled"}} =
                   route(ctx, "phone_calls.stop", %{"call_id" => call.id}, manager)

          _settled = :sys.get_state(manager.pid)
        end)

      lines = log |> String.split("\n") |> Enum.filter(&(&1 =~ "phone call #{call.id} ended:"))

      assert [line] = lines

      assert line =~
               "phone call #{call.id} ended: status=failed outcome=unknown " <>
                 "reason=cancelled_by_owner voice_seconds=0 backend_turns=0"

      for private <- [@destination, "Calloway Bistro", "table for two", @caller, @openai_key],
          do: refute(log =~ private, private)
    end

    test "is the owner's, through the call manager's cancel", ctx do
      seed_ready!(ctx)
      manager = start_manager(ctx)
      call = start_call!(manager)

      assert {:ok, %{"stop" => "cancelled", "call" => view, "sentence" => sentence}} =
               route(ctx, "phone_calls.stop", %{"call_id" => call.id}, manager)

      assert sentence ==
               "The call had not been placed yet, so it was stopped and nothing was dialed."

      assert view["state"] == "failed"
      assert view["placed"] == "no"
      assert view["sentence"] == "Nothing was dialed."
      assert view["why_stopped"] == "The call was stopped at the owner's request."
      assert view["usage"]["carrier"] == nil
      assert_receive {:cancel_asked, _id, :owner}
      assert row!(ctx, call.id).failure_reason == "cancelled_by_owner"
    end

    test "asks a dialed call to end, and it reads stopping", ctx do
      seed_ready!(ctx)
      manager = start_manager(ctx)
      call = start_call!(manager)
      {:ok, _row} = session!(call, "sess_invented_stop_1")

      assert {:ok, %{"stop" => "stopping", "call" => %{"state" => "stopping"}}} =
               route(ctx, "phone_calls.stop", %{"call_id" => call.id}, manager)

      assert_receive {:cancel_asked, _id, :owner}
    end

    test "another owner's call, an ended one and an unresolved one are refused", ctx do
      seed!(ctx, phone_calls: phone(true))
      theirs = seed_call!(ctx, "main-stop-1", [], "someone-else")
      Ledger.fail_undispatched(theirs, "seed", @t0, server: ctx.repo)
      ended = seed_call!(ctx, "main-stop-2", [:claim, :session, {:end, "ended"}])

      unresolved =
        seed_call!(ctx, "main-stop-3", [:claim, :session, {:end, "closure_unconfirmed"}])

      assert {:error, :invalid_params, %{"field" => "call_id", "sentence" => not_found}} =
               route(ctx, "phone_calls.stop", %{"call_id" => theirs})

      assert not_found == "No phone call of yours has that id."

      assert {:error, :unavailable, %{"sentence" => "That call has already ended."}} =
               route(ctx, "phone_calls.stop", %{"call_id" => ended})

      assert {:error, :unavailable, %{"sentence" => sentence}} =
               route(ctx, "phone_calls.stop", %{"call_id" => unresolved})

      assert sentence =~ "its termination is unconfirmed"
      # The sentence the tool says for the same call: the slot, and both ways out.
      assert sentence == Report.stop_refusal(row!(ctx, unresolved), @t0)
      assert sentence =~ "It holds the call slot until it is confirmed ended"

      # Nothing here marks the call ended: it still holds the slot.
      assert {:ok, [%{id: ^unresolved}]} = Ledger.unresolved(@t0, server: ctx.repo)
    end

    test "a call in progress with no call manager running says so", ctx do
      seed!(ctx, phone_calls: phone(true))
      id = seed_call!(ctx, "main-stop-4", [:claim])

      assert {:error, :unavailable, %{"sentence" => sentence}} =
               route(ctx, "phone_calls.stop", %{"call_id" => id})

      assert sentence == "Phone calls are not running here, so no call is in progress to stop."
    end
  end

  describe "the recovery view" do
    test "a dispatch whose answer was lost: no provider id, its slot until OpenAI's limit", ctx do
      seed!(ctx, phone_calls: phone(true))
      id = seed_call!(ctx, "main-recovery-1", [:claim, {:end, "dispatch_unknown"}])

      assert {:ok, %{"calls" => [view]}} = route(ctx, "phone_calls.recovery.get")
      release_at = DateTime.add(@t0, Limits.slot_hold_ms(), :millisecond)

      assert %{
               "call_id" => ^id,
               "state" => "dispatch_unknown",
               "destination" => @destination,
               "contact_name" => "Calloway Bistro",
               "provider_session_id" => nil,
               "carrier_call_id" => nil
             } = view

      assert view["attempted_at"] == DateTime.to_iso8601(@t0)
      assert view["slot_release_at"] == DateTime.to_iso8601(release_at)
      assert view["sentence"] =~ "Whether the call was placed is unknown"
      assert view["release"] =~ "confirmed ended from the Telnyx portal"
      assert view["release"] =~ "2 hours and 5 minutes after the dial"
      assert Enum.any?(view["containment"], &(&1 =~ "confirm it here"))
      assert Enum.any?(view["containment"], &(&1 =~ "Telnyx portal"))
      assert Enum.any?(view["containment"], &(&1 =~ "daily spend limit"))
    end

    test "a closure that is unconfirmed: the provider's id, and the summary says so", ctx do
      seed!(ctx, phone_calls: phone(false))
      id = seed_call!(ctx, "main-recovery-2", [:claim, :session, {:end, "closure_unconfirmed"}])

      assert {:ok, %{"calls" => [view]}} = route(ctx, "phone_calls.recovery.get")
      assert %{"call_id" => ^id, "provider_session_id" => "sess_seeded"} = view

      assert view["sentence"] ==
               "Fermix lost hold of the call before it asked OpenAI to end it, and its " <>
                 "termination is unconfirmed."

      # A feature turned off with an unresolved remote call is not Disabled.
      assert {:ok, %{"enabled" => false, "summary" => summary}} = route(ctx, "phone_calls.status")
      assert summary["state"] == "termination_unconfirmed"
      assert summary["label"] == "Termination unconfirmed"
    end

    test "a call whose slot passed OpenAI's limit is no longer listed", ctx do
      seed!(ctx, phone_calls: phone(true))
      seed_call!(ctx, "main-recovery-3", [:claim, {:end, "dispatch_unknown"}])
      later = DateTime.add(@t0, Limits.slot_hold_ms() + 1_000, :millisecond)

      assert {:ok, %{"calls" => []}} =
               PhoneCalls.recovery(Keyword.put(phone_opts(ctx), :now, later))
    end
  end

  # Through the call manager, which owns the slot and publishes whether a
  # call holds it (`Manager.slot_held?/2`), so the fact admission and the
  # `phone_call` tool read is free the moment the owner's word lands.
  describe "the owner's word that a call ended" do
    test "frees an unresolved call's slot, its recorded outcome unchanged, and a new call may start",
         ctx do
      seed_ready!(ctx)
      id = seed_call!(ctx, "main-confirm-1", [:claim, :session, {:end, "closure_unconfirmed"}])
      manager = start_manager(ctx)
      now = DateTime.add(@t0, 600, :second)
      opts = Keyword.put(phone_opts(ctx, manager), :now, now)
      # The manager publishes the fact once its boot has read the ledger.
      _state = :sys.get_state(manager.pid)
      assert Manager.slot_held?(now, manager.name)

      assert {:ok, %{"sentence" => sentence, "call" => view}} =
               PhoneCalls.route("phone_calls.recovery.confirm", %{"call_id" => id}, opts)

      assert sentence ==
               "Fermix marked the call ended on your word, so a new call may be placed. The " <>
                 "outcome already recorded is unchanged."

      assert %{"state" => "closure_unconfirmed", "outcome" => "unknown", "holds_slot" => false} =
               view

      assert view["slot"] =~ "confirmed ended from the Telnyx portal"

      assert %{slot_release_reason: "owner_confirmed", slot_released_at: ^now, outcome: "unknown"} =
               row!(ctx, id)

      refute Manager.slot_held?(now, manager.name)
      assert {:ok, %{"calls" => []}} = PhoneCalls.recovery(opts)
      assert {:ok, %{"call" => nil}} = PhoneCalls.status(opts)
      assert {:ok, %{state: "admitted"}} = Manager.start_call(request(), manager.name)
    end

    test "frees a call whose dial answer was lost the same way", ctx do
      seed!(ctx, phone_calls: phone(true))
      id = seed_call!(ctx, "main-confirm-2", [:claim, {:end, "dispatch_unknown"}])
      manager = start_manager(ctx)

      assert {:ok, %{"call" => %{"placed" => "unknown", "holds_slot" => false}}} =
               route(ctx, "phone_calls.recovery.confirm", %{"call_id" => id}, manager)

      assert row!(ctx, id).slot_release_reason == "owner_confirmed"
      refute Manager.slot_held?(@t0, manager.name)
    end

    test "is refused for a call in progress, one already over, and another owner's", ctx do
      seed!(ctx, phone_calls: phone(true))
      manager = start_manager(ctx)
      ended = seed_call!(ctx, "main-confirm-4", [:claim, :session, {:end, "ended"}])
      live = seed_call!(ctx, "main-confirm-3", [:claim, :session])
      confirm = &route(ctx, "phone_calls.recovery.confirm", %{"call_id" => &1}, manager)

      assert {:error, :unavailable, %{"sentence" => in_progress}} = confirm.(live)
      assert in_progress == "That call is still in progress, so only stopping it ends it."
      step!(ctx, live, {:end, "failed"})
      theirs = seed_call!(ctx, "main-confirm-5", [:claim, {:end, "dispatch_unknown"}], "someone")

      assert {:error, :unavailable,
              %{"sentence" => "That call has no unconfirmed end to confirm."}} = confirm.(ended)

      assert {:error, :invalid_params, %{"field" => "call_id"}} = confirm.(theirs)
      for id <- [live, ended, theirs], do: assert(is_nil(row!(ctx, id).slot_released_at))
    end

    test "is refused once given, and for a call past OpenAI's limit", ctx do
      seed!(ctx, phone_calls: phone(true))
      manager = start_manager(ctx)
      id = seed_call!(ctx, "main-confirm-6", [:claim, {:end, "dispatch_unknown"}])
      confirm = &route(ctx, "phone_calls.recovery.confirm", %{"call_id" => &1}, manager)
      assert {:ok, _confirmed} = confirm.(id)

      assert {:error, :unavailable,
              %{"sentence" => "That call has no unconfirmed end to confirm."}} = confirm.(id)

      expired = seed_call!(ctx, "main-confirm-7", [:claim, {:end, "dispatch_unknown"}])
      later = DateTime.add(@t0, Limits.slot_hold_ms(), :millisecond)
      opts = Keyword.put(phone_opts(ctx, manager), :now, later)

      assert {:error, :unavailable,
              %{"sentence" => "That call has no unconfirmed end to confirm."}} =
               PhoneCalls.route("phone_calls.recovery.confirm", %{"call_id" => expired}, opts)

      assert is_nil(row!(ctx, expired).slot_released_at)
    end

    test "where no call manager runs, nothing is recorded and it says so", ctx do
      seed!(ctx, phone_calls: phone(true))
      id = seed_call!(ctx, "main-confirm-8", [:claim, {:end, "dispatch_unknown"}])

      assert {:error, :unavailable, %{"sentence" => sentence}} =
               route(ctx, "phone_calls.recovery.confirm", %{"call_id" => id})

      assert sentence ==
               "Phone calls are not running here, so Fermix could not record that the call ended."

      assert is_nil(row!(ctx, id).slot_released_at)
    end

    test "takes the call's id and nothing else", ctx do
      assert {:error, :invalid_params, %{"field" => "call_id"}} =
               route(ctx, "phone_calls.recovery.confirm")

      assert {:error, :invalid_params, %{"field" => "force"}} =
               route(ctx, "phone_calls.recovery.confirm", %{
                 "call_id" => "pc_0a1b2c3d4e5f",
                 "force" => true
               })
    end

    test "is the owner's alone: the phone call tool offers no way to it" do
      %{properties: %{action: %{enum: actions}}} = PhoneCallTool.parameters()

      assert actions == ~w(start status cancel)
    end
  end

  # A process that is not the home's running engine (a setup page served
  # from another tree, a command that booted one) owns no worker of the
  # daemon's: it says the call is the running Fermix's, and changes nothing.
  describe "a call the running engine owns" do
    # As `FermixCore.Application.phone_calls_opts/2` starts one outside the
    # daemon: no boot reconciliation, no timers.
    @not_the_daemon [daemon: false, reconcile: false]

    test "is stopped and confirmed there, in the stop's own sentences", ctx do
      seed!(ctx, phone_calls: phone(true))
      live = seed_call!(ctx, "main-elsewhere-1", [:claim, :session])
      manager = start_manager(ctx, @not_the_daemon)

      assert {:error, :unavailable, %{"capability" => "phone_calls", "sentence" => stop}} =
               route(ctx, "phone_calls.stop", %{"call_id" => live}, manager)

      assert stop == "That call belongs to the Fermix that is running, so it is stopped there."
      assert stop == Report.owned_elsewhere(:stop)
      assert is_nil(row!(ctx, live).cancel_requested_at)

      step!(ctx, live, {:end, "closure_unconfirmed"})

      assert {:error, :unavailable, %{"sentence" => confirm}} =
               route(ctx, "phone_calls.recovery.confirm", %{"call_id" => live}, manager)

      assert confirm ==
               "That call belongs to the Fermix that is running, so its end is confirmed there."

      assert is_nil(row!(ctx, live).slot_released_at)
    end

    test "the off switch says the running engine still has the call", ctx do
      seed_ready!(ctx)
      seed_call!(ctx, "main-elsewhere-2", [:claim, :session])
      manager = start_manager(ctx, @not_the_daemon)

      assert {:ok, result} = apply_phone(ctx, %{"phone_calls_enabled" => false}, manager)

      assert result["side_effects"] == [
               "The Fermix that is running still has 1 call, and applies the switch when it " <>
                 "reads the setting."
             ]
    end
  end

  # The owner's own restart (M94 §12): the drain window a restart to apply
  # takes, refused while a call is in progress. An update, a move or a
  # disable takes `lifecycle.prepare`, which no call holds.
  describe "the owner's restart" do
    setup ctx do
      test = self()

      lifecycle =
        start_supervised!(
          {Lifecycle,
           name: :"phone_lifecycle_#{ctx.unique}", shutdown: fn -> send(test, :stopped) end}
        )

      registry = :"phone_restart_registry_#{ctx.unique}"
      start_supervised!({Registry, keys: :unique, name: registry}, id: registry)
      %{lifecycle: lifecycle, registry: registry}
    end

    test "is refused while a call is in progress, and opens no window", ctx do
      seed!(ctx, phone_calls: phone(true))
      id = seed_call!(ctx, "main-restart-1", [:claim, :session])
      # The call's worker runs: a process registered under its id, as one is.
      worker = {Agent, fn -> {:ok, _owner} = Registry.register(ctx.registry, id, nil) end}
      start_supervised!(worker, id: :restart_worker)

      assert {:error, :unavailable, %{"capability" => "phone_calls", "sentence" => sentence}} =
               restart_route(ctx, "lifecycle.prepare_restart")

      assert sentence ==
               "A phone call is in progress, and restarting Fermix now would hang it up " <>
                 "without its outcome. Ask Fermix to stop the call, or let it end, then restart."

      refute Lifecycle.prepared?(server: ctx.lifecycle)

      # A stop that is not the owner's restart is not asked.
      assert {:ok, %{"lease_id" => lease_id}} = restart_route(ctx, "lifecycle.prepare")
      assert {:ok, _cancelled} = restart_route(ctx, "lifecycle.cancel", %{"lease_id" => lease_id})
      refute_received :stopped
    end

    test "opens the same window as any other once no call is in progress", ctx do
      seed!(ctx, phone_calls: phone(true))
      seed_call!(ctx, "main-restart-2", [:claim, :session, {:end, "closure_unconfirmed"}])

      assert {:ok, %{"lease_id" => lease_id, "ttl_ms" => ttl}} =
               restart_route(ctx, "lifecycle.prepare_restart")

      assert is_integer(ttl) and ttl > 0
      assert Lifecycle.prepared?(server: ctx.lifecycle)

      assert {:ok, %{"status" => "cancelled"}} =
               restart_route(ctx, "lifecycle.cancel", %{"lease_id" => lease_id})
    end

    test "takes no parameters", ctx do
      assert {:error, :invalid_params, _details} =
               restart_route(ctx, "lifecycle.prepare_restart", %{"purpose" => "restart"})
    end
  end

  describe "the credentials a call reads" do
    test "cannot be changed or forgotten while a call is in progress", ctx do
      seed_ready!(ctx)
      id = seed_call!(ctx, "main-secret-1", [:claim])

      for change <- [
            fn -> set_secret(ctx, "phone_calls_sip_password", "another-invented-password") end,
            fn -> set_secret(ctx, "openai_api_key", "sk-another-invented-key") end,
            fn -> Secrets.clear("openai_api_key", phone_calls: phone_opts(ctx)) end,
            fn -> Secrets.clear("phone_calls_sip_password", phone_calls: phone_opts(ctx)) end
          ] do
        assert {:error, {:unavailable, "phone_calls", sentence}} = change.()
        assert sentence =~ "A phone call is in progress"
      end

      assert SecretWriterStub.get(:phone_calls_sip_password) == {:ok, @password}
      assert SecretWriterStub.get(:openai_api_key) == {:ok, @openai_key}

      # A key no phone call reads is not held.
      assert {:ok, %{"present" => true}} = set_secret(ctx, "xai_api_key", @xai_key)

      {:ok, _row} = Ledger.terminalize(id, "failed", %{ended_at: @t0}, server: ctx.repo)

      assert {:ok, %{"present" => true}} =
               set_secret(ctx, "openai_api_key", "sk-another-invented-key")

      assert SecretWriterStub.get(:openai_api_key) == {:ok, "sk-another-invented-key"}
    end

    # The setup page's forms write through the wizard's answers, the same
    # writer that holds the key for `secret.set`: nothing of a held save
    # lands, the store choice included.
    test "the setup forms' answers are held by the same writer", ctx do
      seed_ready!(ctx, realtime: [enabled: true, engine: "openai_live", model: "gpt-live-1"])
      id = seed_call!(ctx, "main-secret-3", [:claim])
      held = [repo: ctx.repo]

      for answers <- [
            [edit_provider: :openai, openai_api_key: "sk-another-invented-key"],
            [realtime_api_key: "sk-another-invented-key"],
            [realtime_api_key: "sk-another-invented-key", secret_store: "file"]
          ] do
        assert {:error, {:credential_held, :openai_api_key, sentence}} =
                 Wizard.save_answers(Wizard.report().wizard, answers, phone_calls: held)

        assert sentence =~ "A phone call is in progress and uses this key."
      end

      assert SecretWriterStub.get(:openai_api_key) == {:ok, @openai_key}
      assert SecretWriter.store() == :keyring

      # The voice key under Grok is SpaceXAI's, which no phone call reads.
      grok = [realtime_model: "grok-voice-3.0", realtime_api_key: "xai-another-invented-key"]
      assert {:ok, _report} = Wizard.save_answers(Wizard.report().wizard, grok, phone_calls: held)
      assert SecretWriterStub.get(:xai_api_key) == {:ok, "xai-another-invented-key"}

      {:ok, _row} = Ledger.terminalize(id, "failed", %{ended_at: @t0}, server: ctx.repo)

      assert {:ok, _report} =
               Wizard.save_answers(
                 Wizard.report().wizard,
                 [edit_provider: :openai, openai_api_key: "sk-another-invented-key"],
                 phone_calls: held
               )

      assert SecretWriterStub.get(:openai_api_key) == {:ok, "sk-another-invented-key"}
    end

    test "a trunk password outside the provider's bounds is refused in the owner's words", ctx do
      seed!(ctx, [])

      assert {:error, {:invalid_params, "value", sentence}} =
               set_secret(ctx, "phone_calls_sip_password", "invented\npassword")

      assert sentence == PhoneCalls.password_sentence(:control_characters)

      assert {:error, {:invalid_params, "value", _too_long}} =
               set_secret(ctx, "phone_calls_sip_password", String.duplicate("p", 4097))

      assert SecretWriterStub.get(:phone_calls_sip_password) != {:ok, "invented\npassword"}
    end

    test "no answer carries a credential", ctx do
      seed_ready!(ctx)
      seed_call!(ctx, "main-secret-2", [:claim, :session, {:end, "closure_unconfirmed"}])

      answers =
        for method <- PhoneCalls.methods() -- ["phone_calls.stop", "phone_calls.recovery.confirm"],
            do: route(ctx, method)

      answers = [{:ok, %{"rows" => rows(ctx)}} | answers]
      encoded = Jason.encode!(Enum.map(answers, fn {:ok, view} -> view end))

      refute encoded =~ @password
      refute encoded =~ @openai_key
      refute encoded =~ @xai_key
    end
  end

  # M94 §14, "Independent voice / phone combinations": every on and off pair
  # of Talk to Fermix (on Grok) and Phone calls. A save of one section leaves
  # the other's saved values and secret references exactly as they were, the
  # local section's restart-bound save included.
  describe "the independence of Talk to Fermix and Phone calls" do
    for local? <- [true, false], phone? <- [true, false] do
      @tag local: local?, phone: phone?
      test "local voice #{if local?, do: "on", else: "off"}, phone calls #{if phone?, do: "on", else: "off"}",
           %{local: local?, phone: phone?} = ctx do
        seed_ready!(ctx, realtime: grok(local?), phone_calls_enabled: phone?)
        phone_before = phone_state()

        # Talk to Fermix's rows ask for a restart; a save of one is no
        # restart of phone calls, and changes nothing of theirs.
        assert Row.restart?(:realtime)
        refute Row.restart?(:phone_calls)

        assert {:ok, %{"applied" => applied}} =
                 Settings.apply("realtime", %{"realtime_voice" => other_voice(grok(local?))},
                   phone_calls: phone_opts(ctx)
                 )

        assert "realtime_voice" in applied
        assert phone_state() == phone_before
        restarting = for row <- rows(ctx), row["restart"], do: row["key"]
        assert restarting == ["openai_api_key"]

        local_before = local_state()

        assert {:ok, %{"applied" => ["phone_calls_voice"]}} =
                 apply_phone(ctx, %{"phone_calls_voice" => "verse"})

        assert local_state() == local_before
        assert Config.get().enabled == phone?
      end
    end
  end

  # -- seeding ---------------------------------------------------------------------

  defp phone(enabled?) do
    base = [caller_number: @caller, sip_username: @username]
    if enabled?, do: [enabled: true] ++ base, else: base
  end

  defp grok(enabled?),
    do: [enabled: enabled?, engine: "xai_realtime", model: "grok-voice-3.0", voice: "eve"]

  defp other_voice(realtime) do
    config = RealtimeConfig.normalize(realtime)
    config.engine |> RealtimeConfig.valid_voices() |> Enum.find(&(&1 != config.voice))
  end

  # The sections as the settings file and application environment hold them,
  # then each secret stored as `secret.set` stores it.
  defp seed!(ctx, opts) do
    Application.put_env(:fermix_core, :realtime, Keyword.get(opts, :realtime, []))
    Application.put_env(:fermix_core, :phone_calls, Keyword.get(opts, :phone_calls, []))
    :ok = ConfigStore.save_snapshot(ConfigStore.current_snapshot())

    for {id, value} <- Keyword.get(opts, :secrets, []) do
      assert {:ok, %{"present" => true}} = set_secret(ctx, id, value)
    end

    :ok
  end

  defp seed_ready!(ctx, opts \\ []) do
    seed!(ctx,
      realtime: Keyword.get(opts, :realtime, []),
      phone_calls: phone(Keyword.get(opts, :phone_calls_enabled, true)),
      secrets: [
        {"openai_api_key", @openai_key},
        {"xai_api_key", @xai_key},
        {"phone_calls_sip_password", @password}
      ]
    )
  end

  # A row of the ledger without a worker: admitted, then each step.
  defp seed_call!(ctx, request_id, steps, owner \\ "default") do
    brief = brief!()

    attrs = %{
      request_id: request_id,
      owner_id: owner,
      authorization: "direct",
      origin_kind: "chat",
      delivery_mode: "origin",
      platform: "telegram",
      destination: "40017",
      mandate: Brief.to_map(brief),
      mandate_hash: Brief.hash(brief),
      model: "gpt-live-1",
      voice: "marin",
      prompt_version: "phone-test-1",
      carrier_profile: "telnyx_credential_v1"
    }

    {:ok, {:admitted, row}} = Ledger.admit(attrs, @t0, server: ctx.repo)
    Enum.each(steps, &step!(ctx, row.id, &1))
    row.id
  end

  defp step!(ctx, id, :claim), do: {:ok, _row} = Ledger.claim_dispatch(id, @t0, server: ctx.repo)

  defp step!(ctx, id, :session),
    do: {:ok, _row} = Ledger.record_session(id, "sess_seeded", @t0, server: ctx.repo)

  defp step!(ctx, id, {:end, "ended"}) do
    fields = %{
      ended_at: @t0,
      outcome: "options",
      voice_seconds: 95,
      usage_state: "voice_duration_confirmed"
    }

    {:ok, _row} = Ledger.terminalize(id, "ended", fields, server: ctx.repo)
  end

  defp step!(ctx, id, {:end, status}),
    do: {:ok, _row} = Ledger.terminalize(id, status, %{ended_at: @t0}, server: ctx.repo)

  defp brief! do
    params = %{
      "destination" => @destination,
      "destination_kind" => "business",
      "number_source" => "The bistro's own website.",
      "contact_name" => "Calloway Bistro",
      "timezone" => "America/New_York",
      "goal" => "Ask for a table for two on Saturday at 19:30.",
      "completion_criteria" => ["The host confirms a table for two at 19:30."]
    }

    {:ok, brief} = Brief.new(params, caller_number: @caller, now: @t0)
    brief
  end

  # -- the call manager --------------------------------------------------------------

  defp start_manager(ctx, extra \\ []) do
    names = %{
      handoff: :"management_phone_handoff_#{ctx.unique}",
      calls: :"management_phone_calls_sup_#{ctx.unique}",
      name: :"management_phone_manager_#{ctx.unique}"
    }

    start_supervised!({Task.Supervisor, name: names.handoff})
    start_supervised!({FermixCore.PhoneCalls.CallSupervisor, name: names.calls})

    start_supervised!(
      {Manager,
       name: names.name,
       call_module: FakeCall,
       hangup: fn _session_id -> :ok end,
       repo: ctx.repo,
       call_supervisor: names.calls,
       handoff_supervisor: names.handoff,
       readiness: fn -> Readiness.current(@host) end,
       now_fn: fn -> @t0 end,
       continuation_dispatcher: SinkDispatcher,
       timer_enabled: false}
      |> then(fn {module, opts} -> {module, Keyword.merge(opts, extra)} end)
    )

    Map.put(names, :pid, GenServer.whereis(names.name))
  end

  defp request do
    brief = brief!()
    unique = System.unique_integer([:positive])

    %{
      brief: brief,
      brief_hash: Brief.hash(brief),
      request_id: "req-phone-#{unique}",
      parent_session: "main-#{unique}",
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
  end

  # Starts a call and waits for its worker, pinning its telemetry by request.
  defp start_call!(manager) do
    request = request()
    TelemetryCapture.attach(@events, parent_session: request.parent_session)

    assert {:ok, %{call_id: id, state: "admitted"}} = Manager.start_call(request, manager.name)
    assert_receive {:started, ^id, pid}
    assert_receive {:telemetry, [:fermix, :phone_call, :run_start], _measurements, _meta}
    %{id: id, pid: pid}
  end

  defp claim!(call),
    do: FakeCall.run(call.pid, &Ledger.claim_dispatch(&1.call_id, @t0, server: &1.repo))

  defp session!(call, session_id) do
    {:ok, _row} = claim!(call)
    FakeCall.run(call.pid, &Ledger.record_session(&1.call_id, session_id, @t0, server: &1.repo))
  end

  # Ends the worker once the Manager's monitor on it is in place, the way a
  # crash would, and waits for the Manager's closer of its row.
  defp lose_worker!(call, manager) do
    assert {:monitored_by, monitors} = Process.info(call.pid, :monitored_by)
    assert manager.pid in monitors
    Process.exit(call.pid, :kill)
    assert_receive {:telemetry, [:fermix, :phone_call, closer], _measurements, _meta}
    assert closer in [:run_complete, :run_error]
    :ok
  end

  # -- reading ---------------------------------------------------------------------

  # A case with no call manager of its own names one that never runs, so the
  # application's own is never reached.
  defp phone_opts(ctx, manager \\ nil) do
    name = if manager, do: manager.name, else: :"management_phone_no_manager_#{ctx.unique}"
    [repo: ctx.repo, now: @t0, readiness: @host, manager: name]
  end

  defp apply_phone(ctx, values, manager \\ nil) do
    opts = phone_opts(ctx, manager)

    Settings.apply("phone_calls", values,
      phone_calls: opts,
      phone_calls_switch: &PhoneCalls.apply_enabled(&1, opts)
    )
  end

  defp set_secret(ctx, id, value), do: Secrets.set(id, value, phone_calls: phone_opts(ctx))

  defp rows(ctx, manager \\ nil) do
    {:ok, %{"rows" => rows}} = Settings.get("phone_calls", phone_calls: phone_opts(ctx, manager))
    rows
  end

  defp row(rows, key), do: Enum.find(rows, &(&1["key"] == key))

  defp row!(ctx, id) do
    {:ok, row} = Ledger.get(id, server: ctx.repo)
    row
  end

  defp route(ctx, method, params \\ %{}, manager \\ nil),
    do:
      Router.route(request(method, params),
        operation_opts: [phone_calls: phone_opts(ctx, manager)]
      )

  defp restart_route(ctx, method, params \\ %{}),
    do:
      Router.route(request(method, params),
        lifecycle_server: ctx.lifecycle,
        operation_opts: [phone_calls: Keyword.put(phone_opts(ctx), :registry, ctx.registry)]
      )

  defp request(method, params \\ %{}),
    do: %{request_id: "req-1", protocol_version: 2, method: method, params: params}

  # An outside edit of the settings file: `from` is there exactly once.
  defp edit_config!(ctx, from, to) do
    path = Path.join(ctx.home, "config.toml")
    text = File.read!(path)
    assert [_before, _after] = String.split(text, from)
    File.write!(path, String.replace(text, from, to))
  end

  defp persisted!(section) do
    {:ok, persisted} = RestartState.load_persisted()
    Keyword.get(persisted.fermix_core, section, [])
  end

  # What the phone section holds: its saved values and secret reference, its
  # value in force, and the stored password.
  defp phone_state do
    {persisted!(:phone_calls), Config.get(), SecretWriterStub.get(:phone_calls_sip_password)}
  end

  # What Talk to Fermix holds: its saved values, its value in force, and the
  # saved references and stored values of the two voice providers' keys.
  defp local_state do
    providers = persisted!(:providers)

    {persisted!(:realtime),
     RealtimeConfig.normalize(Application.get_env(:fermix_core, :realtime)),
     providers[:openai][:api_key], providers[:xai][:api_key],
     SecretWriterStub.get(:openai_api_key), SecretWriterStub.get(:xai_api_key)}
  end

  defp restore_all(app, env) do
    for {key, _value} <- Application.get_all_env(app),
        not Keyword.has_key?(env, key),
        do: Application.delete_env(app, key)

    for {key, value} <- env, do: Application.put_env(app, key, value)
  end
end
