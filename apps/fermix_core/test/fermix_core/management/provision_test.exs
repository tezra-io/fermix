defmodule FermixCore.Management.ProvisionTest do
  # M75 lean v1 §4.3: Always On's provisioner steps, called as `home.act`
  # calls them, and `home.provision.options` through the router, as a daemon
  # answers it, against the recorded Hetzner API. A create, a power action, a
  # delete and a reconcile are management jobs; their ends are read from the
  # job's own completion event, never waited for by the clock.
  use ExUnit.Case, async: true

  alias FermixCore.BuildInfo
  alias FermixCore.Home.DesktopLink
  alias FermixCore.Home.Epoch
  alias FermixCore.Home.Move
  alias FermixCore.Home.Provision.FirstBoot
  alias FermixCore.Home.Provision.Hetzner
  alias FermixCore.Home.Provision.Ledger
  alias FermixCore.Management.Copy
  alias FermixCore.Management.Jobs
  alias FermixCore.Management.Placement
  alias FermixCore.Management.Protocol
  alias FermixCore.Management.Provision
  alias FermixCore.Management.Router
  alias FermixTestSupport.HetznerStub
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.TelemetryCapture

  @now ~U[2031-05-04 10:00:00Z]
  @primary %{role: :primary, primary: nil}
  @device %{role: :device, primary: "fermix-general-a3f9"}
  @code "fxenroll1.eyJ2IjoxLCJuYW1lIjoiaW52ZW50ZWQifQ"
  @server_code "fxenroll1.eyJ2IjoxLCJuYW1lIjoib2xkLXNlcnZlciJ9"

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
      provider_opts: [
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
      end,
      rename_primary: fn name ->
        send(test, {:renamed, name})
        :ok
      end
    ]

    %{home: home, stub: stub, seams: seams, jobs: [server: jobs]}
  end

  test "home.provision.options is answered on this computer, never sent to the server" do
    assert {:ok, 2} = Protocol.minimum_version("home.provision.options")
    assert Placement.place("home.provision.options", %{}) == :device
    refute Placement.served_forwarded?("home.provision.options", %{})
  end

  describe "connect/2" do
    test "checks the token, keeps it on this computer and says what the project holds", ctx do
      assert {:ok, view} = connect(ctx)

      assert view["provider"] == "hetzner"
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
               connect(ctx, "invented-wrong-token-0000")

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
               connect(ctx, "invented-other-project-token-77")

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
      %{"token" => "refused"} = resources(ctx)

      assert {:ok, %{"token" => "accepted", "state" => "created"}} =
               connect(ctx, "invented-renewed-token-0042")

      assert {:ok, %{token: "invented-renewed-token-0042"}} = Ledger.read(ctx.home, "hetzner")
    end

    test "with nothing created, a token for any project replaces the last", ctx do
      {:ok, _view} = connect(ctx)
      HetznerStub.set(ctx.stub, :other_tokens, ["invented-other-project-token-77"])

      assert {:ok, %{"token" => "accepted"}} = connect(ctx, "invented-other-project-token-77")
    end

    test "a value that cannot be a token is refused before Hetzner is asked", ctx do
      for token <- ["", "short", "has a space in it, long enough", 7] do
        assert {:error, :invalid_params, %{"field" => "token"}} = connect(ctx, token)
      end

      assert HetznerStub.requests(ctx.stub) == []
    end
  end

  describe "home.provision.options" do
    test "asks for a token first", ctx do
      assert {:error, :unavailable, %{"capability" => "home", "sentence" => sentence}} =
               options(ctx)

      assert sentence == "Paste a Hetzner API token first."
    end

    test "answers the offers live, with the recommendation in one sentence", ctx do
      {:ok, _view} = connect(ctx)
      assert {:ok, options} = options(ctx)

      assert options["provider"] == %{"id" => "hetzner", "name" => "Hetzner"}
      assert options["recommended"] == %{"type" => "cpx22", "location" => "fsn1"}
      assert options["sentence"] == "Recommended: CPX22 in Falkenstein, €20 a month."
      assert Copy.violations(options["sentence"], :prose, ["CPX22", "Falkenstein"]) == []
    end

    # Always On setup §3.1: each offer's size and price are the engine's
    # words, so a surface draws them as sent and groups the rows by city.
    test "words each offer: its label and its price, finished", ctx do
      {:ok, _view} = connect(ctx)
      assert {:ok, options} = options(ctx)

      shared = Enum.find(options["offers"], &(&1["type"] == "cpx22" and &1["location"] == "fsn1"))
      assert shared["label"] == "CPX22: 2 cores, 4 GB memory, 80 GB disk"
      assert shared["price"] == "€20.09 a month, billed by the hour until deleted"

      dedicated = Enum.find(options["offers"], &(&1["type"] == "ccx13"))
      assert dedicated["label"] == "CCX13: 2 dedicated cores, 8 GB memory, 80 GB disk"

      cities = Map.new(options["locations"], &{&1["id"], &1["city"]})

      for offer <- options["offers"] do
        assert is_binary(cities[offer["location"]]), inspect(offer)
        assert Copy.violations(offer["label"], :prose, [offer["description"]]) == []

        assert offer["price"] ==
                 Copy.summary_line(:costs, {offer["total_monthly"], options["currency"]}, %{})[
                   "value"
                 ]
      end
    end

    # A surface that restarted after the token step reads the offers with
    # nothing to name: the provider in use is the engine's own rule.
    test "takes no params: the provider is the one in use", ctx do
      {:ok, _view} = connect(ctx)

      assert options(ctx, %{"provider" => "hetzner"}) ==
               {:error, :invalid_params, %{"method" => "home.provision.options"}}
    end
  end

  describe "start_create/2" do
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

      view = resources(ctx)
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
               Ledger.state(ctx.home, Hetzner)
    end

    test "a read-only token fails at the firewall, before anything costs money", ctx do
      HetznerStub.set(ctx.stub, :read_only, true)

      done = finished(elem(create(ctx), 1), ctx)
      assert done["failure"]["sentence"] =~ "This token can only read"

      assert %{state: :failed, failure: %{reason: "read_only_token"}} =
               Ledger.state(ctx.home, Hetzner)

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
      assert %{token: :refused} = Ledger.state(ctx.home, Hetzner)
    end

    test "only the primary creates a server", ctx do
      assert {:error, :unavailable, %{"sentence" => sentence}} = create(ctx, role: @device)

      # Replacing the server through Fermix's own Hetzner path is later work;
      # in this version the sentence says what to do instead.
      assert sentence ==
               "Fermix runs on your server now, so it creates no other one from here; to " <>
                 "replace that server, get a code in Always On and use it on a Linux server " <>
                 "of your own."
    end

    test "a second server is refused while the first exists", ctx do
      finished(elem(create(ctx), 1), ctx)

      assert {:error, :unavailable, %{"sentence" => sentence}} = create(ctx)
      assert sentence == "Your server already exists, so delete it before creating another."
    end

    test "a type or location outside what Fermix offers is refused by field", ctx do
      assert {:error, :invalid_params, %{"field" => "location"}} = create(ctx, location: "ash")
      assert {:error, :invalid_params, %{"field" => "type"}} = create(ctx, type: "CPX 22")
    end

    test "one operation at a time", ctx do
      HetznerStub.set(ctx.stub, :action_polls, 1_000_000)
      gate = self()

      seams =
        Keyword.update!(ctx.seams, :provider_opts, fn host ->
          Keyword.put(host, :sleep, fn _ms ->
            send(gate, :polling)

            receive do
              :go -> :ok
            end
          end)
        end)

      {:ok, job} = create(%{ctx | seams: seams})

      assert_receive :polling, 10_000

      assert {:error, :busy, %{"operation" => "home_provision"}} = delete(%{ctx | seams: seams})

      {:ok, _cancelled} = Jobs.cancel(job["job_id"], ctx.jobs)
    end
  end

  describe "power/2" do
    setup ctx do
      {:ok, _view} = connect(ctx)
      finished(elem(create(ctx), 1), ctx)
      :ok
    end

    test "turns the server on or restarts it, as a job", ctx do
      for action <- ["on", "reset"] do
        {:ok, job} = power(ctx, action)
        assert %{"status" => "completed", "result" => %{"action" => ^action}} = finished(job, ctx)
      end
    end

    test "refuses another action by field", ctx do
      assert {:error, :invalid_params, %{"field" => "action"}} = power(ctx, "off")
    end
  end

  describe "delete/1" do
    setup ctx do
      {:ok, _view} = connect(ctx)
      finished(elem(create(ctx), 1), ctx)
      :ok
    end

    test "deletes everything Fermix created and keeps the token", ctx do
      {:ok, job} = delete(ctx)
      assert %{"status" => "completed", "result" => %{"deleted" => true}} = finished(job, ctx)
      assert_received :code_withdrawn

      assert %{"state" => "connected", "resources" => []} = resources(ctx)
    end

    test "refuses the server the live home moved to: Replace is the way", ctx do
      linked_desktop!(ctx.home)

      assert {:error, :unavailable, %{"capability" => "home", "sentence" => sentence}} =
               delete(ctx, role: @device)

      assert sentence ==
               "Your server runs Fermix now, so Fermix does not delete it; replace the server " <>
                 "instead."

      assert Ledger.state(ctx.home, Hetzner).state == :created
    end

    test "refuses while this home is moving to it", ctx do
      File.mkdir_p!(Move.dir(ctx.home))
      :ok = Move.put_phase(ctx.home, "streaming", %{"candidate" => "fermix-general-a3f9"}, @now)

      assert {:error, :unavailable, %{"sentence" => sentence}} = delete(ctx, role: @device)

      assert sentence ==
               "Fermix is moving to your server, so it is not deleted while the move runs."
    end

    test "with nothing created, says so", ctx do
      {:ok, job} = delete(ctx)
      finished(job, ctx)

      assert {:error, :unavailable,
              %{"sentence" => "Fermix created nothing on Hetzner to delete."}} = delete(ctx)
    end
  end

  # Always On setup §5: a step's action is written before its job and
  # cleared by its end; every ending lands in the ledger with the step, size
  # and place it was for; the server costs what its offer cost; an action
  # whose job is gone is an interrupted step; and a reconcile is a job.
  describe "a step's action and every ending" do
    setup ctx do
      {:ok, _view} = connect(ctx)
      :ok
    end

    test "the action stands from before the job until its end clears it", ctx do
      assert :ok = Provision.put_action("create", ctx.seams)
      assert {:error, {:busy, "home_provision"}} = Provision.put_action("delete", ctx.seams)
      assert %{action: %{kind: "create"}} = Ledger.state(ctx.home, Hetzner)

      done = finished(elem(create(ctx), 1), ctx)
      assert done["status"] == "completed"
      assert %{action: nil, state: :created} = Ledger.state(ctx.home, Hetzner)

      # A failed step ends the same way.
      assert :ok = Provision.put_action("power_on", ctx.seams)
      HetznerStub.fault(ctx.stub, "POST", ~r"/actions/poweron$", 500, "server_error")
      {:ok, job} = power(ctx, "on")
      assert %{"status" => "failed"} = finished(job, ctx)
      assert %{action: nil} = Ledger.state(ctx.home, Hetzner)

      assert :ok = Provision.clear_action(ctx.seams)
    end

    test "the server costs what the offer it was created from costs", ctx do
      {:ok, options} = options(ctx)
      offer = Enum.find(options["offers"], &(&1["type"] == "cpx22" and &1["location"] == "fsn1"))

      finished(elem(create(ctx), 1), ctx)

      assert %{server: %{total_monthly: total, currency: currency}} =
               Ledger.state(ctx.home, Hetzner)

      assert {total, currency} == {offer["total_monthly"], options["currency"]}
    end

    # The recommendation is an offer the owner was shown like any other: a
    # create names its size and place, and the job never makes one up.
    test "with no choice the create is refused on the type, and starts no job", ctx do
      assert {:error, {:invalid_params, "type", _sentence}} =
               Provision.start_create(%{type: nil, location: nil, replace: false}, ctx.seams)

      assert {:ok, []} = Jobs.list(ctx.seams[:jobs])
    end

    test "the size and place chosen are the step's before its job starts", ctx do
      assert :ok = Provision.put_action("create", ctx.seams)
      test = self()

      spy =
        Keyword.update!(ctx.seams, :provider_opts, fn host ->
          Keyword.put(host, :sleep, fn _ms ->
            send(test, {:action, Ledger.state(ctx.home, Hetzner).action})
            :ok
          end)
        end)

      {:ok, job} = Provision.start_create(%{type: "cpx32", location: "hel1", replace: false}, spy)
      assert %{"status" => "completed", "result" => result} = finished(job, ctx)
      assert %{"type" => "cpx32", "location" => "hel1"} = result
      assert_received {:action, %{kind: "create", type: "cpx32", location: "hel1"}}
    end

    test "a choice of one without the other is refused by field", ctx do
      assert {:error, {:invalid_params, "location", _sentence}} =
               Provision.start_create(%{type: "cpx22", location: nil, replace: false}, ctx.seams)

      assert {:error, {:invalid_params, "type", _sentence}} =
               Provision.start_create(%{type: nil, location: "fsn1", replace: false}, ctx.seams)
    end

    test "a refused create keeps its step, size and place", ctx do
      HetznerStub.fault(ctx.stub, "POST", ~r"^/v1/servers$", 412, "resource_unavailable")
      finished(elem(create(ctx), 1), ctx)

      assert %{failure: %{action: "create", type: "cpx22", location: "fsn1"}} =
               Ledger.state(ctx.home, Hetzner)
    end

    test "a failed power action stays in the ledger as the power's failure", ctx do
      finished(elem(create(ctx), 1), ctx)
      HetznerStub.fault(ctx.stub, "POST", ~r"/actions/reset$", 500, "server_error")

      {:ok, job} = power(ctx, "reset")
      assert %{"status" => "failed", "failure" => %{"sentence" => sentence}} = finished(job, ctx)

      assert %{
               state: :failed,
               failure: %{action: "power_reset", type: "cpx22", location: "fsn1"} = failure
             } = Ledger.state(ctx.home, Hetzner)

      assert failure.sentence == sentence
    end

    test "a delete that fails stays in the ledger as the delete's failure", ctx do
      finished(elem(create(ctx), 1), ctx)
      HetznerStub.fault(ctx.stub, "DELETE", ~r"^/v1/servers/", 500, "server_error")

      {:ok, job} = delete(ctx)
      assert %{"status" => "failed"} = finished(job, ctx)

      assert %{state: :failed, failure: %{action: "delete", type: "cpx22"}} =
               Ledger.state(ctx.home, Hetzner)
    end

    test "at boot, an action whose job is gone becomes the interrupted step", ctx do
      assert :ok = Provision.put_action("delete", ctx.seams)
      assert :ok = Provision.interrupt_left_actions(ctx.seams)

      assert %{state: :failed, action: nil, failure: failure} = Ledger.state(ctx.home, Hetzner)
      assert %{reason: "interrupted", action: "delete", at: @now} = failure

      # Nothing stood: nothing is written.
      before = File.read!(Ledger.path(ctx.home, "hetzner"))
      assert :ok = Provision.interrupt_left_actions(ctx.seams)
      assert File.read!(Ledger.path(ctx.home, "hetzner")) == before
    end

    test "a reconcile is a job of the family, and writes when it read Hetzner back", ctx do
      finished(elem(create(ctx), 1), ctx)
      assert %{checked_at: nil} = Ledger.state(ctx.home, Hetzner)

      assert {:ok, %{"kind" => "home_provision"} = job} = Provision.start_reconcile(ctx.seams)
      assert %{"status" => "completed"} = finished(job, ctx)
      assert %{checked_at: @now} = Ledger.state(ctx.home, Hetzner)
    end
  end

  describe "start_reconcile/1 and view/2" do
    test "marks what was deleted outside Fermix gone", ctx do
      {:ok, _view} = connect(ctx)
      finished(elem(create(ctx), 1), ctx)
      {:ok, ledger} = Ledger.read(ctx.home, "hetzner")
      HetznerStub.delete_outside(ctx.stub, :servers, String.to_integer(ledger.server.id))

      assert %{"state" => "gone", "server" => %{"status" => "gone"}} = resources(ctx)
    end

    test "a token that stopped working still lists what was created, and says so", ctx do
      {:ok, _view} = connect(ctx)
      finished(elem(create(ctx), 1), ctx)
      HetznerStub.set(ctx.stub, :token, "invented-other-token")

      view = resources(ctx)
      assert view["token"] == "refused"
      assert view["checked"] == false
      assert view["sentence"] == "Hetzner no longer accepts Fermix's token."
      assert length(view["resources"]) == 4
    end
  end

  # M75 lean v1 §4.3, §7 `on` Details "Replace the server", §8: from the
  # computer the home moved off, a new server is created with a 24-hour code
  # the old server opens over the link, the move to it is the existing one,
  # and the old server is deleted once this computer sees that move done.
  describe "replacing the server from the linked desktop" do
    setup ctx do
      {:ok, _view} = connect(ctx)
      finished(elem(create(ctx), 1), ctx)
      assert_received :code_opened
      {:ok, ledger} = Ledger.read(ctx.home, "hetzner")
      linked_desktop!(ctx.home)
      %{old: ledger.server, seams: answering(ctx, %{}).seams}
    end

    test "asks the server for a 24-hour code, creates a new server with it, keeps both", ctx do
      {:ok, job} = replace(ctx)
      done = finished(job, ctx)

      assert done["status"] == "completed"
      assert %{"server" => new_name, "type" => "cpx32", "location" => "hel1"} = done["result"]
      assert new_name != ctx.old.name

      assert_received {:forwarded, "home.enroll.open", %{"kind" => "provisioned"}}
      refute_received :code_opened

      # The new server installs the release this computer runs.
      {:ok, user_data} =
        FirstBoot.user_data(@server_code, BuildInfo.product_version(), Hetzner.max_user_data())

      assert [%{"user_data" => ^user_data, "name" => ^new_name}] =
               for({"POST", "/v1/servers", _q, body} <- HetznerStub.requests(ctx.stub), do: body)
               |> Enum.drop(1)

      assert %{
               state: :created,
               server: %{name: ^new_name},
               replace: %{state: :waiting, current: :old, old: %{name: old_name}}
             } = Ledger.state(ctx.home, Hetzner)

      assert old_name == ctx.old.name

      view = resources(ctx, role: @device)

      assert view["replace"] == %{
               "state" => "waiting",
               "current" => "old",
               "old" => view["replace"]["old"],
               "failure" => nil
             }

      assert view["replace"]["old"]["name"] == ctx.old.name
      assert Enum.count(view["resources"], & &1["replaced"]) == 4
      assert Enum.count(view["resources"], &(not &1["replaced"])) == 4
      assert map_size(HetznerStub.world(ctx.stub).servers) == 2
    end

    test "a create without the replace intent, or one with nothing to replace, is refused", ctx do
      assert {:error, :unavailable, %{"sentence" => sentence}} =
               create(ctx, type: "cpx32", location: "hel1", role: @device)

      assert sentence ==
               "Fermix runs on your server now, so a new server from here can only replace it."

      assert {:error, :unavailable, %{"sentence" => sentence}} =
               create(ctx, type: "cpx32", location: "hel1", replace: true)

      assert sentence == "Fermix runs on this computer, so there is no server to replace yet."

      refute_received {:forwarded, _method, _params}
    end

    test "a home on a server Fermix did not create is replaced with a code, as before", ctx do
      {:ok, _ledger} = Ledger.update(ctx.home, "hetzner", &{:ok, Ledger.clear(&1)})

      assert {:error, :unavailable, %{"sentence" => sentence}} = replace(ctx)
      assert sentence =~ "get a code in Always On and use it on a Linux server of your own"
    end

    test "the server's refusal to open the code is said in its own words", ctx do
      ctx =
        answering(ctx, %{
          "home.enroll.open" =>
            {:error, :unavailable,
             %{"capability" => "home", "sentence" => "Remote reach is off."}}
        })

      done = finished(elem(replace(ctx), 1), ctx)
      assert done["status"] == "failed"
      assert done["failure"]["sentence"] == "Remote reach is off."
      assert map_size(HetznerStub.world(ctx.stub).servers) == 1

      assert %{
               replace: %{
                 state: :failed,
                 current: :old,
                 failure: %{sentence: "Remote reach is off."}
               }
             } =
               Ledger.state(ctx.home, Hetzner)

      unreachable =
        answering(ctx, %{
          "home.enroll.open" =>
            {:error, :primary_unreachable, %{"sentence" => "The server is unreachable."}}
        })

      done = finished(elem(replace(unreachable), 1), ctx)

      assert done["failure"]["sentence"] ==
               "Fermix cannot reach your server to get a code for the new one, so try again " <>
                 "once your server is back."
    end

    test "a create Hetzner refuses closes the code on the server", ctx do
      HetznerStub.fault(ctx.stub, "POST", ~r"^/v1/servers$", 403, "resource_limit_exceeded")

      done = finished(elem(replace(ctx), 1), ctx)
      assert done["failure"]["sentence"] == "Hetzner limits new servers on this account."
      assert_received {:forwarded, "home.enroll.withdraw", %{}}

      assert %{state: :failed, replace: %{state: :failed, current: :old}} =
               Ledger.state(ctx.home, Hetzner)

      # Cancel gives the ledger back the server the home lives on.
      done = finished(elem(delete(ctx, role: @device), 1), ctx)
      assert done["status"] == "completed"
      assert %{state: :created, server: server, replace: nil} = Ledger.state(ctx.home, Hetzner)
      assert server.name == ctx.old.name
    end

    test "Cancel deletes only the new server and closes its code on the server", ctx do
      finished(elem(replace(ctx), 1), ctx)
      {:ok, job} = delete(ctx, role: @device)

      assert %{"status" => "completed"} = finished(job, ctx)
      assert_received {:forwarded, "home.enroll.withdraw", %{}}
      assert Map.keys(HetznerStub.world(ctx.stub).servers) == [String.to_integer(ctx.old.id)]

      assert %{state: :created, server: %{name: name}, replace: nil} =
               Ledger.state(ctx.home, Hetzner)

      assert name == ctx.old.name

      # The server the home lives on is still never deleted.
      assert {:error, :unavailable, %{"sentence" => sentence}} = delete(ctx, role: @device)

      assert sentence =~ "replace the server instead"
    end

    test "the move to the new server, once this computer started it, holds every change", ctx do
      finished(elem(replace(ctx), 1), ctx)

      assert :nothing =
               Provision.move_forwarded(%{"candidate_id" => "cand-new"}, refused(), ctx.seams)

      assert %{replace: %{state: :waiting}} = Ledger.state(ctx.home, Hetzner)

      assert :recorded =
               Provision.move_forwarded(
                 %{"candidate_id" => "cand-new", "keep_as_desktop" => false},
                 {:error, :unconfirmed, %{"method" => "home.move.start"}},
                 ctx.seams
               )

      assert %{replace: %{state: :moving, current: :old}} = Ledger.state(ctx.home, Hetzner)

      assert {:error, :unavailable, %{"sentence" => sentence}} = delete(ctx, role: @device)

      assert sentence ==
               "Fermix is moving to your server, so it is not deleted while the move runs."

      assert {:error, :unavailable, %{"sentence" => sentence}} = replace(ctx)

      assert sentence ==
               "Fermix is moving to your new server, so it creates no other one until the " <>
                 "move is done."

      # The old server answering again at its own epoch undid the move.
      assert :undone = Provision.primary_reached(5, ctx.seams)
      assert %{replace: %{state: :waiting}} = Ledger.state(ctx.home, Hetzner)
    end

    test "once this computer reaches a server one epoch up, the old one is deleted, once", ctx do
      finished(elem(replace(ctx), 1), ctx)
      {:ok, ledger} = Ledger.read(ctx.home, "hetzner")
      # The old server answering before the move changes nothing.
      assert :nothing = Provision.primary_reached(5, ctx.seams)

      :recorded =
        Provision.move_forwarded(%{"candidate_id" => "cand-new"}, {:ok, %{}}, ctx.seams)

      assert {:deleting, job} = Provision.primary_reached(6, ctx.seams)
      assert %{"status" => "completed", "kind" => "home_provision"} = finished(job, ctx)

      # The desktop's link names the server the home moved to from now on.
      new_name = ledger.server.name
      assert_received {:renamed, ^new_name}
      refute new_name == ctx.old.name

      assert Map.keys(HetznerStub.world(ctx.stub).servers) == [
               String.to_integer(ledger.server.id)
             ]

      assert %{state: :created, replace: %{state: :done, current: :new, old: nil}} =
               Ledger.state(ctx.home, Hetzner)

      assert :nothing = Provision.primary_reached(6, ctx.seams)
      assert {:ok, views} = Jobs.list(ctx.jobs)
      assert Enum.count(views, &(&1["kind"] == "home_provision")) == 3

      # The new server holds the home now: it is not deleted, it is replaced.
      assert {:error, :unavailable, %{"sentence" => sentence}} = delete(ctx, role: @device)

      assert sentence =~ "replace the server instead"
    end

    test "a delete of the old server that fails leaves it listed, and Delete tries again", ctx do
      finished(elem(replace(ctx), 1), ctx)
      HetznerStub.fault(ctx.stub, "DELETE", ~r"^/v1/servers/#{ctx.old.id}$", 500, "server_error")

      {:deleting, job} = Provision.primary_reached(6, ctx.seams)
      assert %{"status" => "failed", "failure" => %{"sentence" => sentence}} = finished(job, ctx)
      assert sentence =~ "Fermix could not delete your old server: Hetzner refused the request"
      # The move is done all the same: the link names the new server.
      assert_received {:renamed, _new_name}

      assert %{replace: %{state: :failed, current: :new, failure: %{sentence: ^sentence}}} =
               Ledger.state(ctx.home, Hetzner)

      # Once: seeing the server again tries nothing by itself.
      assert :nothing = Provision.primary_reached(6, ctx.seams)

      view = resources(ctx, role: @device)
      assert %{"state" => "failed", "failure" => %{"sentence" => ^sentence}} = view["replace"]

      assert [%{"kind" => "server", "id" => old_id} | _rest] =
               Enum.filter(view["resources"], & &1["replaced"])

      assert old_id == ctx.old.id

      {:ok, job} = delete(ctx, role: @device)
      assert %{"status" => "completed"} = finished(job, ctx)
      assert %{replace: %{state: :done}} = Ledger.state(ctx.home, Hetzner)
      assert map_size(HetznerStub.world(ctx.stub).servers) == 1
    end
  end

  defp replace(ctx),
    do: create(ctx, type: "cpx32", location: "hel1", replace: true, role: @device)

  defp refused,
    do: {:error, :unavailable, %{"capability" => "home", "sentence" => "Not ready."}}

  defp server_answer("home.enroll.open"),
    do: {:ok, %{"code" => @server_code, "expires_at" => "2031-05-05T10:00:00Z"}}

  defp server_answer("home.enroll.withdraw"), do: {:ok, %{"withdrawn" => true}}

  # A linked desktop's way to its server, answering each method as the
  # server would, or as `answers` says.
  defp answering(ctx, answers) do
    test = self()

    forward = fn %{method: method, params: params}, _opts ->
      send(test, {:forwarded, method, params})

      Map.get_lazy(answers, method, fn -> server_answer(method) end)
    end

    seams =
      ctx.seams
      |> Keyword.drop([:open_code, :withdraw_code])
      |> Keyword.put(:primary_forward, forward)

    %{ctx | seams: seams}
  end

  # Paste a token: Hetzner's own unless said.
  defp connect(ctx, token \\ HetznerStub.token()),
    do: answered(Provision.connect(%{"provider" => "hetzner", "token" => token}, seams(ctx)))

  # A create, on the engine role `opts` names: cpx22 in Falkenstein unless
  # `opts` says another type, location or the replace.
  defp create(ctx, opts \\ []) do
    choice = %{
      type: Keyword.get(opts, :type, "cpx22"),
      location: Keyword.get(opts, :location, "fsn1"),
      replace: Keyword.get(opts, :replace, false)
    }

    answered(Provision.start_create(choice, seams(ctx, opts)))
  end

  defp power(ctx, action),
    do: answered(Provision.power(%{"action" => action}, seams(ctx)))

  defp delete(ctx, opts \\ []), do: answered(Provision.delete(seams(ctx, opts)))

  # The ledger read back from the provider: one reconcile, its end read from
  # its completion event, then the view, with `checked` (the read completed)
  # and `sentence` (why it did not, else the view's own).
  defp resources(ctx, opts \\ []) do
    seams = seams(ctx, opts)
    {:ok, job} = Provision.start_reconcile(seams)
    done = finished(job, ctx)
    view = Provision.view(ctx.home, seams)

    Map.merge(view, %{
      "checked" => done["status"] == "completed",
      "sentence" => get_in(done, ["failure", "sentence"]) || view["sentence"]
    })
  end

  # The one method of the provisioner still on the wire, through the router
  # as a daemon answers it.
  defp options(ctx, params \\ %{}) do
    Router.route(
      %{
        method: "home.provision.options",
        protocol_version: Protocol.protocol_version(),
        params: params
      },
      engine_role: @primary,
      operation_opts: [provision: ctx.seams]
    )
  end

  # The seams a step runs with on the engine role `opts` names (the primary
  # unless said); a linked desktop's way to its server (`:primary_forward`)
  # is in `ctx.seams` already, as `home.act` passes it on.
  defp seams(ctx, opts \\ []),
    do: Keyword.put(ctx.seams, :engine_role, Keyword.get(opts, :role, @primary))

  # A step's answer as the router puts it on the wire.
  defp answered({:ok, view}), do: {:ok, view}
  defp answered({:error, {:busy, operation}}), do: {:error, :busy, %{"operation" => operation}}

  defp answered({:error, {:unavailable, capability, sentence}}),
    do: {:error, :unavailable, %{"capability" => capability, "sentence" => sentence}}

  defp answered({:error, {:invalid_params, field, sentence}}),
    do: {:error, :invalid_params, %{"field" => field, "sentence" => sentence}}

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
