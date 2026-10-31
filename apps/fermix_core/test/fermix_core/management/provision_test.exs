defmodule FermixCore.Management.ProvisionTest do
  # M75 lean v1 §4.3: the `home.provision.*` family through the router, as a
  # daemon answers it, against the recorded Hetzner API. A create, a power
  # action and a delete are management jobs; their ends are read from the
  # job's own completion event, never waited for by the clock.
  use ExUnit.Case, async: true

  alias FermixCore.Home.DesktopLink
  alias FermixCore.Home.Epoch
  alias FermixCore.Home.Move
  alias FermixCore.Home.Provision.Ledger
  alias FermixCore.Management.Copy
  alias FermixCore.Management.Jobs
  alias FermixCore.Management.Placement
  alias FermixCore.Management.Protocol
  alias FermixCore.Management.Router
  alias FermixTestSupport.HetznerStub
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.TelemetryCapture

  @now ~U[2031-05-04 10:00:00Z]
  @primary %{role: :primary, primary: nil}
  @device %{role: :device, primary: "fermix-general-a3f9"}
  @code "fxenroll1.eyJ2IjoxLCJuYW1lIjoiaW52ZW50ZWQifQ"
  @methods ~w(home.provision.connect home.provision.options home.provision.create
              home.provision.power home.provision.resources home.provision.delete)

  setup context do
    home = SafeRm.make_tmp_dir!("provision")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    :ok = Epoch.write(home, 4)
    stub = HetznerStub.start!()
    test = self()

    tasks = :"provision_tasks_#{:erlang.phash2(context.test)}"
    start_supervised!({Task.Supervisor, name: tasks}, id: tasks)

    jobs =
      start_supervised!(
        {Jobs, name: :"provision_jobs_#{:erlang.phash2(context.test)}", task_supervisor: tasks}
      )

    seams = [
      home: home,
      profile: "general",
      jobs: [server: jobs],
      host_opts: [
        req_options: HetznerStub.req_options(stub),
        now: fn -> @now end,
        sleep: fn _ms -> :ok end
      ],
      open_code: fn ->
        send(test, :code_opened)
        {:ok, @code}
      end,
      withdraw_code: fn ->
        send(test, :code_withdrawn)
        :ok
      end
    ]

    %{home: home, stub: stub, seams: seams, jobs: [server: jobs]}
  end

  test "the family is answered on this computer, never sent to the server" do
    for method <- @methods do
      assert {:ok, 2} = Protocol.minimum_version(method)
      assert Placement.place(method, %{}) == :device
      refute Placement.served_forwarded?(method, %{})
    end
  end

  describe "home.provision.connect" do
    test "checks the token, keeps it on this computer and says what the project holds", ctx do
      assert {:ok, view} = connect(ctx)

      assert view["state"] == "connected"
      assert view["token"] == "accepted"
      assert view["other_servers"] == false
      assert view["resources"] == []
      refute inspect(view) =~ HetznerStub.token()

      assert {:ok, %{token: token}} = Ledger.read(ctx.home, "hetzner")
      assert token == HetznerStub.token()
      assert Bitwise.band(File.stat!(Ledger.path(ctx.home, "hetzner")).mode, 0o777) == 0o600
      refute File.exists?(Path.join(ctx.home, "config.toml"))
    end

    test "a token Hetzner does not accept is refused at once, and kept nowhere", ctx do
      assert {:error, :invalid_params, %{"field" => "token", "sentence" => sentence}} =
               route("home.provision.connect", %{"token" => "invented-wrong-token-0000"}, ctx)

      assert sentence ==
               "Hetzner does not accept this token, so paste a Read & Write API token from " <>
                 "the Hetzner project you made for Fermix."

      refute File.exists?(Ledger.path(ctx.home, "hetzner"))
    end

    test "a token for another Hetzner project is refused while Fermix's server stands", ctx do
      {:ok, _view} = connect(ctx)
      finished(elem(create(ctx), 1), ctx)
      HetznerStub.set(ctx.stub, :other_tokens, ["invented-other-project-token-77"])

      assert {:error, :invalid_params, %{"field" => "token", "sentence" => sentence}} =
               route(
                 "home.provision.connect",
                 %{"token" => "invented-other-project-token-77"},
                 ctx
               )

      assert sentence ==
               "This token is for another Hetzner project than the server Fermix created, so " <>
                 "paste a token from that project."

      assert {:ok, %{token: token}} = Ledger.read(ctx.home, "hetzner")
      assert token == HetznerStub.token()
    end

    test "a new token from the same project replaces one that stopped working", ctx do
      {:ok, _view} = connect(ctx)
      finished(elem(create(ctx), 1), ctx)
      HetznerStub.set(ctx.stub, :token, "invented-renewed-token-0042")
      {:ok, %{"token" => "refused"}} = route("home.provision.resources", %{}, ctx)

      assert {:ok, %{"token" => "accepted", "state" => "created"}} =
               route("home.provision.connect", %{"token" => "invented-renewed-token-0042"}, ctx)

      assert {:ok, %{token: "invented-renewed-token-0042"}} = Ledger.read(ctx.home, "hetzner")
    end

    test "with nothing created, a token for any project replaces the last", ctx do
      {:ok, _view} = connect(ctx)
      HetznerStub.set(ctx.stub, :other_tokens, ["invented-other-project-token-77"])

      assert {:ok, %{"token" => "accepted"}} =
               route(
                 "home.provision.connect",
                 %{"token" => "invented-other-project-token-77"},
                 ctx
               )
    end

    test "a value that cannot be a token is refused before Hetzner is asked", ctx do
      for token <- ["", "short", "has a space in it, long enough", 7] do
        assert {:error, :invalid_params, %{"field" => "token"}} =
                 route("home.provision.connect", %{"token" => token}, ctx)
      end

      assert HetznerStub.requests(ctx.stub) == []
    end
  end

  describe "home.provision.options" do
    test "asks for a token first", ctx do
      assert {:error, :unavailable, %{"capability" => "home", "sentence" => sentence}} =
               route("home.provision.options", %{}, ctx)

      assert sentence == "Paste a Hetzner API token first."
    end

    test "answers the offers live, with the recommendation in one sentence", ctx do
      {:ok, _view} = connect(ctx)
      assert {:ok, options} = route("home.provision.options", %{}, ctx)

      assert options["recommended"] == %{"type" => "cpx22", "location" => "fsn1"}
      assert options["sentence"] == "Recommended: CPX22 in Falkenstein, €20 a month."
      assert Copy.violations(options["sentence"], :prose, ["CPX22", "Falkenstein"]) == []
    end
  end

  describe "home.provision.create" do
    setup ctx do
      {:ok, _view} = connect(ctx)
      :ok
    end

    test "is a job that creates the server, its 24-hour code inside", ctx do
      assert {:ok, %{"kind" => "home_provision", "status" => "running"} = job} = create(ctx)

      done = finished(job, ctx)
      assert done["status"] == "completed"

      assert %{"server" => "fermix-general-" <> _ref, "type" => "cpx22", "location" => "fsn1"} =
               done["result"]

      assert_received :code_opened

      assert {:ok, view} = route("home.provision.resources", %{}, ctx)
      assert view["state"] == "created"
      assert view["checked"] == true

      assert %{"name" => "fermix-general-" <> _, "status" => "created", "power" => "running"} =
               view["server"]

      kinds = Enum.map(view["resources"], & &1["kind"])
      assert kinds == ["server", "firewall", "primary_ip", "primary_ip"]
      refute inspect(view) =~ HetznerStub.root_password()
      refute inspect(done) =~ HetznerStub.root_password()
    end

    test "a location Hetzner has no capacity in fails with the next one in stock", ctx do
      HetznerStub.fault(ctx.stub, "POST", ~r"^/v1/servers$", 412, "resource_unavailable")

      {:ok, job} = create(ctx)
      done = finished(job, ctx)

      assert done["status"] == "failed"
      assert done["failure"]["sentence"] == "Falkenstein has no CPX22 right now."

      assert %{state: :failed, failure: %{reason: "unavailable", next_location: "nbg1"}} =
               Ledger.state(ctx.home)
    end

    test "a read-only token fails at the firewall, before anything costs money", ctx do
      HetznerStub.set(ctx.stub, :read_only, true)

      done = finished(elem(create(ctx), 1), ctx)
      assert done["failure"]["sentence"] =~ "This token can only read"
      assert %{state: :failed, failure: %{reason: "read_only_token"}} = Ledger.state(ctx.home)
      refute_received :code_opened
    end

    test "the account's limit is said as Hetzner's limit", ctx do
      HetznerStub.fault(ctx.stub, "POST", ~r"^/v1/servers$", 403, "resource_limit_exceeded")
      done = finished(elem(create(ctx), 1), ctx)
      assert done["failure"]["sentence"] == "Hetzner limits new servers on this account."
    end

    test "a token that stopped working is recorded refused", ctx do
      HetznerStub.set(ctx.stub, :token, "invented-other-token")
      done = finished(elem(create(ctx), 1), ctx)

      assert done["failure"]["sentence"] == "Hetzner no longer accepts Fermix's token."
      assert %{token: :refused} = Ledger.state(ctx.home)
    end

    test "only the primary creates a server", ctx do
      assert {:error, :unavailable, %{"sentence" => sentence}} =
               route("home.provision.create", %{"type" => "cpx22", "location" => "fsn1"}, ctx,
                 role: @device
               )

      assert sentence == "Fermix creates a server only on the computer its home runs on."
    end

    test "a second server is refused while the first exists", ctx do
      finished(elem(create(ctx), 1), ctx)

      assert {:error, :unavailable, %{"sentence" => sentence}} = create(ctx)
      assert sentence == "Your server already exists, so delete it before creating another."
    end

    test "a type or location outside what Fermix offers is refused by field", ctx do
      assert {:error, :invalid_params, %{"field" => "location"}} =
               route("home.provision.create", %{"type" => "cpx22", "location" => "ash"}, ctx)

      assert {:error, :invalid_params, %{"field" => "type"}} =
               route("home.provision.create", %{"type" => "CPX 22", "location" => "fsn1"}, ctx)

      assert {:error, :invalid_params, %{"field" => "extra"}} =
               route(
                 "home.provision.create",
                 %{"type" => "cpx22", "location" => "fsn1", "extra" => 1},
                 ctx
               )
    end

    test "one operation at a time", ctx do
      HetznerStub.set(ctx.stub, :action_polls, 1_000_000)
      gate = self()

      seams =
        Keyword.update!(ctx.seams, :host_opts, fn host ->
          Keyword.put(host, :sleep, fn _ms ->
            send(gate, :polling)

            receive do
              :go -> :ok
            end
          end)
        end)

      {:ok, job} =
        route("home.provision.create", %{"type" => "cpx22", "location" => "fsn1"}, %{
          ctx
          | seams: seams
        })

      assert_receive :polling, 10_000

      assert {:error, :busy, %{"operation" => "home_provision"}} =
               route("home.provision.delete", %{}, %{ctx | seams: seams})

      {:ok, _cancelled} = Jobs.cancel(job["job_id"], ctx.jobs)
    end
  end

  describe "home.provision.power" do
    setup ctx do
      {:ok, _view} = connect(ctx)
      finished(elem(create(ctx), 1), ctx)
      :ok
    end

    test "turns the server on or restarts it, as a job", ctx do
      for action <- ["on", "reset"] do
        {:ok, job} = route("home.provision.power", %{"action" => action}, ctx)
        assert %{"status" => "completed", "result" => %{"action" => ^action}} = finished(job, ctx)
      end
    end

    test "refuses another action by field", ctx do
      assert {:error, :invalid_params, %{"field" => "action"}} =
               route("home.provision.power", %{"action" => "off"}, ctx)
    end
  end

  describe "home.provision.delete" do
    setup ctx do
      {:ok, _view} = connect(ctx)
      finished(elem(create(ctx), 1), ctx)
      :ok
    end

    test "deletes everything Fermix created and keeps the token", ctx do
      {:ok, job} = route("home.provision.delete", %{}, ctx)
      assert %{"status" => "completed", "result" => %{"deleted" => true}} = finished(job, ctx)
      assert_received :code_withdrawn

      assert {:ok, %{"state" => "connected", "resources" => []}} =
               route("home.provision.resources", %{}, ctx)
    end

    test "refuses the server the live home moved to: Replace is the way", ctx do
      linked_desktop!(ctx.home)

      assert {:error, :unavailable, %{"capability" => "home", "sentence" => sentence}} =
               route("home.provision.delete", %{}, ctx, role: @device)

      assert sentence ==
               "Your server runs Fermix now, so Fermix does not delete it; replace the server " <>
                 "instead."

      assert Ledger.state(ctx.home).state == :created
    end

    test "refuses while this home is moving to it", ctx do
      File.mkdir_p!(Move.dir(ctx.home))
      :ok = Move.put_phase(ctx.home, "streaming", %{"candidate" => "fermix-general-a3f9"}, @now)

      assert {:error, :unavailable, %{"sentence" => sentence}} =
               route("home.provision.delete", %{}, ctx, role: @device)

      assert sentence ==
               "Fermix is moving to your server, so it is not deleted while the move runs."
    end

    test "with nothing created, says so", ctx do
      {:ok, job} = route("home.provision.delete", %{}, ctx)
      finished(job, ctx)

      assert {:error, :unavailable,
              %{"sentence" => "Fermix created nothing on Hetzner to delete."}} =
               route("home.provision.delete", %{}, ctx)
    end
  end

  describe "home.provision.resources" do
    test "with no token, answers none and asks Hetzner nothing", ctx do
      assert {:ok, %{"state" => "none", "token" => "none", "resources" => [], "checked" => false}} =
               route("home.provision.resources", %{}, ctx)

      assert HetznerStub.requests(ctx.stub) == []
    end

    test "marks what was deleted outside Fermix gone", ctx do
      {:ok, _view} = connect(ctx)
      finished(elem(create(ctx), 1), ctx)
      {:ok, ledger} = Ledger.read(ctx.home, "hetzner")
      HetznerStub.delete_outside(ctx.stub, :servers, ledger.server.id)

      assert {:ok, %{"state" => "gone", "server" => %{"status" => "gone"}}} =
               route("home.provision.resources", %{}, ctx)
    end

    test "a token that stopped working still lists what was created, and says so", ctx do
      {:ok, _view} = connect(ctx)
      finished(elem(create(ctx), 1), ctx)
      HetznerStub.set(ctx.stub, :token, "invented-other-token")

      assert {:ok, view} = route("home.provision.resources", %{}, ctx)
      assert view["token"] == "refused"
      assert view["checked"] == false
      assert view["sentence"] == "Hetzner no longer accepts Fermix's token."
      assert length(view["resources"]) == 4
    end
  end

  defp connect(ctx),
    do: route("home.provision.connect", %{"token" => HetznerStub.token()}, ctx)

  defp create(ctx),
    do: route("home.provision.create", %{"type" => "cpx22", "location" => "fsn1"}, ctx)

  defp route(method, params, ctx, opts \\ []) do
    Router.route(
      %{method: method, protocol_version: Protocol.protocol_version(), params: params},
      engine_role: Keyword.get(opts, :role, @primary),
      operation_opts: [provision: ctx.seams]
    )
  end

  # The job's end is its completion event; one that ended before the handler
  # was attached is read as it stands.
  defp finished(%{"job_id" => id}, ctx) do
    TelemetryCapture.attach([[:fermix, :management_job, :complete]], session_id: id)

    case Jobs.get(id, ctx.jobs) do
      {:ok, %{"status" => "running"}} ->
        assert_receive {:telemetry, _event, _measurements, %{session_id: ^id}}, 10_000
        {:ok, view} = Jobs.get(id, ctx.jobs)
        view

      {:ok, view} ->
        view
    end
  end

  # This computer after its home moved to the server: the device role, the
  # link and the move's ending.
  defp linked_desktop!(home) do
    :ok =
      DesktopLink.write(home, %{
        device_id: "6f1e2d3c-4b5a-4968-8778-695a4b3c2d1e",
        primary: %{
          name: "fermix-general-a3f9",
          gateway_pk: <<7::256>>,
          node_id: String.duplicate("ab", 32),
          relays: [%{"url" => "https://relay.invalid/", "quic_port" => 7842}],
          relays_rev: "0123456789abcdef"
        },
        epoch: 5
      })

    File.mkdir_p!(Move.dir(home))
    :ok = Move.put_phase(home, "done", %{"candidate" => "fermix-general-a3f9"}, @now)
  end
end
