defmodule FermixCore.Home.Provision.HetznerTest do
  # M75 lean v1 §4.3 and L2: the Hetzner provisioner against the recorded
  # Hetzner Cloud API (`FermixTestSupport.HetznerStub`). Nothing leaves the
  # machine, no clock is waited on (the poll's pause is a function the test
  # owns), and every home is a temporary one.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias FermixCore.Home.Provision.FirstBoot
  alias FermixCore.Home.Provision.Hetzner
  alias FermixCore.Home.Provision.Ledger
  alias FermixTestSupport.HetznerStub
  alias FermixTestSupport.SafeRm

  @now ~U[2031-05-04 10:00:00Z]
  @code "fxenroll1.eyJ2IjoxLCJuYW1lIjoiaW52ZW50ZWQifQ"
  @request %{type: "cpx22", location: "fsn1", profile: "general"}

  setup do
    home = SafeRm.make_tmp_dir!("provision-hetzner")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    stub = HetznerStub.start!()
    test = self()

    opts = [
      req_options: HetznerStub.req_options(stub),
      now: fn -> @now end,
      sleep: fn ms -> send(test, {:slept, ms}) end,
      report: fn phase -> send(test, {:phase, phase}) end,
      open_code: fn ->
        send(test, {:code_opened, ledger!(home)})
        {:ok, @code}
      end,
      withdraw_code: fn ->
        send(test, :code_withdrawn)
        :ok
      end
    ]

    %{home: home, stub: stub, opts: opts}
  end

  describe "options/2, the L2 rule from the live API" do
    test "the cheapest x86 type with 4 GB in stock, first in Falkenstein, and the next size up",
         ctx do
      assert {:ok, options} = Hetzner.options(HetznerStub.token(), ctx.opts)

      assert options["recommended"] == %{"type" => "cpx22", "location" => "fsn1"}
      assert options["more_room"] == %{"type" => "cpx32", "location" => "fsn1"}
      assert options["currency"] == "EUR"

      assert options["locations"] == [
               %{"id" => "fsn1", "city" => "Falkenstein", "country" => "DE"},
               %{"id" => "nbg1", "city" => "Nuremberg", "country" => "DE"},
               %{"id" => "hel1", "city" => "Helsinki", "country" => "FI"}
             ]

      # Out of stock (CX23), under 4 GB (CPX12), Arm (CAX11), deprecated
      # (CX22) and outside the three locations (Ashburn) are not offered.
      offered = Enum.map(options["offers"], &{&1["type"], &1["location"]})

      assert offered == [
               {"cpx22", "fsn1"},
               {"cpx22", "nbg1"},
               {"cpx22", "hel1"},
               {"cpx32", "fsn1"},
               {"cpx32", "hel1"},
               {"ccx13", "fsn1"},
               {"ccx13", "nbg1"},
               {"ccx13", "hel1"}
             ]

      # Gross, with VAT as the account is billed, and the IPv4 address.
      assert hd(options["offers"]) == %{
               "type" => "cpx22",
               "description" => "CPX22",
               "cores" => 2,
               "memory_gb" => 4,
               "disk_gb" => 80,
               "dedicated" => false,
               "location" => "fsn1",
               "monthly" => "19.49",
               "ipv4_monthly" => "0.60",
               "total_monthly" => "20.09"
             }

      assert [
               {"GET", "/v1/server_types", _q, nil},
               {"GET", "/v1/pricing", _, nil},
               {"GET", "/v1/locations", _, nil}
             ] =
               HetznerStub.requests(ctx.stub)
    end

    test "a type sold out in Falkenstein is recommended in the next location in stock", ctx do
      types = stock(%{"cpx22" => %{"fsn1" => false}})
      HetznerStub.set(ctx.stub, :server_types, types)

      assert {:ok, options} = Hetzner.options(HetznerStub.token(), ctx.opts)
      assert options["recommended"] == %{"type" => "cpx22", "location" => "nbg1"}
      # The next size up, where the recommendation is or else where it is in stock.
      assert options["more_room"] == %{"type" => "cpx32", "location" => "fsn1"}
    end

    test "nothing in stock is no recommendation", ctx do
      types =
        stock(%{
          "cpx22" => %{"fsn1" => false, "nbg1" => false, "hel1" => false},
          "cpx32" => %{"fsn1" => false, "hel1" => false},
          "ccx13" => %{"fsn1" => false, "nbg1" => false, "hel1" => false}
        })

      HetznerStub.set(ctx.stub, :server_types, types)

      assert {:ok, %{"recommended" => nil, "more_room" => nil, "offers" => []}} =
               Hetzner.options(HetznerStub.token(), ctx.opts)
    end
  end

  describe "check_token/2" do
    test "reads the project and says whether it holds servers Fermix did not create", ctx do
      assert {:ok, %{other_servers: false}} = Hetzner.check_token(HetznerStub.token(), ctx.opts)

      assert [
               {"GET", "/v1/servers", %{"label_selector" => "!fermix", "per_page" => "1"}, nil},
               {"GET", "/v1/pricing", _, nil}
             ] =
               HetznerStub.requests(ctx.stub)

      seed_foreign_server(ctx.stub)
      assert {:ok, %{other_servers: true}} = Hetzner.check_token(HetznerStub.token(), ctx.opts)
    end

    test "a token Hetzner does not accept is refused", ctx do
      assert {:error, :unauthorized} = Hetzner.check_token("invented-wrong-token", ctx.opts)
    end
  end

  describe "create/3" do
    setup ctx, do: connect!(ctx)

    test "firewall first, then the server with the first boot and its code, then its start",
         ctx do
      log =
        capture_log(fn ->
          assert {:ok, server} = Hetzner.create(ctx.home, @request, ctx.opts)
          send(self(), {:server, server})
        end)

      assert_received {:server, %{status: :created, type: "cpx22", location: "fsn1"} = server}
      assert server.name =~ ~r/\Afermix-general-[0-9a-f]{4}\z/
      ref = String.slice(server.name, -4, 4)
      labels = %{"fermix" => "always-on", "fermix-profile" => "general", "fermix-ref" => ref}

      [types, locations, firewall, image, create | rest] = HetznerStub.requests(ctx.stub)
      assert {"GET", "/v1/server_types", %{"name" => "cpx22"}, nil} = types
      assert {"GET", "/v1/locations", _query, nil} = locations

      assert {"POST", "/v1/firewalls", %{},
              %{"name" => name, "labels" => ^labels, "rules" => [], "apply_to" => []}} = firewall

      assert name == server.name

      assert {"GET", "/v1/images",
              %{"type" => "system", "name" => "debian-13", "architecture" => "x86"}, nil} = image

      {:ok, user_data} = FirstBoot.user_data(@code)
      firewall_id = ledger!(ctx.home).firewall.id

      assert {"POST", "/v1/servers", %{},
              %{
                "name" => ^name,
                "server_type" => "cpx22",
                "location" => "fsn1",
                "image" => 161_547_269,
                "start_after_create" => true,
                "firewalls" => [%{"firewall" => ^firewall_id}],
                "public_net" => %{"enable_ipv4" => true, "enable_ipv6" => true},
                "labels" => ^labels,
                "user_data" => ^user_data
              } = body} = create

      refute Map.has_key?(body, "ssh_keys")

      # Both actions the create answered, polled until done, then the server.
      assert [
               {"GET", "/v1/actions/" <> _a, _, nil},
               {"GET", "/v1/actions/" <> _b, _, nil},
               {"GET", "/v1/actions/" <> _c, _, nil},
               {"GET", "/v1/actions/" <> _d, _, nil},
               {"GET", "/v1/servers/" <> _id, _, nil}
             ] = rest

      assert_received {:phase, "checking"}
      assert_received {:phase, "firewall"}
      assert_received {:phase, "server"}
      assert_received {:phase, "starting"}

      # The code is opened after the firewall stands, before the server exists.
      assert_received {:code_opened, %{firewall: %{status: :created}, server: nil}}
      refute_received :code_withdrawn

      ledger = ledger!(ctx.home)
      assert %{status: :created, power: "running", ipv4: "203.0.113." <> _} = ledger.server
      assert [%{type: "ipv4"}, %{type: "ipv6"}] = ledger.primary_ips
      assert ledger.ref == ref
      assert Ledger.state(ctx.home).state == :created

      # The root password Hetzner answers is read for nothing.
      password = HetznerStub.root_password()
      refute File.read!(Ledger.path(ctx.home, "hetzner")) =~ password
      refute inspect(server) =~ password
      refute log =~ password
    end

    test "an answer shaped otherwise fails loud, and never carries the root password", ctx do
      password = HetznerStub.root_password()

      HetznerStub.answer_with(ctx.stub, "POST", ~r"^/v1/servers$", 201, %{
        "server" => %{"id" => 61_839_204},
        "root_password" => password
      })

      failure =
        try do
          Hetzner.create(ctx.home, @request, ctx.opts)
        rescue
          error -> Exception.format(:error, error, __STACKTRACE__)
        end

      assert failure =~ "FunctionClauseError"
      refute failure =~ password
    end

    test "the ledger names the server before Hetzner is asked to create it", ctx do
      HetznerStub.fault(ctx.stub, "POST", ~r"^/v1/servers$", 500, "server_error")

      assert {:error, {:refused, 500, "server_error", _message}} =
               Hetzner.create(ctx.home, @request, ctx.opts)

      # Whether Hetzner made it is not known: it stays asked for, found again
      # by its labels, and its code stays open for it.
      assert %{status: :requested, id: nil, name: "fermix-general-" <> _} =
               ledger!(ctx.home).server

      refute_received :code_withdrawn
    end

    test "a read-only token is refused at the firewall, before anything costs money", ctx do
      HetznerStub.set(ctx.stub, :read_only, true)

      assert {:error, :forbidden} = Hetzner.create(ctx.home, @request, ctx.opts)

      refute Enum.any?(HetznerStub.requests(ctx.stub), &match?({"POST", "/v1/servers", _, _}, &1))
      refute_received {:code_opened, _ledger}
      assert %{firewall: nil, server: nil} = ledger!(ctx.home)
    end

    test "a type Hetzner says is sold out where asked names the next location in stock", ctx do
      HetznerStub.fault(ctx.stub, "POST", ~r"^/v1/servers$", 412, "resource_unavailable")

      assert {:error,
              {:unavailable,
               %{
                 type: "cpx22",
                 description: "CPX22",
                 location: "fsn1",
                 city: "Falkenstein",
                 next: "nbg1",
                 next_city: "Nuremberg"
               }}} = Hetzner.create(ctx.home, @request, ctx.opts)

      # Nothing was created, so the code is withdrawn; the firewall stays for
      # the next try, which reuses it and the name.
      assert_received :code_withdrawn
      ledger = ledger!(ctx.home)
      assert ledger.server == nil
      assert %{status: :created, id: firewall_id} = ledger.firewall

      assert {:ok, %{location: "nbg1", name: name}} =
               Hetzner.create(ctx.home, %{@request | location: "nbg1"}, ctx.opts)

      assert name == ledger.firewall.name
      assert ledger!(ctx.home).firewall.id == firewall_id

      firewalls =
        Enum.filter(HetznerStub.requests(ctx.stub), &match?({"POST", "/v1/firewalls", _, _}, &1))

      assert length(firewalls) == 1
    end

    test "a type out of stock where asked is refused before anything is created", ctx do
      HetznerStub.set(ctx.stub, :server_types, stock(%{"cpx22" => %{"fsn1" => false}}))

      assert {:error, {:unavailable, %{location: "fsn1", next: "nbg1"}}} =
               Hetzner.create(ctx.home, @request, ctx.opts)

      assert [{"GET", "/v1/server_types", _, nil}, {"GET", "/v1/locations", _, nil}] =
               HetznerStub.requests(ctx.stub)

      assert %{firewall: nil, ref: nil} = ledger!(ctx.home)
    end

    test "a type that is not x86 with 4 GB is refused", ctx do
      for type <- ["cax11", "cpx12", "cx22", "no-such-type"] do
        assert {:error, {:ineligible_type, ^type}} =
                 Hetzner.create(ctx.home, %{@request | type: type}, ctx.opts)
      end
    end

    test "the account's limit is refused in its own words", ctx do
      HetznerStub.fault(ctx.stub, "POST", ~r"^/v1/servers$", 403, "resource_limit_exceeded")
      assert {:error, :account_limit} = Hetzner.create(ctx.home, @request, ctx.opts)
      assert_received :code_withdrawn
    end

    test "a server that already exists is not created again", ctx do
      {:ok, _server} = Hetzner.create(ctx.home, @request, ctx.opts)
      assert {:error, :server_exists} = Hetzner.create(ctx.home, @request, ctx.opts)
    end

    test "an action Hetzner could not finish is said in Hetzner's words", ctx do
      HetznerStub.set(ctx.stub, :action_polls, 3)
      stub = ctx.stub

      opts =
        Keyword.put(ctx.opts, :sleep, fn _ms ->
          for {id, %{record: %{"command" => "create_server"}}} <- HetznerStub.world(stub).actions,
              do: HetznerStub.fail_action(stub, id, "server placement failed")
        end)

      assert {:error, {:action_failed, "create_server", "server placement failed"}} =
               Hetzner.create(ctx.home, @request, opts)

      assert %{status: :creating} = ledger!(ctx.home).server
    end

    test "polling an action stops at its bound", ctx do
      HetznerStub.set(ctx.stub, :action_polls, 1_000)

      assert {:error, {:action_timeout, "create_server"}} =
               Hetzner.create(ctx.home, @request, Keyword.put(ctx.opts, :max_polls, 3))

      for _n <- 1..3, do: assert_received({:slept, 2_000})
      refute_received {:slept, _ms}
    end

    test "a rate-limited poll waits and goes on", ctx do
      HetznerStub.fault(ctx.stub, "GET", ~r"^/v1/actions/", 429, "rate_limit_exceeded")

      assert {:ok, %{status: :created}} = Hetzner.create(ctx.home, @request, ctx.opts)
      assert_received {:slept, 10_000}
    end

    test "a rate-limited write is refused by name", ctx do
      HetznerStub.fault(ctx.stub, "POST", ~r"^/v1/firewalls$", 429, "rate_limit_exceeded")

      assert {:error, {:rate_limited, 1_999_999_999}} =
               Hetzner.create(ctx.home, @request, ctx.opts)
    end

    test "a name Hetzner already holds leaves the server asked for, to be found by its labels",
         ctx do
      # The shared pool sends a request again once when its connection closed
      # under it, so a create Hetzner carried out can come back as a name it
      # already holds.
      HetznerStub.lose_answer(ctx.stub, "POST", ~r"^/v1/servers$", 409, "uniqueness_error")

      assert {:error, {:refused, 409, "uniqueness_error", _message}} =
               Hetzner.create(ctx.home, @request, ctx.opts)

      assert %{status: :requested, id: nil} = ledger!(ctx.home).server
      refute_received :code_withdrawn
      assert {:ok, %{server: %{status: :created}}} = Hetzner.reconcile(ctx.home, ctx.opts)
    end

    test "Hetzner out of reach is said, and the asked-for firewall is kept", ctx do
      HetznerStub.transport_error(ctx.stub, "POST", ~r"^/v1/firewalls$", :timeout)

      assert {:error, {:unreachable, _reason}} = Hetzner.create(ctx.home, @request, ctx.opts)
      assert %{status: :requested, id: nil} = ledger!(ctx.home).firewall
    end
  end

  describe "power/3" do
    setup ctx, do: created!(connect!(ctx))

    test "turns the server on, and restarts it, waiting for each action", ctx do
      id = ledger!(ctx.home).server.id
      HetznerStub.server_status(ctx.stub, id, "off")

      assert :ok = Hetzner.power(ctx.home, :on, ctx.opts)
      assert :ok = Hetzner.power(ctx.home, :reset, ctx.opts)

      posts = for {"POST", path, _q, _b} <- HetznerStub.requests(ctx.stub), do: path
      assert "/v1/servers/#{id}/actions/poweron" in posts
      assert "/v1/servers/#{id}/actions/reset" in posts
      assert ledger!(ctx.home).server.power == "running"
    end
  end

  describe "reconcile/2" do
    setup ctx, do: created!(connect!(ctx))

    test "what was deleted outside Fermix is marked gone", ctx do
      ledger = ledger!(ctx.home)
      HetznerStub.delete_outside(ctx.stub, :servers, ledger.server.id)
      HetznerStub.delete_outside(ctx.stub, :firewalls, ledger.firewall.id)

      assert {:ok, %{server: %{status: :gone}, firewall: %{status: :gone}}} =
               Hetzner.reconcile(ctx.home, ctx.opts)

      assert Ledger.state(ctx.home).state == :gone
    end

    test "a server turned off in Hetzner is recorded off", ctx do
      HetznerStub.server_status(ctx.stub, ledger!(ctx.home).server.id, "off")

      assert {:ok, %{server: %{status: :created, power: "off", seen_at: @now}}} =
               Hetzner.reconcile(ctx.home, ctx.opts)
    end

    test "nothing is asked of Hetzner while an operation runs", ctx do
      before = length(HetznerStub.requests(ctx.stub))
      assert {:ok, _ledger} = Hetzner.reconcile(ctx.home, Keyword.put(ctx.opts, :running?, true))
      assert length(HetznerStub.requests(ctx.stub)) == before
    end
  end

  describe "a create whose answer was lost" do
    setup ctx, do: connect!(ctx)

    test "is found again by its labels and the ledger's id", ctx do
      HetznerStub.lose_answer(ctx.stub, "POST", ~r"^/v1/servers$", 500, "server_error")

      assert {:error, {:refused, 500, _code, _message}} =
               Hetzner.create(ctx.home, @request, ctx.opts)

      assert %{status: :requested, id: nil, name: name} = ledger!(ctx.home).server

      assert {:ok, ledger} = Hetzner.reconcile(ctx.home, ctx.opts)
      assert %{status: :created, name: ^name, id: id} = ledger.server
      assert is_integer(id)
      assert ledger.failure == nil

      ref = ledger.ref

      assert {"GET", "/v1/servers",
              %{
                "label_selector" => "fermix=always-on,fermix-profile=general,fermix-ref=" <> ^ref
              }, nil} =
               Enum.find(
                 HetznerStub.requests(ctx.stub),
                 &match?({"GET", "/v1/servers", %{"label_selector" => "fermix=" <> _}, _}, &1)
               )
    end

    test "that never reached Hetzner is dropped, its code withdrawn, and the create failed",
         ctx do
      HetznerStub.fault(ctx.stub, "POST", ~r"^/v1/servers$", 502, "server_error")
      {:error, _reason} = Hetzner.create(ctx.home, @request, ctx.opts)

      assert {:ok, %{server: nil, failure: %{reason: "interrupted"}}} =
               Hetzner.reconcile(ctx.home, ctx.opts)

      assert_received :code_withdrawn
      assert Ledger.state(ctx.home).state == :failed
    end
  end

  describe "delete/2" do
    setup ctx, do: created!(connect!(ctx))

    test "the server, then its addresses unless they went with it, then the firewall", ctx do
      ledger = ledger!(ctx.home)

      assert :ok = Hetzner.delete(ctx.home, ctx.opts)

      writes =
        for {method, path, _q, _b} <- HetznerStub.requests(ctx.stub), method == "DELETE", do: path

      assert writes == ["/v1/servers/#{ledger.server.id}", "/v1/firewalls/#{ledger.firewall.id}"]
      assert_received :code_withdrawn
      assert_received {:phase, "deleting"}

      assert %{server: nil, firewall: nil, primary_ips: [], ref: nil, token: token} =
               ledger!(ctx.home)

      assert token == HetznerStub.token()
      assert Ledger.state(ctx.home).state == :connected
      assert HetznerStub.world(ctx.stub).servers == %{}
    end

    test "an address that stays behind its server is deleted too", ctx do
      HetznerStub.set(ctx.stub, :auto_delete_ips, false)
      ips = Enum.map(ledger!(ctx.home).primary_ips, & &1.id)

      assert :ok = Hetzner.delete(ctx.home, ctx.opts)

      deleted =
        for {"DELETE", "/v1/primary_ips/" <> id, _q, _b} <- HetznerStub.requests(ctx.stub),
            do: String.to_integer(id)

      assert Enum.sort(deleted) == Enum.sort(ips)
      assert HetznerStub.world(ctx.stub).primary_ips == %{}
    end

    test "a firewall still in use as its server goes is tried again", ctx do
      HetznerStub.fault(ctx.stub, "DELETE", ~r"^/v1/firewalls/", 422, "resource_in_use")

      assert :ok = Hetzner.delete(ctx.home, ctx.opts)
      assert_received {:slept, 2_000}
      assert HetznerStub.world(ctx.stub).firewalls == %{}
    end

    test "a server already gone from Hetzner is simply dropped", ctx do
      HetznerStub.delete_outside(ctx.stub, :servers, ledger!(ctx.home).server.id)
      assert :ok = Hetzner.delete(ctx.home, ctx.opts)
      assert %{server: nil, firewall: nil} = ledger!(ctx.home)
    end
  end

  defp connect!(ctx) do
    {:ok, _ledger} =
      Ledger.update(ctx.home, "hetzner", &{:ok, Ledger.connect(&1, HetznerStub.token(), @now)})

    ctx
  end

  # The create's own pauses, phases and code are drained, so a test sees only
  # what its own step did.
  defp created!(ctx) do
    {:ok, _server} = Hetzner.create(ctx.home, @request, ctx.opts)
    flush()
    ctx
  end

  defp flush do
    receive do
      {kind, _value} when kind in [:slept, :phase, :code_opened] -> flush()
    after
      0 -> :ok
    end
  end

  defp ledger!(home) do
    {:ok, ledger} = Ledger.read(home, "hetzner")
    ledger
  end

  defp seed_foreign_server(stub) do
    HetznerStub.set(stub, :servers, %{
      7 =>
        Map.merge(HetznerStub.fixture("server.json"), %{
          "id" => 7,
          "name" => "web-1",
          "labels" => %{}
        })
    })
  end

  # The recorded types with the stock of some locations changed.
  defp stock(changes) do
    fixture = HetznerStub.fixture("server_types.json")

    types =
      for type <- fixture["server_types"] do
        case Map.fetch(changes, type["name"]) do
          {:ok, change} ->
            %{type | "locations" => Enum.map(type["locations"], &restock(&1, change))}

          :error ->
            type
        end
      end

    %{fixture | "server_types" => types}
  end

  defp restock(location, change),
    do: %{location | "available" => Map.get(change, location["name"], location["available"])}
end
