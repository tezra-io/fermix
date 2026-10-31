defmodule FermixCore.Management.ProvisionProvidersTest do
  # M75 lean v1 §4.3: the `home.provision.*` family is the same for every
  # provider in `Provision.Registry`. `home.provision.providers` answers each
  # one's display data, so the apps draw the token and choose screens from
  # it; connect, options and create name the provider; power, resources and
  # delete act on the one Fermix created something on. Run here on an
  # invented provider alone (`FermixTestSupport.FakeCloudProvider`), so the
  # family is shown to need nothing of Hetzner's.
  use ExUnit.Case, async: true

  alias FermixCore.Home.Epoch
  alias FermixCore.Home.Provision.Hetzner
  alias FermixCore.Home.Provision.Ledger
  alias FermixCore.Management.Jobs
  alias FermixCore.Management.Placement
  alias FermixCore.Management.Protocol
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

  describe "home.provision.providers" do
    test "is answered on this computer, open to every caller, minimum version 2" do
      assert {:ok, 2} = Protocol.minimum_version("home.provision.providers")
      assert Placement.place("home.provision.providers", %{}) == :device
      assert "home.provision.providers" in Protocol.methods()
    end

    test "answers each provider's display data, the registry's by default", ctx do
      assert {:ok, %{"providers" => [hetzner]}} =
               route("home.provision.providers", %{}, %{ctx | seams: []})

      assert hetzner["id"] == "hetzner"
      assert hetzner["name"] == "Hetzner"
      assert hetzner["token_label"] == Hetzner.display().token_label
      assert hetzner["steps"] == Hetzner.display().steps
      assert hetzner["console_url"] == "https://console.hetzner.cloud/"
      assert hetzner["docs_anchor"] == "hetzner"

      assert {:ok, %{"providers" => [nimbus]}} = route("home.provision.providers", %{}, ctx)

      assert nimbus == %{
               "id" => "nimbus",
               "name" => "Nimbus",
               "token_label" => "Nimbus access key",
               "steps" => FakeCloudProvider.display().steps,
               "console_url" => "https://console.nimbus.invalid/",
               "docs_anchor" => "nimbus"
             }
    end

    test "takes no parameters", ctx do
      assert {:error, :invalid_params, _details} =
               route("home.provision.providers", %{"provider" => "nimbus"}, ctx)
    end
  end

  describe "the family on a provider that is not Hetzner" do
    test "connects, offers, creates, powers, reads back and deletes", ctx do
      assert {:ok, view} = connect(ctx)
      assert %{"provider" => "nimbus", "state" => "connected", "token" => "accepted"} = view
      assert {:ok, %{token: token}} = Ledger.read(ctx.home, "nimbus")
      assert token == FakeCloudProvider.token()
      refute File.exists?(Ledger.path(ctx.home, "hetzner"))

      assert {:ok, options} = route("home.provision.options", %{"provider" => "nimbus"}, ctx)
      assert options["sentence"] == "Recommended: Small 4 in Oslo, €12 a month."

      assert {:ok, job} = create(ctx)
      assert %{"status" => "completed", "result" => result} = finished(job, ctx)

      assert result == %{
               "server" => "fermix-general-" <> ref(ctx),
               "type" => "small-4",
               "location" => "osl1"
             }

      assert_received :code_opened

      assert {:ok, view} = route("home.provision.resources", %{}, ctx)
      assert %{"provider" => "nimbus", "state" => "created", "checked" => true} = view
      assert %{"type" => "small-4", "location" => "osl1"} = view["server"]

      # A resource's id is the provider's own, opaque, as a string.
      assert [_server, _firewall, _ip] = view["resources"]
      assert Enum.all?(view["resources"], &match?(%{"id" => "nb-" <> _}, &1))

      assert {:ok, job} = route("home.provision.power", %{"action" => "on"}, ctx)
      assert %{"status" => "completed"} = finished(job, ctx)

      assert {:ok, job} = route("home.provision.delete", %{}, ctx)
      assert %{"status" => "completed"} = finished(job, ctx)
      assert_received :code_withdrawn

      assert {:ok, %{"state" => "connected", "resources" => []}} =
               route("home.provision.resources", %{}, ctx)
    end

    test "every refusal names the provider in its own words", ctx do
      assert {:error, :unavailable, %{"sentence" => "Paste a Nimbus access key first."}} =
               route("home.provision.options", %{"provider" => "nimbus"}, ctx)

      assert {:error, :invalid_params, %{"field" => "token", "sentence" => sentence}} =
               route(
                 "home.provision.connect",
                 %{"provider" => "nimbus", "token" => "invented-wrong-token-0000"},
                 ctx
               )

      assert sentence ==
               "Nimbus does not accept this token, so paste a key that may create servers " <>
                 "from the Nimbus workspace you made for Fermix."

      {:ok, _view} = connect(ctx)

      assert {:error, :invalid_params, %{"field" => "location", "sentence" => sentence}} =
               route(
                 "home.provision.create",
                 %{"provider" => "nimbus", "type" => "small-4", "location" => "fsn1"},
                 ctx
               )

      assert sentence == "Fermix creates a server in Oslo or Lisbon."
    end

    test "a refusal the provider maps to a shared kind is kept in the ledger", ctx do
      {:ok, _view} = connect(ctx)
      FakeCloudProvider.fault(ctx.world, :create_server, :account_limit)

      assert {:ok, job} = create(ctx)

      assert %{"status" => "failed", "failure" => %{"sentence" => sentence}} = finished(job, ctx)
      assert sentence == "Nimbus limits new servers on this account."

      assert {:ok, %{"state" => "failed", "failure" => failure}} =
               route("home.provision.resources", %{}, ctx)

      assert %{"reason" => "account_limit", "sentence" => ^sentence} = failure
    end
  end

  describe "the provider a call names" do
    test "connect, options and create need one, and only one Fermix offers", ctx do
      for {method, params} <- [
            {"home.provision.connect", %{"token" => FakeCloudProvider.token()}},
            {"home.provision.options", %{}},
            {"home.provision.create", %{"type" => "small-4", "location" => "osl1"}}
          ],
          provider <- [:absent, "hetzner", 7] do
        params = if provider == :absent, do: params, else: Map.put(params, "provider", provider)

        assert {:error, :invalid_params, %{"field" => "provider"}} = route(method, params, ctx),
               "#{method} #{inspect(provider)}"
      end
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

      assert {:error, :unavailable, %{"sentence" => sentence}} = create(ctx)
      assert sentence == "Your server already exists, so delete it before creating another."
      assert {:ok, %{server: nil, ref: nil}} = Ledger.read(ctx.home, "nimbus")
    end
  end

  defp connect(ctx),
    do:
      route(
        "home.provision.connect",
        %{"provider" => "nimbus", "token" => FakeCloudProvider.token()},
        ctx
      )

  defp create(ctx),
    do:
      route(
        "home.provision.create",
        %{"provider" => "nimbus", "type" => "small-4", "location" => "osl1"},
        ctx
      )

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
