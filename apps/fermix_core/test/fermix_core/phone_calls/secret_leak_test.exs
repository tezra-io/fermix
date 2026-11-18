defmodule FermixCore.PhoneCalls.SecretLeakTest do
  @moduledoc """
  Neither credential of a phone call ever reaches the text a finished call
  leaves behind (M94 §11, "Credentials are redacted before logging or content
  capture").

  Two calls run through the real pieces: the `phone_call` tool on an owner's
  turn, `PhoneCalls.Manager`, the `PhoneCalls.Call` worker and the production
  `PhoneCalls.CallTransport` (`OpenAILive`, `OpenAILive.Sideband`) against one
  loopback stand-in of the vendor (Bandit), the real hand-off, report and
  management views. The API key and the trunk password are invented and
  distinctive, and the vendor quotes them back in its failures: the first
  call's create is refused with an error that names both, and the second
  call, answered, ends at its deadline with a hang-up answered by a gateway's
  page that names the key, so its end stays unconfirmed and the call stays in
  the recovery view. Then every place a finished call leaves text is read:
  each ledger row whole, both renderings of each report, the tool's status,
  the management status, list and recovery views, the hand-off's notices,
  every log line at debug, every Fermix telemetry event's metadata, and the
  worker's printed status. The backend turn, the outcome reader and the clocks
  are fakes; nothing reaches a vendor.

  A second case does the same for what the vendor says over the sideband
  during a call, quoting both secrets as stored, after `Bearer ` and inside
  JSON: an `error` event, a `transport.failed`, a `session.closed` reason, an
  event of a type Fermix does not know (its type and its body), and the close
  frame of a socket the vendor drops.

  async: false: the fakes report to a registered sink, and the log level is
  raised to debug for the test and restored.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias FermixCore.Agents.RequestIdentity
  alias FermixCore.Management.PhoneCalls, as: ManagementPhoneCalls
  alias FermixCore.Memory.Repo
  alias FermixCore.Net.Egress
  alias FermixCore.PhoneCalls.CallControls
  alias FermixCore.PhoneCalls.Config
  alias FermixCore.PhoneCalls.Ledger
  alias FermixCore.PhoneCalls.Report
  alias FermixCore.Tools.PhoneCall
  alias FermixTestSupport.PhoneCallFakes, as: Fakes

  @arrival_ms 10_000
  @t0 ~U[2031-03-04 15:00:00.000000Z]
  @session "live_u0_leak01"

  # Invented, and shaped so that no other text could hold them by accident.
  @api_key "sk-LEAKCANARYkey7q9z3xWv"
  @password "LEAKCANARYtrunk4e8d2bQm"
  @secrets [@api_key, @password, "LEAKCANARYkey", "LEAKCANARYtrunk"]
  # Both secrets as a vendor's words can carry them: as stored, after
  # `Bearer `, inside JSON, and the password inside a basic-auth base64.
  @basic Base.encode64("fermixtrunk01:" <> @password)
  @quoted "Bearer #{@api_key} refused for trunk password #{@password}; " <>
            ~s(sent {"api_key":"#{@api_key}","password":"#{@password}"} basic #{@basic})
  # The key as OpenAI quotes a refused one back: masked, its last characters kept.
  @masked "sk-LEAKCAN**************3xWv"

  defmodule Vendor do
    @moduledoc false
    @behaviour Plug

    import Plug.Conn

    @impl true
    def init(opts), do: opts

    @impl true
    def call(%{method: "POST", request_path: "/v1/live/sessions"} = conn, %{test: test} = opts) do
      {:ok, raw, conn} = read_body(conn)
      send(test, {:vendor_create, conn.req_headers, Jason.decode!(raw)})
      {status, body} = Agent.get_and_update(opts.creates, fn [next | rest] -> {next, rest} end)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, body)
    end

    def call(
          %{method: "POST", path_info: ["v1", "live", "sessions", _session, "hangup"]} = conn,
          %{test: test, hangup_page: page}
        ) do
      send(test, {:vendor_hangup, conn.req_headers})

      conn
      |> put_resp_content_type("text/html")
      |> send_resp(502, page)
    end

    def call(%{path_info: ["v1", "live", "sessions", _session, "attach"]} = conn, %{test: test}),
      do: upgrade_adapter(conn, :websocket, {Vendor.Socket, %{test: test}, []})
  end

  defmodule Vendor.Socket do
    @moduledoc false
    @behaviour WebSock

    @impl true
    def init(%{test: test} = state) do
      send(test, {:vendor_socket, self()})
      {:ok, state}
    end

    @impl true
    def handle_in({_text, opcode: :text}, state), do: {:ok, state}

    @impl true
    def handle_info({:push, frames}, state), do: {:push, Enum.map(frames, &{:text, &1}), state}
    def handle_info({:close, code, text}, state), do: {:stop, :normal, {code, text}, state}
  end

  # The real worker, started by the Manager with its own args plus the seams.
  defmodule LeakCall do
    alias FermixCore.PhoneCalls.Call

    def start_link(args),
      do: Call.start_link(Map.merge(args, FermixTestSupport.PhoneCallFakes.scripted(:seams, %{})))

    def cancel(pid, why), do: Call.cancel(pid, why)
    def prompt_version, do: "phone-leak-1"
  end

  # A finished call's notice goes to the test, never into a gateway.
  defmodule SinkDispatcher do
    def dispatch(notice), do: FermixTestSupport.PhoneCallFakes.notify({:dispatched, notice})
  end

  @doc false
  def forward(event, _measurements, metadata, test),
    do: send(test, {:leak_telemetry, event, metadata})

  setup ctx do
    Process.flag(:trap_exit, true)
    Fakes.register_sink!()
    start_supervised!(Fakes.script_spec())

    level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: level) end)

    unique = System.unique_integer([:positive])
    repo = repo!(unique)
    origins = vendor!(Map.get(ctx, :sessions))
    names = subtree!(unique, repo)
    clock = :atomics.new(1, [])

    Fakes.script(
      :seams,
      clock
      |> Fakes.seams()
      |> Map.drop([:transport, :ledger])
      |> Map.merge(%{
        transport_opts: origins,
        config: &config/0,
        credentials: &credentials/1,
        registry: CallControls.registry_name()
      })
    )

    attach_telemetry!()
    %{repo: repo, names: names, clock: clock}
  end

  defp config do
    %Config{
      enabled: true,
      voice: "marin",
      caller_number: Fakes.caller(),
      sip_username: "fermixtrunk01",
      sip_password: @password
    }
  end

  defp credentials(%Config{}),
    do: {:ok, %{api_key: @api_key, sip_username: "fermixtrunk01", sip_password: @password}}

  defp repo!(unique) do
    db_path = Path.join(System.tmp_dir!(), "fermix-phone-leak-#{unique}.db")
    repo = :"phone_leak_repo_#{unique}"
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path}, id: repo)

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    repo
  end

  # By default the first create is refused with an error naming both secrets
  # and the second places the call; with `sessions`, each create places one.
  # The hang-up is answered by a gateway's page naming the key.
  defp vendor!(sessions) do
    refused =
      Jason.encode!(%{
        "error" => %{
          "message" =>
            "Trunk auth failed for fermixtrunk01 with password #{@password}; " <>
              "request authorized by Bearer #{@api_key}",
          "type" => "server_error",
          "code" => "sip_trunk_error"
        }
      })

    placed = &~s({"session":{"id":"#{&1}"},"transport":{"type":"sip"}})

    answers =
      case sessions do
        nil -> [{500, refused}, {201, placed.(@session)}]
        [_ | _] -> Enum.map(sessions, &{201, placed.(&1)})
      end

    creates = start_supervised!({Agent, fn -> answers end})
    page = "<html><body>502 Bad Gateway: upstream refused Bearer #{@api_key}</body></html>"

    server =
      start_supervised!(
        {Bandit,
         plug: {Vendor, %{test: self(), creates: creates, hangup_page: page}},
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false},
        id: make_ref()
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    [
      base_url: "http://127.0.0.1:#{port}",
      ws_base_url: "ws://127.0.0.1:#{port}",
      egress: Egress.new([])
    ]
  end

  defp subtree!(unique, repo) do
    names = %{
      supervisor: :"phone_leak_sup_#{unique}",
      call_registry: :"phone_leak_call_registry_#{unique}",
      handoff_supervisor: :"phone_leak_handoff_#{unique}",
      manager: :"phone_leak_manager_#{unique}",
      call_supervisor: :"phone_leak_calls_#{unique}",
      delivery_worker: :"phone_leak_delivery_#{unique}"
    }

    start_supervised!(
      {FermixCore.PhoneCalls.Supervisor,
       call_module: LeakCall,
       hangup: fn session_id ->
         Fakes.notify({:manager_hangup, session_id})
         :ok
       end,
       names: names,
       repo: repo,
       readiness: fn -> :ready end,
       config: &config/0,
       now_fn: fn -> @t0 end,
       continuation_dispatcher: SinkDispatcher,
       reconcile: false,
       timer_enabled: false}
    )

    names
  end

  # Every Fermix event anything listens to, and the feature's own.
  defp attach_telemetry! do
    events =
      [:fermix]
      |> :telemetry.list_handlers()
      |> Enum.map(& &1.event_name)
      |> Kernel.++([
        [:fermix, :tool, :exec],
        [:fermix, :provider, :call],
        [:fermix, :phone_call, :run_start],
        [:fermix, :phone_call, :run_complete],
        [:fermix, :phone_call, :run_error]
      ])
      |> Enum.uniq()

    id = {__MODULE__, System.unique_integer([:positive])}
    :ok = :telemetry.attach_many(id, events, &__MODULE__.forward/4, self())
    on_exit(fn -> :telemetry.detach(id) end)
  end

  # An owner's attended chat turn, with this test's manager, readiness, setup
  # and clock in the context seams the tool reads.
  defp owner_turn(ctx) do
    %{
      agent_name: "main",
      request_id: RequestIdentity.mint(),
      session_id: "main-leak-#{System.unique_integer([:positive])}",
      conversation_key: {"telegram", "40017", :root},
      source_trust: :operator,
      computer_use_origin: :interactive,
      chat_type: "private",
      outside_sources: MapSet.new(),
      memory_owner_id: "default",
      memory_repo: ctx.repo,
      phone_call_manager: ctx.names.manager,
      phone_call_readiness: fn -> :ready end,
      phone_call_config: &config/0,
      phone_call_now: fn -> @t0 end
    }
  end

  defp start!(ctx) do
    brief = %{
      "destination" => "+12125550101",
      "destination_kind" => "business",
      "number_source" => "The bistro's own website.",
      "contact_name" => "Calloway Bistro",
      "timezone" => "America/New_York",
      "goal" => "Ask for a table for two on Saturday, March 8, 2031 at 7:30 PM.",
      "completion_criteria" => ["The bistro confirms a table for two at 7:30 PM."],
      "times" => [%{"label" => "Requested table", "at" => "2031-03-08T19:30"}]
    }

    assert {:ok, %{success: true, output: output}} =
             PhoneCall.execute(%{"action" => "start", "brief" => brief}, owner_turn(ctx))

    assert %{"call_id" => id, "status" => "accepted"} = Jason.decode!(output)

    # The secrets really go to the wire: the key as the bearer, the password
    # in the trunk's digest auth.
    assert_receive {:vendor_create, headers, body}, @arrival_ms
    assert {"authorization", "Bearer " <> @api_key} in headers
    assert body["transport"]["trunk"]["auth"]["password"] == @password
    id
  end

  defp fire!(worker, kind) do
    _state = :sys.get_state(worker)
    assert_receive {:scheduled, {:phone_call_timer, ^kind, _token} = message, _ms}, @arrival_ms
    send(worker, message)
  end

  # The refused create: nothing placed, the report handed off.
  defp refused_call!(ctx) do
    id = start!(ctx)
    assert_receive {:dispatched, %{metadata: %{phone_call_result: ^id}} = notice}, @arrival_ms
    {id, notice}
  end

  # The placed call, answered, ended at its deadline with a hang-up the
  # gateway answers with its page. Answers its id, its notice and the
  # worker's printed status once the failure's words are in its state.
  defp unconfirmed_call!(ctx) do
    id = start!(ctx)
    assert_receive {:vendor_socket, socket}, @arrival_ms
    [{worker, _value}] = Registry.lookup(CallControls.registry_name(), id)

    answered = %{"type" => "transport.answered", "event_id" => "s1", "session_id" => @session}
    send(socket, {:push, [Jason.encode!(answered)]})
    assert_receive {:scheduled, {:phone_call_timer, :silence, _token}, _ms}, @arrival_ms
    # Nobody speaks within the opening's wait: the opening goes.
    fire!(worker, :opening)

    fire!(worker, :deadline)
    _state = :sys.get_state(worker)
    :atomics.add(ctx.clock, 1, 60_000)
    fire!(worker, :speech)
    assert_receive {:vendor_hangup, hangup_headers}, @arrival_ms
    assert {"authorization", "Bearer " <> @api_key} in hangup_headers

    assert_receive {:scheduled, {:phone_call_timer, :drain, _token} = drain, _ms}, @arrival_ms
    printed = printed(:sys.get_status(worker))
    send(worker, drain)

    assert_receive {:dispatched, %{metadata: %{phone_call_result: ^id}} = notice}, @arrival_ms
    {id, notice, printed}
  end

  defp await_handoffs(ctx) do
    for pid <- Task.Supervisor.children(ctx.names.handoff_supervisor) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, @arrival_ms
    end

    :ok
  end

  defp printed(term), do: inspect(term, limit: :infinity, printable_limit: :infinity)

  defp telemetry_seen do
    receive do
      {:leak_telemetry, event, metadata} -> [{event, printed(metadata)} | telemetry_seen()]
    after
      0 -> []
    end
  end

  # Every place a finished call leaves text, by name.
  defp surfaces(ctx, ids) do
    views = [repo: ctx.repo, manager: ctx.names.manager, now: @t0, owner_id: "default"]
    status_opts = views ++ [config: config(), readiness: [openai_api_key?: true]]

    per_call =
      Enum.flat_map(ids, fn id ->
        {:ok, row} = Ledger.get(id, server: ctx.repo)

        {:ok, %{output: status}} =
          PhoneCall.execute(%{"action" => "status", "call_id" => id}, owner_turn(ctx))

        [
          {"#{id} ledger row", printed(row)},
          {"#{id} report text", Report.text(row)},
          {"#{id} report notice", Report.notice(row)},
          {"#{id} report status view", printed(Report.status_view(row, @t0))},
          {"#{id} tool status", status}
        ]
      end)

    per_call ++
      [
        {"management status", printed(ManagementPhoneCalls.status(status_opts))},
        {"management list", printed(ManagementPhoneCalls.list(views))},
        {"management recovery", printed(ManagementPhoneCalls.recovery(views))}
      ]
  end

  defp push(socket, events), do: send(socket, {:push, Enum.map(events, &Jason.encode!/1)})

  # A placed call, answered on `session`: its id, its worker and the socket.
  defp answered_on!(ctx, session) do
    id = start!(ctx)
    assert_receive {:vendor_socket, socket}, @arrival_ms
    [{worker, _value}] = Registry.lookup(CallControls.registry_name(), id)

    push(socket, [
      %{"type" => "transport.answered", "event_id" => "#{session}_a", "session_id" => session}
    ])

    assert_receive {:scheduled, {:phone_call_timer, :silence, _token}, _ms}, @arrival_ms
    # Nobody speaks within the opening's wait: the opening goes.
    fire!(worker, :opening)
    %{id: id, worker: worker, socket: socket, session: session}
  end

  # A call the carrier fails, after an event of a type Fermix does not know;
  # its hang-up is answered by the gateway's page, then `session.closed`
  # confirms the end with a reason. Every one quotes both secrets.
  defp failed_on_the_line!(ctx, session) do
    call = answered_on!(ctx, session)

    push(call.socket, [
      %{
        "type" => "vendor.future.#{@api_key}",
        "event_id" => "#{session}_u",
        "detail" => @quoted <> " " <> @masked
      },
      %{
        "type" => "transport.failed",
        "event_id" => "#{session}_f",
        "session_id" => session,
        "error" => %{
          "code" => "sip_trunk_error",
          "message" => "Incorrect API key provided: #{@masked}. " <> @quoted
        }
      }
    ])

    # The failure reached the worker once it waits for the opening to finish.
    assert_receive {:scheduled, {:phone_call_timer, :speech, _token} = speech, _ms}, @arrival_ms
    _state = :sys.get_state(call.worker)
    :atomics.add(ctx.clock, 1, 60_000)
    send(call.worker, speech)
    assert_receive {:vendor_hangup, _headers}, @arrival_ms
    assert_receive {:scheduled, {:phone_call_timer, :drain, _token}, _ms}, @arrival_ms

    push(call.socket, [
      %{
        "type" => "session.closed",
        "event_id" => "#{session}_c",
        "reason" => "closed: " <> @quoted,
        "usage" => %{"seconds" => 7}
      }
    ])

    assert_receive {:dispatched, %{metadata: %{phone_call_result: id}} = notice}, @arrival_ms
    assert id == call.id
    {call.id, notice}
  end

  # A call whose vendor reports an error and then drops the socket with a
  # close frame, both quoting both secrets; the end stays unconfirmed. Answers
  # the worker's printed status once the error's words are in its state.
  defp lost_on_the_line!(ctx, session) do
    call = answered_on!(ctx, session)

    push(call.socket, [
      %{
        "type" => "error",
        "event_id" => "#{session}_e",
        "error" => %{"type" => "invalid_request_error", "message" => @quoted}
      },
      %{
        "type" => "session.input_transcript.delta",
        "event_id" => "#{session}_t",
        "delta" => "Hello?"
      }
    ])

    # The recipient's words re-arm the silence bound, after the error before them.
    assert_receive {:scheduled, {:phone_call_timer, :silence, _token}, _ms}, @arrival_ms
    printed = printed(:sys.get_status(call.worker))
    # A close frame's reason is at most 123 bytes.
    send(call.socket, {:close, 4000, "dropped: Bearer #{@api_key} #{@password}"})
    assert_receive {:vendor_hangup, _headers}, @arrival_ms

    assert_receive {:dispatched, %{metadata: %{phone_call_result: id}} = notice}, @arrival_ms
    assert id == call.id
    {call.id, notice, printed}
  end

  defp leaks(named_texts) do
    for {where, text} <- named_texts,
        secret <- @secrets,
        String.contains?(text, secret),
        do: {where, secret}
  end

  test "neither the API key nor the trunk password reaches anything a finished call leaves",
       ctx do
    {{refused, unconfirmed, notices, printed}, log} =
      with_log(fn ->
        {refused, refused_notice} = refused_call!(ctx)
        {unconfirmed, unconfirmed_notice, printed} = unconfirmed_call!(ctx)
        :ok = await_handoffs(ctx)
        {refused, unconfirmed, [refused_notice, unconfirmed_notice], printed}
      end)

    {:ok, refused_row} = Ledger.get(refused, server: ctx.repo)
    {:ok, unconfirmed_row} = Ledger.get(unconfirmed, server: ctx.repo)

    # The vendor's words reached the record, so the checks below read real
    # failure text, scrubbed.
    assert refused_row.status == "failed"
    assert refused_row.vendor_message =~ "[REDACTED]"
    assert unconfirmed_row.status == "closure_unconfirmed"
    assert unconfirmed_row.failure_reason =~ "[REDACTED]"

    assert {:ok, %{"calls" => [%{} | _]}} =
             ManagementPhoneCalls.recovery(repo: ctx.repo, now: @t0, owner_id: "default")

    telemetry = telemetry_seen()

    assert Enum.any?(telemetry, fn {event, _meta} ->
             event == [:fermix, :phone_call, :run_error]
           end)

    texts =
      surfaces(ctx, [refused, unconfirmed]) ++
        Enum.map(notices, &{"notice #{&1.metadata.phone_call_result}", &1.content}) ++
        Enum.map(telemetry, fn {event, meta} -> {"telemetry #{inspect(event)}", meta} end) ++
        [{"captured log", log}, {"worker printed status", printed}]

    assert leaks(texts) == []
    refute_received {:manager_hangup, _session}
  end

  @tag sessions: ["live_u0_leak02", "live_u0_leak03"]
  test "no word the vendor says on the line carries either credential", ctx do
    {{failed, lost, notices, printed}, log} =
      with_log(fn ->
        {failed, failed_notice} = failed_on_the_line!(ctx, "live_u0_leak02")
        {lost, lost_notice, printed} = lost_on_the_line!(ctx, "live_u0_leak03")
        :ok = await_handoffs(ctx)
        {failed, lost, [failed_notice, lost_notice], printed}
      end)

    telemetry = telemetry_seen()

    texts =
      surfaces(ctx, [failed, lost]) ++
        Enum.map(notices, &{"notice #{&1.metadata.phone_call_result}", &1.content}) ++
        Enum.map(telemetry, fn {event, meta} -> {"telemetry #{inspect(event)}", meta} end) ++
        [{"captured log", log}, {"worker printed status", printed}]

    # Named by surface, so a leak says where it is: either secret, and the
    # basic-auth base64 and the masked key the vendor quoted.
    assert leaks(texts) == []

    assert for({where, text} <- texts, form <- [@basic, @masked], text =~ form, do: {where, form}) ==
             []

    # The vendor's words did reach the record and the log, so the checks above
    # read real vendor text, scrubbed; a failure that names the key, even
    # masked, is withheld in the engine's own words.
    {:ok, failed_row} = Ledger.get(failed, server: ctx.repo)
    {:ok, lost_row} = Ledger.get(lost, server: ctx.repo)
    assert failed_row.status == "failed"
    assert failed_row.vendor_message == "OpenAI did not accept the API key (sip_trunk_error)."
    assert failed_row.closure_reason =~ "[REDACTED]"
    assert lost_row.status == "closure_unconfirmed"
    assert lost_row.vendor_message =~ "[REDACTED]"
    assert log =~ "vendor.future.[REDACTED]"
    assert log =~ "dropped: Bearer [REDACTED]"
  end
end
