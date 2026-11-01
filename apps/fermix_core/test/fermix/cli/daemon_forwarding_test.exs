defmodule Fermix.CLI.DaemonForwardingTest do
  @moduledoc """
  The daemon's management dispatch after a move (M75 §6, B12): a device-role
  engine holding its desktop link answers device-class requests itself and
  sends every primary-class one to the primary, after its own owner
  placement; without the link nothing changes. On the primary,
  `serve_forwarded/3` answers a desktop's request as the socket would. A
  composed request (`home.status`, `settings.sections`) is answered on the
  device with the primary's own part, asked within 5 s, or the sentence that
  says why it is missing.

  The rail is stood in for by the daemon's `:forwarding` (its own tests run it
  for real).
  """

  use ExUnit.Case, async: true

  alias Fermix.CLI.Daemon
  alias Fermix.CLI.Daemon.Client
  alias FermixCore.Home.Provision.Hetzner
  alias FermixCore.Home.Provision.Ledger
  alias FermixTestSupport.ParentProcess
  alias FermixTestSupport.SafeRm

  @reply_ms 10_000
  @device %{role: :device, primary: "fermix-vm"}
  @this_machines_sections [
    %{id: "sandbox", pane: "safety", title: "Sandbox"},
    %{id: "computer_use", pane: "computer", title: "Computer use"},
    %{id: "routing", pane: "agent", title: "Routing"}
  ]

  defmodule PairProvider do
    @moduledoc false
    def pair_decide(session_id, approved, opts) do
      send(Keyword.fetch!(opts, :test), {:pair_decided, session_id, approved})
      {:error, :unknown_pairing_session}
    end
  end

  setup do
    tasks = start_supervised!({Task.Supervisor, []})
    %{tasks: tasks}
  end

  test "a linked device sends a primary-class request to the primary and answers what it said",
       ctx do
    socket = start_daemon!(ctx, engine_role: @device, desktop_link?: true)

    assert {:ok, %{"answered_by" => "primary"}} =
             Client.request_v1("settings.get", %{"section" => "providers.openai"},
               socket_path: socket,
               timeout: @reply_ms
             )

    assert_receive {:forwarded,
                    %{method: "settings.get", params: %{"section" => "providers.openai"}}, []}

    assert {:ok, %{"answered_by" => "primary"}} =
             Client.request_v1("providers.models.list", %{"provider" => "anthropic"},
               socket_path: socket,
               timeout: @reply_ms
             )

    assert_receive {:forwarded, %{method: "providers.models.list"}, []}
  end

  test "a linked device answers a device-class request itself, and forwards nothing", ctx do
    socket = start_daemon!(ctx, engine_role: @device, desktop_link?: true)

    assert {:ok, %{"engine" => "this machine", "section" => "sandbox"}} =
             Client.request_v1("settings.get", %{"section" => "sandbox"},
               socket_path: socket,
               timeout: @reply_ms
             )

    assert {:ok, %{"protocol" => _protocol}} =
             Client.request_v1("hello", %{}, socket_path: socket, timeout: @reply_ms)

    refute_received {:forwarded, _request, _opts}
  end

  test "an owner decision is forwarded only after this daemon placed its caller as the owner",
       ctx do
    socket = start_daemon!(ctx, engine_role: @device, desktop_link?: true)
    decide = %{"session_id" => "pair-1", "approved" => true}

    assert {:ok, %{"answered_by" => "primary"}} =
             Client.request_v1("mobile.pair.decide", decide,
               socket_path: socket,
               timeout: @reply_ms
             )

    assert_receive {:forwarded, %{method: "mobile.pair.decide"}, []}

    started_here =
      start_daemon!(ctx,
        engine_role: @device,
        desktop_link?: true,
        daemon_os_pid: ParentProcess.os_pid()
      )

    assert {:error, {:management_error, "unavailable", _message, %{"capability" => "mobile"}}} =
             Client.request_v1("mobile.pair.decide", decide,
               socket_path: started_here,
               timeout: @reply_ms
             )

    refute_received {:forwarded, _request, _opts}
  end

  test "without a desktop link a device refuses as it always did, and forwards nothing", ctx do
    socket = start_daemon!(ctx, engine_role: @device, desktop_link?: false)

    assert {:error,
            {:management_error, "unavailable", _message, %{"capability" => "providers"} = details}} =
             Client.request_v1(
               "providers.models.list",
               %{"provider" => "anthropic", "live" => true},
               socket_path: socket,
               timeout: @reply_ms
             )

    assert details["sentence"] == "This engine runs in the device role; the primary is fermix-vm."

    assert {:ok, %{"engine" => "this machine"}} =
             Client.request_v1("settings.get", %{"section" => "providers.openai"},
               socket_path: socket,
               timeout: @reply_ms
             )

    refute_received {:forwarded, _request, _opts}
  end

  test "the primary's refusal while unreachable reaches the app as it was said", ctx do
    unreachable =
      {:error, :primary_unreachable,
       %{
         "primary" => "fermix-vm",
         "sentence" =>
           "The server fermix-vm is unreachable. Fermix keeps your message until it is back."
       }}

    socket =
      start_daemon!(ctx,
        engine_role: @device,
        desktop_link?: true,
        forward: fn _r, _opts -> unreachable end
      )

    assert {:error,
            {:management_error, "primary_unreachable", "The primary engine cannot be reached.",
             details}} =
             Client.request_v1("cues.status", %{}, socket_path: socket, timeout: @reply_ms)

    assert details == elem(unreachable, 2)

    failing =
      start_daemon!(ctx,
        engine_role: @device,
        desktop_link?: true,
        forward: fn _request, _opts -> raise "the rail fell over" end
      )

    assert {:error, {:management_error, "internal_error", _message, %{}}} =
             Client.request_v1("cues.status", %{}, socket_path: failing, timeout: @reply_ms)
  end

  describe "composed requests on a linked device" do
    test "home.status answers this machine's facts and the primary's picture, asked within 5 s",
         ctx do
      socket = start_daemon!(ctx, engine_role: @device, desktop_link?: true)

      assert {:ok, status} =
               Client.request_v1("home.status", %{}, socket_path: socket, timeout: @reply_ms)

      assert status["role"] == "device"
      assert status["primary"]["name"] == "fermix-vm"
      assert status["primary_home"] == %{"role" => "primary", "epoch" => 7, "candidates" => []}
      assert status["primary_missing"] == nil
      # The desktop's own snapshot status is a retired copy: no target of its own.
      assert status["snapshots"]["targets"] == []
      assert_receive {:forwarded, %{method: "home.status", params: %{}}, [deadline_ms: 5_000]}
    end

    test "while the primary cannot answer, home.status says why its picture is missing", ctx do
      unreachable = fn _request, _opts ->
        {:error, :primary_unreachable,
         %{
           "primary" => "fermix-vm",
           "sentence" =>
             "The server fermix-vm is unreachable. Fermix keeps your message until it is back."
         }}
      end

      socket =
        start_daemon!(ctx, engine_role: @device, desktop_link?: true, forward: unreachable)

      assert {:ok, status} =
               Client.request_v1("home.status", %{}, socket_path: socket, timeout: @reply_ms)

      assert status["role"] == "device"
      assert status["primary_home"] == nil
      assert status["primary_missing"] =~ "The server fermix-vm is unreachable."

      assert {:ok, %{"sections" => sections, "primary_missing" => missing}} =
               Client.request_v1("settings.sections", %{},
                 socket_path: socket,
                 timeout: @reply_ms
               )

      assert Enum.map(sections, & &1["id"]) == ["sandbox", "computer_use"]
      assert missing =~ "The server fermix-vm is unreachable."
    end

    test "settings.sections lists this machine's own sections and the primary's others", ctx do
      socket = start_daemon!(ctx, engine_role: @device, desktop_link?: true)

      assert {:ok, %{"sections" => sections, "primary_missing" => nil}} =
               Client.request_v1("settings.sections", %{},
                 socket_path: socket,
                 timeout: @reply_ms
               )

      assert Enum.map(sections, & &1["id"]) == [
               "providers.openai",
               "routing",
               "sandbox",
               "computer_use"
             ]

      assert %{"title" => "Sandbox"} = Enum.find(sections, &(&1["id"] == "sandbox"))
      assert_receive {:forwarded, %{method: "settings.sections"}, [deadline_ms: 5_000]}
    end

    test "an engine with no link answers both on its own, missing nothing", ctx do
      socket = start_daemon!(ctx, engine_role: %{role: :primary, primary: nil})

      assert {:ok, %{"sections" => sections, "primary_missing" => nil}} =
               Client.request_v1("settings.sections", %{},
                 socket_path: socket,
                 timeout: @reply_ms
               )

      assert length(sections) == 3

      assert {:ok, %{"primary_home" => nil, "primary_missing" => nil}} =
               Client.request_v1("home.status", %{}, socket_path: socket, timeout: @reply_ms)

      refute_received {:forwarded, _request, _opts}
    end

    test "the home's recovery and the servers it holds are the primary's", ctx do
      socket = start_daemon!(ctx, engine_role: @device, desktop_link?: true)

      for {method, params} <- [{"home.snapshots.status", %{}}, {"home.candidates.list", %{}}] do
        assert {:ok, %{"answered_by" => "primary"}} =
                 Client.request_v1(method, params, socket_path: socket, timeout: @reply_ms)

        assert_receive {:forwarded, %{method: ^method}, []}
      end
    end

    # Always On setup §3.5, §7: the server's Always On steps reach it only from
    # this desktop's own `home.act`, which records a replace's move itself, so
    # one sent on this socket is refused here by name and never forwarded, and
    # the ledger keeps nothing of it.
    test "a server step sent on the socket is refused by name and never forwarded", ctx do
      {socket, root} = start_daemon!(ctx, [engine_role: @device, desktop_link?: true], :both)
      waiting_replace!(root)
      start = %{"candidate_id" => "cand-new", "recovery_passphrase" => "invented-lantern-orchard"}

      for {method, params} <- [
            {"home.move.start", start},
            {"home.move.readiness", %{"candidate_id" => "cand-new"}},
            {"home.enroll.open", %{}},
            {"home.enroll.withdraw", %{}},
            {"home.snapshots.run", %{}}
          ] do
        assert {:error,
                {:management_error, "unavailable", _message,
                 %{"capability" => "home", "method" => ^method}}} =
                 Client.request_v1(method, params, socket_path: socket, timeout: @reply_ms)
      end

      refute_received {:forwarded, _request, _opts}
      assert {:ok, %{replace: %{move_started_at: nil}}} = Ledger.read(root, "hetzner")
      assert %{replace: %{state: :waiting}} = Ledger.state(root, Hetzner)
    end
  end

  describe "serve_forwarded/3, on the primary" do
    test "answers a composed request a desktop forwarded as its own", ctx do
      daemon = start_daemon!(ctx, [engine_role: %{role: :primary, primary: nil}], :name)

      assert %{"request_id" => "call-5", "result" => %{"role" => "primary"}} =
               Daemon.serve_forwarded(frame("call-5", "home.status", %{}), "desk-1", daemon)

      assert %{"result" => %{"sections" => [_one, _two, _three], "primary_missing" => nil}} =
               Daemon.serve_forwarded(frame("call-6", "settings.sections", %{}), "desk-1", daemon)
    end

    test "answers a desktop's request as the socket would", ctx do
      daemon = start_daemon!(ctx, [engine_role: %{role: :primary, primary: nil}], :name)

      assert %{"request_id" => "call-1", "result" => %{"engine" => "this machine"}} =
               Daemon.serve_forwarded(
                 frame("call-1", "settings.get", %{"section" => "routing"}),
                 "desk-1",
                 daemon
               )
    end

    test "serves the owner's decision a desktop forwarded, whoever runs the call here", ctx do
      daemon =
        start_daemon!(
          ctx,
          [engine_role: %{role: :primary, primary: nil}, daemon_os_pid: ParentProcess.os_pid()],
          :name
        )

      decide =
        frame("call-2", "mobile.pair.decide", %{"session_id" => "pair-9", "approved" => false})

      assert %{"request_id" => "call-2", "error" => %{"code" => "unknown_pairing_session"}} =
               Daemon.serve_forwarded(decide, "desk-1", daemon)

      assert_receive {:pair_decided, "pair-9", false}
    end

    test "serves a server step a desktop's Always On sent, and refuses home.act itself", ctx do
      daemon = start_daemon!(ctx, [engine_role: %{role: :primary, primary: nil}], :name)

      assert %{
               "request_id" => "call-7",
               "error" => %{"code" => "unavailable", "details" => %{"capability" => "snapshots"}}
             } =
               Daemon.serve_forwarded(
                 frame("call-7", "home.snapshots.run", %{}),
                 "desk-1",
                 daemon
               )

      assert %{
               "error" => %{
                 "code" => "device_class_method",
                 "details" => %{"method" => "home.act"}
               }
             } =
               Daemon.serve_forwarded(
                 frame("call-8", "home.act", %{"action" => "cancel", "key" => "k"}),
                 "desk-1",
                 daemon
               )
    end

    test "refuses a device-class request by name, and a frame that is no request", ctx do
      daemon = start_daemon!(ctx, [engine_role: %{role: :primary, primary: nil}], :name)

      assert %{
               "request_id" => "call-3",
               "error" => %{
                 "code" => "device_class_method",
                 "message" => "This method belongs to the device that sent it.",
                 "details" => %{"method" => "settings.get", "sentence" => _sentence}
               }
             } =
               Daemon.serve_forwarded(
                 frame("call-3", "settings.get", %{"section" => "sandbox"}),
                 "desk-1",
                 daemon
               )

      assert %{"error" => %{"code" => "invalid_request"}} =
               Daemon.serve_forwarded("not json", "desk-1", daemon)
    end
  end

  defp frame(id, method, params),
    do:
      Jason.encode!(%{
        "request_id" => id,
        "protocol_version" => 2,
        "method" => method,
        "params" => params
      })

  defp start_daemon!(ctx, opts, answer \\ :socket) do
    test = self()
    root = Path.join(System.tmp_dir!(), "fx-df-#{System.unique_integer([:positive])}")
    SafeRm.mark!(root)
    on_exit(fn -> SafeRm.rm_rf!(root) end)
    socket_path = Path.join(root, "d.sock")
    name = :"daemon_forwarding_#{System.unique_integer([:positive])}"
    {role, opts} = Keyword.pop!(opts, :engine_role)
    {linked?, opts} = Keyword.pop(opts, :desktop_link?, false)

    recorded = fn request, forward_opts ->
      send(test, {:forwarded, request, forward_opts})
      primary_answer(request)
    end

    {forward, opts} = Keyword.pop(opts, :forward, recorded)
    # As `Home.Link.forwarding/0` answers it for a linked desktop, or any other engine.
    forwarding = if linked?, do: [primary_forward: forward], else: []

    start_supervised!(
      {Daemon,
       [
         name: name,
         socket_path: socket_path,
         task_supervisor: ctx.tasks,
         forwarding: forwarding,
         management_opts: [
           engine_role: role,
           settings_reader: fn section, _opts ->
             {:ok, %{"section" => section, "engine" => "this machine"}}
           end,
           identity_provider: fn -> {:ok, identity()} end,
           settings_sections: fn -> @this_machines_sections end,
           endpoint_opts: [port: 4041],
           operation_opts: [
             mobile: [provider: PairProvider, test: test],
             home: [home: root, scheduler: nil, link_status: &link_status/0],
             provision: [home: root]
           ]
         ]
       ]
       |> Keyword.merge(opts)},
      id: name
    )

    case answer do
      :name -> name
      :socket -> socket_path
      :both -> {socket_path, root}
    end
  end

  # A replace whose new server stands and waits for its move, as the
  # provisioner left it in this computer's ledger.
  defp waiting_replace!(root) do
    now = ~U[2031-05-04 10:00:00Z]
    server = %{name: "fermix-general-a3f9", type: "cpx22", location: "fsn1", id: "7"}

    {:ok, _ledger} =
      Ledger.update(root, "hetzner", fn ledger ->
        ledger
        |> Ledger.connect("invented-hetzner-token-6d1f0c9a2b7e4f3a", now)
        |> Ledger.begin_create("a3f9", server)
        |> Ledger.put_server(Map.put(server, :status, :created))
        |> Ledger.begin_replace(5, now)
      end)

    new = %{name: "fermix-general-b7c2", type: "cpx32", location: "hel1", id: "8"}

    {:ok, _ledger} =
      Ledger.update(root, "hetzner", fn ledger ->
        {:ok,
         ledger
         |> Ledger.begin_create("b7c2", new)
         |> Ledger.put_server(Map.put(new, :status, :created))}
      end)
  end

  # What the primary answers each forwarded request: its own home picture and
  # sections for the composed ones, a mark of having answered for the rest.
  defp primary_answer(%{method: "home.status"}),
    do: {:ok, %{"role" => "primary", "epoch" => 7, "candidates" => []}}

  defp primary_answer(%{method: "settings.sections"}) do
    {:ok,
     %{
       "sections" => [
         %{"id" => "providers.openai", "pane" => "providers", "title" => "OpenAI"},
         %{"id" => "sandbox", "pane" => "safety", "title" => "The server's sandbox"},
         %{"id" => "routing", "pane" => "agent", "title" => "Routing"}
       ]
     }}
  end

  defp primary_answer(_request), do: {:ok, %{"answered_by" => "primary"}}

  defp link_status do
    %{
      primary: %{
        name: "fermix-vm",
        connected: true,
        status: :connected,
        sentence: "Fermix is connected."
      },
      desktops: [],
      enrollment: nil
    }
  end

  defp identity do
    %{
      "engine_id" => "fermix-engine-test",
      "product_version" => "1.2.3",
      "build_id" => nil,
      "source_commit" => nil,
      "distribution_identity" => "standalone",
      "artifact_target" => nil,
      "architecture" => "arm64",
      "pid" => "4321"
    }
  end
end
