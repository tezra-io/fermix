defmodule FermixCore.Management.ProvisionProvidersTest do
  # M75 lean v1 §4.3: Always On's provisioner is the same for every provider
  # in `Provision.Registry`. Connect names the provider; options, create,
  # power, the read back and delete act on the one Always On speaks of
  # (`Provision.current/2`). Run here on an invented provider alone
  # (`FermixTestSupport.FakeCloudProvider`), so the provisioner is shown to
  # need nothing of Hetzner's.
  use ExUnit.Case, async: true

  alias FermixCore.Home.Epoch
  alias FermixCore.Home.Provision.Hetzner
  alias FermixCore.Home.Provision.Ledger
  alias FermixCore.Management.Jobs
  alias FermixCore.Management.Protocol
  alias FermixCore.Management.Provision
  alias FermixCore.Management.Router
  alias FermixTestSupport.FakeCloudProvider
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.TelemetryCapture

  @now ~U[2031-05-04 10:00:00Z]
  @primary %{role: :primary, primary: nil}
  @code "fxenroll1.eyJ2IjoxLCJuYW1lIjoiaW52ZW50ZWQifQ"

  setup context do
    home = SafeRm.make_tmp_dir!("provision-providers")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    :ok = Epoch.write(home, 4)
    test = self()

    tasks = :"providers_tasks_#{:erlang.phash2(context.test)}"
    start_supervised!({Task.Supervisor, name: tasks}, id: tasks)

    jobs =
      start_supervised!(
        {Jobs, name: :"providers_jobs_#{:erlang.phash2(context.test)}", task_supervisor: tasks}
      )

    world = FakeCloudProvider.start!()

    seams = [
      home: home,
      profile: "general",
      jobs: [server: jobs],
      providers: [FakeCloudProvider],
      provider_opts: [now: fn -> @now end, world: world],
      open_code: fn ->
        send(test, :code_opened)
        {:ok, @code}
      end,
      withdraw_code: fn ->
        send(test, :code_withdrawn)
        :ok
      end
    ]

    %{home: home, seams: seams, jobs: [server: jobs], world: world}
  end

  describe "the family on a provider that is not Hetzner" do
    test "connects, offers, creates, powers, reads back and deletes", ctx do
      assert {:ok, view} = connect(ctx)
      assert %{"provider" => "nimbus", "state" => "connected", "token" => "accepted"} = view
      assert {:ok, %{token: token}} = Ledger.read(ctx.home, "nimbus")
      assert token == FakeCloudProvider.token()
      refute File.exists?(Ledger.path(ctx.home, "hetzner"))

      assert {:ok, options} = options(ctx)
      assert options["provider"] == %{"id" => "nimbus", "name" => "Nimbus"}
      assert options["sentence"] == "Recommended: Small 4 in Oslo, €12 a month."

      assert {:ok, job} = create(ctx)
      assert %{"status" => "completed", "result" => result} = finished(job, ctx)

      assert result == %{
               "server" => "fermix-general-" <> ref(ctx),
               "type" => "small-4",
               "location" => "osl1"
             }

      assert_received :code_opened

      view = resources(ctx)
      assert %{"provider" => "nimbus", "state" => "created", "checked" => true} = view
      assert %{"type" => "small-4", "location" => "osl1"} = view["server"]

      # A resource's id is the provider's own, opaque, as a string.
      assert [_server, _firewall, _ip] = view["resources"]
      assert Enum.all?(view["resources"], &match?(%{"id" => "nb-" <> _}, &1))

      assert {:ok, job} = power(ctx, "on")
      assert %{"status" => "completed"} = finished(job, ctx)

      assert {:ok, job} = delete(ctx)
      assert %{"status" => "completed"} = finished(job, ctx)
      assert_received :code_withdrawn

      assert %{"state" => "connected", "resources" => []} = resources(ctx)
    end

    test "every refusal names the provider in its own words", ctx do
      assert {:error, :unavailable, %{"sentence" => "Paste a Nimbus access key first."}} =
               options(ctx)

      assert {:error, :invalid_params, %{"field" => "token", "sentence" => sentence}} =
               connect(ctx, %{"provider" => "nimbus", "token" => "invented-wrong-token-0000"})

      assert sentence ==
               "Nimbus does not accept this token, so paste a key that may create servers " <>
                 "from the Nimbus workspace you made for Fermix."

      {:ok, _view} = connect(ctx)

      assert {:error, :invalid_params, %{"field" => "location", "sentence" => sentence}} =
               create(ctx, location: "fsn1")

      assert sentence == "Fermix creates a server in Oslo or Lisbon."
    end

    test "a refusal the provider maps to a shared kind is kept in the ledger", ctx do
      {:ok, _view} = connect(ctx)
      FakeCloudProvider.fault(ctx.world, :create_server, :account_limit)

      assert {:ok, job} = create(ctx)

      assert %{"status" => "failed", "failure" => %{"sentence" => sentence}} = finished(job, ctx)
      assert sentence == "Nimbus limits new servers on this account."

      assert %{"state" => "failed", "failure" => failure} = resources(ctx)

      assert %{"reason" => "account_limit", "sentence" => ^sentence} = failure
    end
  end

  describe "the provider a call names" do
    test "connect needs one, and only one Fermix offers", ctx do
      for provider <- [:absent, "hetzner", 7] do
        params = %{"token" => FakeCloudProvider.token()}
        params = if provider == :absent, do: params, else: Map.put(params, "provider", provider)

        assert {:error, :invalid_params, %{"field" => "provider"}} = connect(ctx, params),
               inspect(provider)
      end
    end

    test "options reads the provider in use: the one whose token Fermix has", ctx do
      ctx = put_in(ctx.seams[:providers], [Hetzner, FakeCloudProvider])

      assert {:error, :unavailable, %{"sentence" => "Paste a Hetzner API token first."}} =
               options(ctx)

      {:ok, _view} = connect(ctx)

      assert {:ok, %{"provider" => %{"id" => "nimbus", "name" => "Nimbus"}} = options} =
               options(ctx)

      assert options["sentence"] == "Recommended: Small 4 in Oslo, €12 a month."
    end

    test "a create waits while another provider holds Fermix's server", ctx do
      ctx = put_in(ctx.seams[:providers], [Hetzner, FakeCloudProvider])

      {:ok, _ledger} =
        Ledger.update(ctx.home, "hetzner", fn ledger ->
          {:ok,
           ledger
           |> Ledger.connect("invented-hetzner-token-0001", ~U[2031-05-04 09:00:00Z])
           |> Ledger.begin_create("a3f9", %{name: "fermix-general-a3f9"})
           |> Ledger.put_server(%{
             name: "fermix-general-a3f9",
             id: "42",
             status: :created,
             type: "cpx22",
             location: "fsn1"
           })}
        end)

      {:ok, _view} = connect(ctx)

      # Always On speaks of the provider that holds it (`Provision.current/2`),
      # one of whose offers the create names.
      assert {:error, :unavailable, %{"sentence" => sentence}} =
               create(ctx, type: "cpx22", location: "fsn1")

      assert sentence == "Your server already exists, so delete it before creating another."
      assert {:ok, %{server: nil, ref: nil}} = Ledger.read(ctx.home, "nimbus")
    end
  end

  # Paste a token: Nimbus's own unless `params` say otherwise.
  defp connect(ctx, params \\ %{"provider" => "nimbus", "token" => FakeCloudProvider.token()}),
    do: answered(Provision.connect(params, seams(ctx)))

  # A create: small-4 in Oslo unless `opts` says another type or location.
  defp create(ctx, opts \\ []) do
    choice = %{
      type: Keyword.get(opts, :type, "small-4"),
      location: Keyword.get(opts, :location, "osl1"),
      replace: false
    }

    answered(Provision.start_create(choice, seams(ctx)))
  end

  defp power(ctx, action), do: answered(Provision.power(%{"action" => action}, seams(ctx)))
  defp delete(ctx), do: answered(Provision.delete(seams(ctx)))

  # The ledger read back from the provider: one reconcile, its end read from
  # its completion event, then the view, with `checked` (the read completed)
  # and `sentence` (why it did not, else the view's own).
  defp resources(ctx) do
    {:ok, job} = Provision.start_reconcile(seams(ctx))
    done = finished(job, ctx)
    view = Provision.view(ctx.home, seams(ctx))

    Map.merge(view, %{
      "checked" => done["status"] == "completed",
      "sentence" => get_in(done, ["failure", "sentence"]) || view["sentence"]
    })
  end

  # The one method of the provisioner still on the wire, through the router
  # as a daemon answers it.
  defp options(ctx), do: route("home.provision.options", %{}, ctx)

  defp seams(ctx), do: Keyword.put(ctx.seams, :engine_role, @primary)

  # A step's answer as the router puts it on the wire.
  defp answered({:ok, view}), do: {:ok, view}

  defp answered({:error, {:unavailable, capability, sentence}}),
    do: {:error, :unavailable, %{"capability" => capability, "sentence" => sentence}}

  defp answered({:error, {:invalid_params, field, sentence}}),
    do: {:error, :invalid_params, %{"field" => field, "sentence" => sentence}}

  defp ref(ctx) do
    {:ok, %{ref: ref}} = Ledger.read(ctx.home, "nimbus")
    ref
  end

  defp route(method, params, ctx) do
    Router.route(
      %{method: method, protocol_version: Protocol.protocol_version(), params: params},
      engine_role: @primary,
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
end
