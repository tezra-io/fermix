defmodule FermixCore.Home.Provision.DriverTest do
  # M75 lean v1 §4.3: the shared driver (`Provision.Driver`) does everything
  # a create, a power action, a reconcile and a delete write to the ledger,
  # in order, around a provider's API primitives. Proved here on an invented
  # provider that is only those primitives (`FermixTestSupport.FakeCloudProvider`,
  # "Nimbus"), so the driver alone is what writes the ledger, labels what it
  # creates, polls with a bound, keeps a lost create findable, guards the
  # delete and keeps nothing of an answer but its facts.
  use ExUnit.Case, async: true

  alias FermixCore.Home.Provision.Driver
  alias FermixCore.Home.Provision.Ledger
  alias FermixTestSupport.FakeCloudProvider, as: Nimbus
  alias FermixTestSupport.SafeRm

  @now ~U[2031-05-04 10:00:00Z]
  @code "fxenroll1.eyJ2IjoxLCJuYW1lIjoiaW52ZW50ZWQifQ"
  @request %{type: "small-4", location: "osl1", profile: "general"}

  setup do
    home = SafeRm.make_tmp_dir!("provision-driver")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    world = Nimbus.start!()
    test = self()

    opts = [
      world: world,
      now: fn -> @now end,
      sleep: fn ms -> send(test, {:slept, ms}) end,
      report: fn phase -> send(test, {:phase, phase}) end,
      open_code: fn ->
        send(test, :code_opened)
        {:ok, @code}
      end,
      withdraw_code: fn ->
        send(test, :code_withdrawn)
        :ok
      end
    ]

    {:ok, _ledger} =
      Ledger.update(home, "nimbus", &{:ok, Ledger.connect(&1, Nimbus.token(), @now)})

    %{home: home, world: world, opts: opts}
  end

  describe "create" do
    test "writes the ledger before each call and after it, firewall first", ctx do
      test = self()
      spy = fn primitive -> send(test, {:at, primitive, ledger!(ctx.home)}) end

      assert {:ok, server} =
               Driver.create(Nimbus, ctx.home, @request, Keyword.put(ctx.opts, :spy, spy))

      assert [:server_type, :create_firewall, :system_image, :create_server, :get] =
               ctx.world |> Nimbus.calls() |> Enum.map(&elem(&1, 0))

      assert_received {:at, :create_firewall, %{firewall: %{status: :requested, id: nil}}}

      assert_received {:at, :create_server,
                       %{firewall: %{status: :created}, server: %{status: :requested, id: nil}}}

      ref = String.slice(server.name, -4, 4)
      labels = %{"fermix" => "always-on", "fermix-profile" => "general", "fermix-ref" => ref}

      assert {:create_firewall, %{name: name, labels: ^labels}} =
               Enum.find(Nimbus.calls(ctx.world), &(elem(&1, 0) == :create_firewall))

      assert name == server.name
      assert server.name =~ ~r/\Afermix-general-[0-9a-f]{4}\z/

      ledger = ledger!(ctx.home)
      assert %{status: :created, power: "running", type: "small-4", location: "osl1"} = server
      assert is_binary(ledger.server.id) and is_binary(ledger.firewall.id)
      assert [%{id: "nb-" <> _, type: "ipv4"}] = ledger.primary_ips

      for phase <- ~w(checking firewall server starting), do: assert_received({:phase, ^phase})
      assert_received :code_opened
    end

    test "keeps nothing of an answer but its facts", ctx do
      {:ok, _server} = Driver.create(Nimbus, ctx.home, @request, ctx.opts)

      refute File.read!(Ledger.path(ctx.home, "nimbus")) =~ "invented-nimbus-password"
    end

    test "a type the provider has no room for where asked names the next place in stock",
         ctx do
      assert {:error, {:unavailable, capacity}} =
               Driver.create(
                 Nimbus,
                 ctx.home,
                 %{@request | type: "large-8", location: "lis1"},
                 ctx.opts
               )

      assert %{city: "Lisbon", description: "Large 8", next: "osl1", next_city: "Oslo"} =
               capacity

      assert %{firewall: nil, ref: nil} = ledger!(ctx.home)
    end

    test "a type Fermix cannot use is refused before anything is written", ctx do
      assert {:error, {:ineligible_type, "tiny-2"}} =
               Driver.create(Nimbus, ctx.home, %{@request | type: "tiny-2"}, ctx.opts)

      assert {:error, {:ineligible_type, "no-such"}} =
               Driver.create(Nimbus, ctx.home, %{@request | type: "no-such"}, ctx.opts)
    end

    test "a server the provider refuses outright leaves nothing and closes its code", ctx do
      Nimbus.fault(ctx.world, :create_server, :account_limit)

      assert {:error, :account_limit} = Driver.create(Nimbus, ctx.home, @request, ctx.opts)
      assert %{server: nil, firewall: %{status: :created}} = ledger!(ctx.home)
      assert_received :code_withdrawn
    end

    test "no capacity when the server is asked for names the next place in stock", ctx do
      Nimbus.fault(ctx.world, :create_server, :no_capacity)

      assert {:error, {:unavailable, %{location: "osl1", next: "lis1"}}} =
               Driver.create(Nimbus, ctx.home, @request, ctx.opts)

      assert_received :code_withdrawn
    end

    test "an answer that did not come keeps the server asked for, found again by its labels",
         ctx do
      Nimbus.fault(ctx.world, :create_server, {:unknown, {:unreachable, "timeout"}})

      assert {:error, {:unreachable, "timeout"}} =
               Driver.create(Nimbus, ctx.home, @request, ctx.opts)

      assert %{server: %{status: :requested, id: nil}} = ledger!(ctx.home)
      refute_received :code_withdrawn

      # The provider did create it: the console shows it under its labels.
      ledger = ledger!(ctx.home)
      put_server_outside(ctx.world, ledger)

      assert {:ok, %{server: %{status: :created, id: "nb-outside"}}} =
               Driver.reconcile(Nimbus, ctx.home, ctx.opts)
    end

    test "a create that stopped after its firewall reuses that firewall and its ref", ctx do
      Nimbus.fault(ctx.world, :create_server, :account_limit)
      {:error, :account_limit} = Driver.create(Nimbus, ctx.home, @request, ctx.opts)
      first = ledger!(ctx.home)

      assert {:ok, _server} = Driver.create(Nimbus, ctx.home, @request, ctx.opts)

      assert ledger!(ctx.home).ref == first.ref
      assert ledger!(ctx.home).firewall.id == first.firewall.id

      assert 1 ==
               ctx.world |> Nimbus.calls() |> Enum.count(&(elem(&1, 0) == :create_firewall))
    end

    test "an action is polled with a bound, and one past it is said", ctx do
      Nimbus.set(ctx.world, :action_polls, 1_000)

      assert {:error, {:action_timeout, :create}} =
               Driver.create(Nimbus, ctx.home, @request, Keyword.put(ctx.opts, :max_polls, 3))

      for _n <- 1..3, do: assert_received({:slept, 2_000})
      refute_received {:slept, _ms}
    end

    test "a rate-limited poll waits longer and goes on", ctx do
      Nimbus.set(ctx.world, :action_polls, 1)
      Nimbus.fault(ctx.world, :action, {:rate_limited, nil})

      assert {:ok, %{status: :created}} = Driver.create(Nimbus, ctx.home, @request, ctx.opts)
      assert_received {:slept, 10_000}
    end
  end

  describe "power, reconcile and the token check" do
    setup ctx do
      {:ok, _server} = Driver.create(Nimbus, ctx.home, @request, ctx.opts)
      ctx
    end

    test "power waits for its action and records the power", ctx do
      assert :ok = Driver.power(Nimbus, ctx.home, :reset, ctx.opts)
      assert {:power, {_id, :reset}} = ctx.world |> Nimbus.calls() |> Enum.take(-2) |> hd()
      assert_received {:phase, "power"}
    end

    test "what was deleted outside Fermix is marked gone", ctx do
      ledger = ledger!(ctx.home)
      Nimbus.delete_outside(ctx.world, :servers, ledger.server.id)

      assert {:ok, %{server: %{status: :gone}, firewall: %{status: :created}}} =
               Driver.reconcile(Nimbus, ctx.home, ctx.opts)
    end

    test "a token of another account does not reach what Fermix created", ctx do
      ledger = ledger!(ctx.home)

      assert :ok = Driver.reaches(Nimbus, Nimbus.token(), ledger, ctx.opts)

      assert {:error, :other_project} =
               Driver.reaches(Nimbus, Nimbus.other_project_token(), ledger, ctx.opts)
    end
  end

  describe "delete" do
    setup ctx do
      {:ok, _server} = Driver.create(Nimbus, ctx.home, @request, ctx.opts)
      ctx
    end

    test "the server, then its addresses unless they went with it, then the firewall", ctx do
      ledger = ledger!(ctx.home)
      Nimbus.set(ctx.world, :in_use, 2)
      before = length(Nimbus.calls(ctx.world))

      assert :ok = Driver.delete(Nimbus, ctx.home, ctx.opts)

      deletes =
        for {:delete, {kind, _id}} <- Enum.drop(Nimbus.calls(ctx.world), before), do: kind

      assert deletes == [:server, :firewall, :firewall, :firewall]
      assert_received :code_withdrawn

      after_delete = ledger!(ctx.home)
      assert %{server: nil, firewall: nil, ref: nil, primary_ips: []} = after_delete
      assert after_delete.token == ledger.token
    end

    test "is refused for the server the home moved to, and with nothing created", ctx do
      {:ok, _ledger} = Ledger.update(ctx.home, "nimbus", &Ledger.begin_replace(&1, 5, @now))
      {:ok, _server} = Driver.create(Nimbus, ctx.home, @request, ctx.opts)
      {:ok, _ledger} = Ledger.update(ctx.home, "nimbus", &Ledger.moved(&1, 6, @now))

      assert {:error, :live_home} = Driver.delete(Nimbus, ctx.home, ctx.opts)
      assert :ok = Driver.delete_replaced(Nimbus, ctx.home, ctx.opts)
      assert %{replace: %{old: nil, deleted_at: @now}} = ledger!(ctx.home)

      {:ok, _ledger} = Ledger.update(ctx.home, "nimbus", &{:ok, Ledger.clear(&1)})
      assert {:error, :nothing_to_delete} = Driver.delete(Nimbus, ctx.home, ctx.opts)
    end
  end

  describe "options" do
    test "the L2 rule over the provider's catalog: cheapest in stock, then more room", ctx do
      assert {:ok, options} = Driver.options(Nimbus, Nimbus.token(), ctx.opts)

      assert options["recommended"] == %{"type" => "small-4", "location" => "osl1"}
      assert options["more_room"] == %{"type" => "large-8", "location" => "osl1"}

      # Under 4 GB (Tiny 2) and a place Fermix does not offer (Reykjavik) are not offered.
      assert Enum.map(options["offers"], &{&1["type"], &1["location"]}) ==
               [{"small-4", "osl1"}, {"small-4", "lis1"}, {"large-8", "osl1"}]

      assert hd(options["offers"])["total_monthly"] == "12.00"
      assert Enum.map(options["locations"], & &1["id"]) == ["osl1", "lis1"]
    end
  end

  defp ledger!(home) do
    {:ok, ledger} = Ledger.read(home, "nimbus")
    ledger
  end

  defp put_server_outside(world, ledger) do
    ref = ledger.ref
    labels = %{"fermix" => "always-on", "fermix-profile" => "general", "fermix-ref" => ref}

    server = %{
      id: "nb-outside",
      name: ledger.server.name,
      labels: labels,
      power: "running",
      ipv4: "198.51.100.9",
      created_at: @now,
      primary_ips: []
    }

    Agent.update(world, &put_in(&1.servers["nb-outside"], server))
  end
end
