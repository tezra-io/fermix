defmodule FermixCore.PhoneCalls.CallTransportTest do
  @moduledoc """
  The real worker over the real wire: `PhoneCalls.Call` with the production
  `PhoneCalls.CallTransport`, `OpenAILive` and `OpenAILive.Sideband`, against
  one local stand-in of the vendor (Bandit, loopback only) that answers the
  create and the hangup and holds the sideband WebSocket. Only the backend
  turn, the outcome reader and the clocks are fakes, so a mismatch between
  the worker and what the transport sends or reads fails here.

  async: false: the fakes report to a registered sink, and the Manager's
  cleanup case establishes and restores the provider keys' app env. Every
  key, number and id is invented.
  """

  use ExUnit.Case, async: false

  alias FermixCore.Memory.Repo
  alias FermixCore.Net.Egress
  alias FermixCore.PhoneCalls.Brief
  alias FermixCore.PhoneCalls.Call
  alias FermixCore.PhoneCalls.CallControls
  alias FermixCore.PhoneCalls.CallTransport
  alias FermixCore.PhoneCalls.Ledger
  alias FermixTestSupport.PhoneCallFakes, as: Fakes

  @arrival_ms 10_000
  @t0 ~U[2031-03-04 15:00:00.000000Z]
  @session "live_u0_e2e01"

  defmodule Vendor do
    @moduledoc false
    @behaviour Plug

    import Plug.Conn

    @impl true
    def init(opts), do: opts

    @impl true
    def call(%{method: "POST", request_path: "/v1/live/sessions"} = conn, %{test: test}) do
      {:ok, raw, conn} = read_body(conn)
      send(test, {:vendor_create, conn.req_headers, Jason.decode!(raw)})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(201, ~s({"session":{"id":"live_u0_e2e01"},"transport":{"type":"sip"}}))
    end

    def call(%{method: "POST", request_path: "/v1/live/sessions/live_u0_e2e01/hangup"} = conn, %{
          test: test
        }) do
      send(test, {:vendor_hangup, conn.req_headers})
      send_resp(conn, 200, "")
    end

    def call(%{request_path: "/v1/live/sessions/live_u0_e2e01/attach"} = conn, %{test: test}),
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
    def handle_in({text, opcode: :text}, state) do
      send(state.test, {:vendor_got, Jason.decode!(text)})
      {:ok, state}
    end

    @impl true
    def handle_info({:push, frames}, state), do: {:push, Enum.map(frames, &{:text, &1}), state}

    @impl true
    def terminate(_reason, state) do
      send(state.test, :vendor_socket_closed)
      :ok
    end
  end

  setup do
    Process.flag(:trap_exit, true)
    Fakes.register_sink!()
    start_supervised!(Fakes.script_spec())
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-phone-wire-#{unique}.db")
    repo = :"phone_wire_repo_#{unique}"
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path}, id: repo)
    registry = :"phone_wire_registry_#{unique}"
    start_supervised!({Registry, keys: :unique, name: registry})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    server =
      start_supervised!(
        {Bandit,
         plug: {Vendor, %{test: self()}}, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
        id: make_ref()
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    origins = [
      base_url: "http://127.0.0.1:#{port}",
      ws_base_url: "ws://127.0.0.1:#{port}",
      egress: Egress.new([])
    ]

    %{repo: repo, registry: registry, origins: origins, clock: :atomics.new(1, [])}
  end

  defp start!(ctx) do
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

    attrs = %{
      request_id: "main-wire-#{System.unique_integer([:positive])}",
      owner_id: "default",
      authorization: "direct",
      origin_kind: "chat",
      delivery_mode: "origin",
      platform: "telegram",
      destination: "40017",
      mandate: Brief.to_map(brief),
      mandate_hash: Brief.hash(brief),
      model: "gpt-live-1",
      voice: "cedar",
      prompt_version: "phone-test-1",
      carrier_profile: "telnyx_credential_v1"
    }

    {:ok, {:admitted, row}} = Ledger.admit(attrs, @t0, server: ctx.repo)

    seams =
      ctx.clock
      |> Fakes.seams()
      |> Map.drop([:transport, :ledger])
      |> Map.put(:transport_opts, ctx.origins)

    args =
      Map.merge(seams, %{
        call_id: row.id,
        row: row,
        brief: brief,
        manager: self(),
        repo: ctx.repo,
        now_fn: fn -> @t0 end,
        session_id: "phone_call_" <> row.id,
        parent_session: row.request_id,
        registry: ctx.registry
      })

    {:ok, pid} = Call.start_link(args)
    %{pid: pid, id: row.id}
  end

  defp push(socket, events), do: send(socket, {:push, Enum.map(events, &Jason.encode!/1)})

  defp got!(type) do
    assert_receive {:vendor_got, %{"type" => ^type} = frame}, @arrival_ms
    frame
  end

  defp fire!(call, kind) do
    _state = :sys.get_state(call.pid)
    assert_receive {:scheduled, {:phone_call_timer, ^kind, _token} = message, _ms}, @arrival_ms
    send(call.pid, message)
  end

  test "one whole call: create, attach, answer, words, a turn, a key, the hangup, the end",
       ctx do
    call = start!(ctx)

    # The one create, as the vendor reads it.
    assert_receive {:vendor_create, headers, body}, @arrival_ms
    assert {"authorization", "Bearer sk-invented-phone-key"} in headers
    assert body["session"]["model"] == "gpt-live-1"
    assert body["session"]["audio"]["output"]["voice"] == "cedar"
    assert body["session"]["delegation"] == %{"type" => "client"}
    assert body["transport"]["destination"] == "+12125550101"
    assert body["transport"]["trunk"]["provider_url"] == "sips:sip.telnyx.com:5061"
    assert body["transport"]["trunk"]["caller_number"] == Fakes.caller()

    # The attach, and the call answered: nobody speaks within the opening's
    # wait, so the opening goes once, to the call.
    assert_receive {:vendor_socket, socket}, @arrival_ms

    push(socket, [%{"type" => "transport.answered", "event_id" => "s1", "session_id" => @session}])

    fire!(call, :opening)

    opening = got!("session.commentary.append")
    assert opening["delegation_id"] == nil

    push(socket, [
      %{
        "type" => "session.input_transcript.delta",
        "event_id" => "s2",
        "delta" => "We have a table at seven.",
        "start_ms" => 1_200,
        "end_ms" => 2_400
      },
      %{
        "type" => "session.delegation.created",
        "event_id" => "s3",
        "offset_ms" => 2_500,
        "delegation" => %{"id" => "dlg_e2e_1", "target" => "client"}
      }
    ])

    fire!(call, {:settle, "dlg_e2e_1"})
    assert_receive {:delegate_run, request}, @arrival_ms
    assert [%{speaker: :remote, text: "We have a table at seven."}] = request.window

    # A key from the turn, acknowledged by the vendor.
    press =
      Task.async(fn ->
        CallControls.press_keys(call.id, request.handle, "1", registry: ctx.registry)
      end)

    dtmf = got!("transport.dtmf.send")
    assert dtmf["event"] == "1"

    push(socket, [
      %{
        "type" => "transport.dtmf.sent",
        "event_id" => "s4",
        "event" => "1",
        "client_event_id" => dtmf["event_id"]
      }
    ])

    assert {:ok, %{confirmed: "1", unconfirmed: "", stopped: nil}} = Task.await(press)

    # The turn finishes the call: the ending begins at once, the turn is
    # retired (never stopped: it is inside its own end call), and a reply it
    # still sends never reaches the voice.
    assert :ok = CallControls.finish(call.id, request.handle, :done, nil, registry: ctx.registry)

    send(
      call.pid,
      {:phone_call_delegation, call.id, "dlg_e2e_1",
       {:ok, %{reply: "The recipient said yes.", backend_usage: %{"total_tokens" => 640}}}}
    )

    # The voice's own goodbye goes quiet; then one hangup, and the vendor's
    # close. The clock moves only once the worker has taken the answer in.
    Fakes.advance_clock!(ctx.clock, call.pid, 60_000)
    fire!(call, :speech)
    assert_receive {:vendor_hangup, hangup_headers}, @arrival_ms
    assert {"authorization", "Bearer sk-invented-phone-key"} in hangup_headers

    push(socket, [
      %{
        "type" => "session.closed",
        "event_id" => "s5",
        "reason" => "close_requested",
        "usage" => %{"seconds" => 61}
      }
    ])

    pid = call.pid
    assert_receive {:phone_call_ended, id, report}, @arrival_ms
    assert id == call.id
    assert_receive {:EXIT, ^pid, :normal}, @arrival_ms
    assert_receive :vendor_socket_closed, @arrival_ms

    assert report.status == "ended"
    assert report.voice_seconds == 61
    assert report.usage_state == "voice_duration_confirmed"
    # The cut turn ran and never answered: one turn, its usage unknown.
    assert report.backend_usage == %{"turns" => 1, "turns_unmeasured" => 1}
    refute_received {:vendor_got, %{"type" => "session.commentary.append"}}
    refute_received {:delegate_cancel, _call_id, _id}
    refute_received {:vendor_create, _headers, _body}
    refute_received {:vendor_hangup, _headers}

    {:ok, row} = Ledger.get(call.id, server: ctx.repo)
    assert row.provider_session_id == @session
    assert row.closure_reason == "close_requested"
    assert row.dtmf_keys == 1
  end

  describe "the Manager's cleanup (manager_hangup)" do
    setup do
      saved = Application.fetch_env(:fermix_core, :providers)

      on_exit(fn ->
        case saved do
          {:ok, value} -> Application.put_env(:fermix_core, :providers, value)
          :error -> Application.delete_env(:fermix_core, :providers)
        end
      end)

      :ok
    end

    test "hangs up a known session once, with the key resolved as it runs", ctx do
      Application.put_env(:fermix_core, :providers, openai: [api_key: "sk-invented-cleanup"])

      assert :ok = CallTransport.manager_hangup(@session, ctx.origins)
      assert_receive {:vendor_hangup, headers}, @arrival_ms
      assert {"authorization", "Bearer sk-invented-cleanup"} in headers
      refute_received {:vendor_hangup, _headers}
    end

    # Never sent, so the Manager may send it again (bounded, counted): a boot
    # before the key resolves must not leave a call up.
    test "with no OpenAI key it sends nothing, and says it provably never left", ctx do
      Application.put_env(:fermix_core, :providers, [])

      assert {:error, {:not_sent, :openai_api_key_missing}} =
               CallTransport.manager_hangup(@session, ctx.origins)

      refute_received {:vendor_hangup, _headers}
    end

    test "a stored key no request could carry is never sent either", ctx do
      Application.put_env(:fermix_core, :providers,
        openai: [api_key: "sk-invented\nX-Injected: 1"]
      )

      assert {:error, {:not_sent, {:invalid, :api_key}}} =
               CallTransport.manager_hangup(@session, ctx.origins)

      refute_received {:vendor_hangup, _headers}
    end

    test "over a refused transport it sends nothing and reads no key", ctx do
      # No usable key is stored, so a key read first would answer
      # `{:not_sent, :openai_api_key_missing}` instead.
      Application.put_env(:fermix_core, :providers, openai: [api_key: :not_a_key])

      assert {:error, {:not_sent, :test_build}} =
               CallTransport.manager_hangup(@session, ctx.origins ++ [refused: :test_build])

      refute_received {:vendor_hangup, _headers}
    end
  end
end
