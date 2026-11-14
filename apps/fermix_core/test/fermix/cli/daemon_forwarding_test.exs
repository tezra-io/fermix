defmodule Fermix.CLI.DaemonForwardingTest do
  @moduledoc """
  The daemon's management dispatch after a move (M75 §6, B12): a device-role
  engine holding its desktop link answers device-class requests itself and
  sends every primary-class one to the primary, after its own owner
  placement; without the link nothing changes. On the primary,
  `serve_forwarded/3` answers a desktop's request as the socket would. A
  composed request (`home.status`, `settings.sections`, `job.list`) is
  answered on the device with the primary's own part, asked within 5 s, or
  the sentence that says why it is missing.

  The rail is stood in for by the daemon's `:forwarding` (its own tests run it
  for real).
  """

  use ExUnit.Case, async: true

  alias Fermix.CLI.Daemon
  alias Fermix.CLI.Daemon.Client
  alias FermixCore.Management.Doctor
  alias FermixCore.Management.Doctor.Descriptor
  alias FermixCore.Management.HomeSummary
  alias FermixCore.Management.Jobs
  alias FermixTestSupport.ParentProcess
  alias FermixTestSupport.SafeRm

  @reply_ms 10_000
  # The computer that forwards, its hello saying it applies M97 §19.3's rule.
  @desk %{device_id: "desk-1", machine_settings: true}
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

    assert {:ok, %{"engine" => "this machine", "section" => "computer"}} =
             Client.request_v1("settings.get", %{"section" => "computer"},
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

  # A device with no link (the server revoked it)
  # opens no database, and every cue method reads or writes the cue rows in
  # memory.db: each is refused by name, as a linked desktop's is while its
  # server is out of reach, before anything is read. Read from the protocol's
  # own method list, so a cue method added later is refused too. The host's
  # own platform places the caller (an owner decision among the cue methods is
  # placed before it is refused), so the sentence names this host's machine.
  test "without a desktop link a device refuses every cue method as retired", ctx do
    socket = start_daemon!(ctx, engine_role: @device, desktop_link?: false)
    machine = if :os.type() == {:unix, :darwin}, do: "this Mac", else: "this computer"
    cue_methods = Enum.filter(FermixCore.Management.Protocol.methods(), &(&1 =~ ~r/^cues\./))

    assert length(cue_methods) > 20

    for method <- cue_methods do
      assert {:error, {:management_error, "primary_unreachable", _message, details}} =
               Client.request_v1(method, %{}, socket_path: socket, timeout: @reply_ms),
             method

      assert details["sentence"] ==
               "Fermix moved to your server, and #{machine} is no longer connected to it.",
             method
    end

    assert {:ok, %{"engine" => "this machine"}} =
             Client.request_v1("settings.get", %{"section" => "sandbox"},
               socket_path: socket,
               timeout: @reply_ms
             )

    refute_received {:forwarded, _request, _opts}
  end

  test "on a Mac the retired sentence names the Mac", ctx do
    socket = start_daemon!(ctx, engine_role: @device, desktop_link?: false, os: {:unix, :darwin})

    assert {:error, {:management_error, "primary_unreachable", _message, details}} =
             Client.request_v1("cues.status", %{}, socket_path: socket, timeout: @reply_ms)

    assert details["sentence"] ==
             "Fermix moved to your server, and this Mac is no longer connected to it."
  end

  test "on a computer that is no Mac the retired sentence names the computer", ctx do
    socket = start_daemon!(ctx, engine_role: @device, desktop_link?: false, os: {:unix, :linux})

    assert {:error, {:management_error, "primary_unreachable", _message, details}} =
             Client.request_v1("cues.status", %{}, socket_path: socket, timeout: @reply_ms)

    assert details["sentence"] ==
             "Fermix moved to your server, and this computer is no longer connected to it."
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

  # M97 §19.6 (D28c): setup.state.get and overview.get are the server's, so
  # the restart they report is the server's, and a linked computer adds the
  # step that restarts it, the record its summary offers: the app presses
  # that one step from every pane, never this computer's own restart.
  test "the server's restart state carries the step that restarts the server", ctx do
    socket = start_daemon!(ctx, engine_role: @device, desktop_link?: true)
    step = HomeSummary.restart_server_action("fermix-vm")

    assert %{"id" => "restart_server", "label" => "Restart fermix-vm"} = step

    assert {:ok, %{"restart" => %{"required" => true}, "restart_step" => ^step}} =
             Client.request_v1("setup.state.get", %{}, socket_path: socket, timeout: @reply_ms)

    assert {:ok, %{"health" => %{"restart_required" => true, "restart_step" => ^step}}} =
             Client.request_v1("overview.get", %{}, socket_path: socket, timeout: @reply_ms)

    assert_receive {:forwarded, %{method: "setup.state.get"}, []}
    assert_receive {:forwarded, %{method: "overview.get"}, []}

    # A forwarded machine section is titled with the server's name.
    assert {:ok, %{"title" => "Sandbox on fermix-vm"}} =
             Client.request_v1("settings.get", %{"section" => "sandbox"},
               socket_path: socket,
               timeout: @reply_ms
             )

    settled =
      start_daemon!(ctx,
        engine_role: @device,
        desktop_link?: true,
        forward: fn _request, _opts ->
          {:ok, %{"restart" => %{"required" => false, "reasons" => []}}}
        end
      )

    assert {:ok, %{"restart_step" => nil}} =
             Client.request_v1("setup.state.get", %{}, socket_path: settled, timeout: @reply_ms)

    unlinked =
      start_daemon!(ctx,
        engine_role: %{role: :primary, primary: nil},
        management: [
          setup_state_reporter: fn _opts ->
            %{"restart" => %{"required" => true, "reasons" => []}}
          end
        ]
      )

    assert {:ok, answer} =
             Client.request_v1("setup.state.get", %{}, socket_path: unlinked, timeout: @reply_ms)

    refute Map.has_key?(answer, "restart_step")
  end

  # Doctor's `server link` row: the link as this computer's own engine holds
  # it, its path included, read with no round trip to the server.
  test "the link Doctor reads is this machine's own, and asks the server nothing", ctx do
    socket = start_daemon!(ctx, engine_role: @device, desktop_link?: true)

    assert {:ok, %{"status" => "ok", "result" => %{"primary" => primary}}} =
             Client.request("home_link", socket_path: socket, timeout: @reply_ms)

    assert primary["name"] == "fermix-vm"
    assert primary["connected"] == true
    assert primary["path"] == "direct"
    refute_received {:forwarded, _request, _opts}
  end

  # EC2 test 2026-11-08: Doctor diagnoses this machine, so a device answers
  # the Doctor pane's own calls itself, linked or not, and forwards none:
  # `doctor.start` with the local scope named, as the Mac app sends it, or
  # left to its default, which is the same run and was refused, then
  # `doctor.get` and `doctor.cancel` of that session. The network scope
  # probes a provider with this machine's retired credentials, so it stays
  # refused by name (M75 D5).
  test "a device runs Doctor's local checks itself, through the pane's own calls", ctx do
    doctor = start_doctor!(ctx)

    for linked? <- [true, false], params <- [%{"scope" => "local"}, %{}] do
      socket =
        start_daemon!(ctx,
          engine_role: @device,
          desktop_link?: linked?,
          management: [doctor_server: doctor, descriptors: [server_link_row()]]
        )

      # The case rides beside the answer, so a failure names it.
      assert {^linked?, ^params, {:ok, %{"session_id" => id, "scope" => "local", "total" => 1}}} =
               {linked?, params,
                Client.request_v1("doctor.start", params, socket_path: socket, timeout: @reply_ms)}

      assert {:ok, %{"session_id" => ^id}} =
               Client.request_v1("doctor.get", %{"session_id" => id},
                 socket_path: socket,
                 timeout: @reply_ms
               )

      assert {:ok, %{"session_id" => ^id, "status" => status}} =
               Client.request_v1("doctor.cancel", %{"session_id" => id},
                 socket_path: socket,
                 timeout: @reply_ms
               )

      assert status in ~w(completed cancelled)

      assert {:error, {:management_error, "unavailable", _message, details}} =
               Client.request_v1("doctor.start", %{"scope" => "network"},
                 socket_path: socket,
                 timeout: @reply_ms
               )

      assert details == %{
               "capability" => "doctor",
               "sentence" => "This engine runs in the device role; the primary is fermix-vm."
             }
    end

    refute_received {:forwarded, _request, _opts}
  end

  # What the pane draws on a device: the local catalog holds the rows that
  # read the device role (`acp`) and the link to the server (`server_link`).
  test "the local catalog a device runs holds the rows that read its role and its link" do
    ids = Enum.map(Descriptor.catalog(:local), & &1.id)
    assert "acp" in ids
    assert "server_link" in ids
  end

  test "an engine with no link answers no primary", ctx do
    socket = start_daemon!(ctx, engine_role: :primary, link_status: &unlinked/0)

    assert {:ok, %{"status" => "ok", "result" => %{"primary" => nil}}} =
             Client.request("home_link", socket_path: socket, timeout: @reply_ms)
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
        start_daemon!(ctx,
          engine_role: @device,
          desktop_link?: true,
          forward: unreachable,
          management: [computer?: true, macos?: true]
        )

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

      assert Enum.map(sections, & &1["id"]) == ["computer.sandbox", "computer.computer_use"]
      assert missing =~ "The server fermix-vm is unreachable."
    end

    # M97 D28: the jobs this computer started itself are still listed while
    # the server's cannot be asked for, and the sentence says why.
    test "while the primary cannot answer, job.list lists this computer's own jobs", ctx do
      unreachable = fn _request, _opts ->
        {:error, :primary_unreachable,
         %{
           "primary" => "fermix-vm",
           "sentence" =>
             "The server fermix-vm is unreachable. Fermix keeps your message until it is back."
         }}
      end

      jobs = start_jobs!(ctx, computer?: true)
      {:ok, %{"job_id" => "computer.job:" <> _rest = mine}} = blocked_job(jobs)

      socket =
        start_daemon!(ctx,
          engine_role: @device,
          desktop_link?: true,
          forward: unreachable,
          jobs: jobs
        )

      assert {:ok, %{"jobs" => [%{"job_id" => ^mine}], "primary_missing" => missing}} =
               Client.request_v1("job.list", %{}, socket_path: socket, timeout: @reply_ms)

      assert missing =~ "The server fermix-vm is unreachable."
    end

    # M97 §19: the server's sections, its machine sections only where its
    # hello_ack says it applies the rule (this link says nothing, so its
    # sandbox is left out), then this computer's own as computer.<id>.
    test "settings.sections lists the primary's sections, then this machine's own", ctx do
      socket =
        start_daemon!(ctx,
          engine_role: @device,
          desktop_link?: true,
          management: [computer?: true, macos?: true]
        )

      assert {:ok, %{"sections" => sections, "primary_missing" => nil}} =
               Client.request_v1("settings.sections", %{},
                 socket_path: socket,
                 timeout: @reply_ms
               )

      assert Enum.map(sections, & &1["id"]) == [
               "providers.openai",
               "routing",
               "computer.sandbox",
               "computer.computer_use"
             ]

      assert %{"title" => "Sandbox on this Mac", "pane" => "always_on"} =
               Enum.find(sections, &(&1["id"] == "computer.sandbox"))

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
    # this desktop's own `home.act`, which records a move back's start itself,
    # so one sent on this socket is refused here by name and never forwarded.
    test "a server step sent on the socket is refused by name and never forwarded", ctx do
      socket = start_daemon!(ctx, engine_role: @device, desktop_link?: true)
      start = %{"candidate_id" => "cand-new", "recovery_passphrase" => "invented-lantern-orchard"}

      for {method, params} <- [
            {"home.move.start", start},
            {"home.move.readiness", %{"candidate_id" => "cand-new"}},
            {"home.enroll.open", %{}},
            {"home.enroll.withdraw", %{}},
            {"home.snapshots.run", %{}},
            {"home.restart", %{}}
          ] do
        assert {:error,
                {:management_error, "unavailable", _message,
                 %{"capability" => "home", "method" => ^method}}} =
                 Client.request_v1(method, params, socket_path: socket, timeout: @reply_ms)
      end

      refute_received {:forwarded, _request, _opts}
    end
  end

  describe "serve_forwarded/3, on the primary" do
    test "answers a composed request a desktop forwarded as its own", ctx do
      daemon = start_daemon!(ctx, [engine_role: %{role: :primary, primary: nil}], :name)

      assert %{"request_id" => "call-5", "result" => %{"role" => "primary"}} =
               Daemon.serve_forwarded(frame("call-5", "home.status", %{}), @desk, daemon)

      assert %{"result" => %{"sections" => [_one, _two, _three], "primary_missing" => nil}} =
               Daemon.serve_forwarded(frame("call-6", "settings.sections", %{}), @desk, daemon)
    end

    test "answers a forwarded job.list with its own jobs, missing nothing", ctx do
      jobs = start_jobs!(ctx, computer?: false)
      {:ok, %{"job_id" => "job:" <> _rest = theirs}} = blocked_job(jobs)

      daemon =
        start_daemon!(ctx, [engine_role: %{role: :primary, primary: nil}, jobs: jobs], :name)

      assert %{"result" => %{"jobs" => [%{"job_id" => ^theirs}], "primary_missing" => nil}} =
               Daemon.serve_forwarded(frame("call-7", "job.list", %{}), @desk, daemon)
    end

    test "answers a desktop's request as the socket would", ctx do
      daemon = start_daemon!(ctx, [engine_role: %{role: :primary, primary: nil}], :name)

      assert %{"request_id" => "call-1", "result" => %{"engine" => "this machine"}} =
               Daemon.serve_forwarded(
                 frame("call-1", "settings.get", %{"section" => "routing"}),
                 @desk,
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
               Daemon.serve_forwarded(decide, @desk, daemon)

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
                 @desk,
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
                 @desk,
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
                 frame("call-3", "settings.get", %{"section" => "computer.sandbox"}),
                 @desk,
                 daemon
               )

      assert %{"error" => %{"code" => "invalid_request"}} =
               Daemon.serve_forwarded("not json", @desk, daemon)
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
    {link, opts} = Keyword.pop(opts, :link_status, &link_status/0)
    {management, opts} = Keyword.pop(opts, :management, [])
    {jobs, opts} = Keyword.pop(opts, :jobs)
    # As `Home.Link.forwarding/0` answers it for a linked desktop, or any other engine.
    forwarding = if linked?, do: [primary_forward: forward], else: []

    start_supervised!(
      {Daemon,
       [
         name: name,
         socket_path: socket_path,
         task_supervisor: ctx.tasks,
         forwarding: forwarding,
         management_opts:
           [
             engine_role: role,
             settings_reader: fn section, _opts ->
               {:ok, %{"section" => section, "engine" => "this machine"}}
             end,
             identity_provider: fn -> {:ok, identity()} end,
             settings_sections: fn -> @this_machines_sections end,
             endpoint_opts: [port: 4041],
             operation_opts:
               [
                 mobile: [provider: PairProvider, test: test],
                 home: [home: root, scheduler: nil, link_status: link]
               ] ++ if(jobs, do: [jobs: [server: jobs]], else: [])
           ] ++ management
       ]
       |> Keyword.merge(opts)},
      id: name
    )

    case answer do
      :name -> name
      :socket -> socket_path
    end
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

  defp primary_answer(%{method: "setup.state.get"}),
    do: {:ok, %{"restart" => %{"required" => true, "reasons" => []}, "answered_by" => "primary"}}

  defp primary_answer(%{method: "overview.get"}),
    do: {:ok, %{"health" => %{"restart_required" => true}, "answered_by" => "primary"}}

  defp primary_answer(%{method: "settings.get", params: %{"section" => "sandbox"}}),
    do: {:ok, %{"id" => "sandbox", "title" => "Sandbox", "rows" => []}}

  defp primary_answer(_request), do: {:ok, %{"answered_by" => "primary"}}

  # A job family of the test's own, a linked computer's (`computer?: true`)
  # minting ids that name it, so no job of the application's is touched.
  defp start_jobs!(ctx, opts) do
    name = :"daemon_forwarding_jobs_#{System.unique_integer([:positive])}"
    start_supervised!({Jobs, [name: name, task_supervisor: ctx.tasks] ++ opts}, id: name)
  end

  # A browser download that runs until the test ends.
  defp blocked_job(jobs) do
    run = fn _job_id, _report ->
      receive do
        :never_sent -> {:ok, %{}}
      end
    end

    Jobs.start(:browser_install, server: jobs, name: "browser", target: "browser", run: run)
  end

  # A Doctor of the test's own, with its own task supervisor, so no session of
  # the application's Doctor is touched.
  defp start_doctor!(ctx) do
    name = :"daemon_forwarding_doctor_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Doctor, name: name, task_supervisor: ctx.tasks},
      id: name
    )
  end

  defp server_link_row do
    %{
      id: "server_link",
      category: :connectivity,
      severity: :warning,
      applicability: :configured,
      origin: :engine,
      run: fn -> %{name: "server link", status: :ok, detail: "connected to fermix-vm"} end
    }
  end

  defp link_status do
    %{
      primary: %{
        name: "fermix-vm",
        connected: true,
        status: :connected,
        sentence: "Fermix is connected.",
        path: :direct
      },
      desktops: [],
      enrollment: nil
    }
  end

  defp unlinked, do: %{primary: nil, desktops: [], enrollment: nil}

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
