defmodule FermixCore.Home.Provision.LedgerTest do
  # M75 lean v1 §4.3: the provisioner's one file per provider,
  # `device/provision/<id>.json`, holds the provider's API token and the
  # resources Fermix created there, written whole and owner-only, and read by
  # the summary through `state/3`. Shared by every provider, so it is read
  # here through an invented one (`FermixTestSupport.FakeCloudProvider`).
  use ExUnit.Case, async: true

  alias FermixCore.Home.DeviceLocal
  alias FermixCore.Home.Provision.Ledger
  alias FermixTestSupport.FakeCloudProvider
  alias FermixTestSupport.SafeRm

  @now ~U[2031-05-04 10:00:00Z]
  @token "invented-nimbus-token-6d1f0c9a2b7e4f3a"

  setup do
    home = SafeRm.make_tmp_dir!("provision-ledger")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    %{home: home}
  end

  test "the file lives on this machine, owner-only, in a folder of its own", %{home: home} do
    assert Ledger.path(home, "nimbus") ==
             Path.join([home, "device", "provision", "nimbus.json"])

    assert DeviceLocal.excluded?("device/provision/nimbus.json")

    assert {:ok, ledger} =
             Ledger.update(home, "nimbus", &{:ok, Ledger.connect(&1, @token, @now)})

    assert ledger.token == @token

    assert Bitwise.band(File.stat!(Ledger.path(home, "nimbus")).mode, 0o777) == 0o600

    assert Bitwise.band(File.stat!(Path.dirname(Ledger.path(home, "nimbus"))).mode, 0o777) ==
             0o700

    assert {:ok, ^ledger} = Ledger.read(home, "nimbus")
    assert File.ls!(Path.dirname(Ledger.path(home, "nimbus"))) == ["nimbus.json"]
  end

  # A resource's id is its provider's own, opaque to Fermix: a string. A file
  # written before ids were strings holds Hetzner's numbers; each reads as
  # its string, and is written as one from then on.
  test "an id is an opaque string, and a number the file holds reads as its string",
       %{home: home} do
    file = Ledger.path(home, "nimbus")
    File.mkdir_p!(Path.dirname(file))

    File.write!(
      file,
      Jason.encode!(%{
        "v" => 1,
        "token" => @token,
        "ref" => "a3f9",
        "server" => %{
          "name" => "fermix-general-a3f9",
          "id" => 61_839_204,
          "status" => "created",
          "type" => "cpx22",
          "location" => "fsn1"
        },
        "firewall" => %{"name" => "fermix-general-a3f9", "id" => "fw-7", "status" => "created"},
        "primary_ips" => [%{"id" => 91, "type" => "ipv4", "ip" => "203.0.113.7"}]
      })
    )

    assert {:ok, ledger} = Ledger.read(home, "nimbus")
    assert %{server: %{id: "61839204"}, firewall: %{id: "fw-7"}} = ledger
    assert [%{id: "91"}] = ledger.primary_ips

    {:ok, _ledger} = Ledger.update(home, "nimbus", &{:ok, &1})
    assert %{"server" => %{"id" => "61839204"}} = file |> File.read!() |> Jason.decode!()

    for bad <- [0, -3, "", 1.5, %{}] do
      File.write!(
        file,
        Jason.encode!(%{
          "v" => 1,
          "firewall" => %{"name" => "f", "id" => bad, "status" => "created"},
          "primary_ips" => []
        })
      )

      assert {:error, {:invalid_ledger, _path}} = Ledger.read(home, "nimbus"), inspect(bad)
    end
  end

  test "an absent file is an empty ledger, and the summary says none", %{home: home} do
    assert {:ok, %{token: nil, server: nil, firewall: nil, primary_ips: []}} =
             Ledger.read(home, "nimbus")

    assert %{state: :none, token: :none, server: nil, failure: nil} =
             Ledger.state(home, FakeCloudProvider)

    refute File.exists?(Ledger.path(home, "nimbus"))
  end

  test "an update that answers an error writes nothing", %{home: home} do
    {:ok, _ledger} = Ledger.update(home, "nimbus", &{:ok, Ledger.connect(&1, @token, @now)})
    before = File.read!(Ledger.path(home, "nimbus"))

    assert {:error, :refused_here} =
             Ledger.update(home, "nimbus", fn ledger ->
               _changed = %{ledger | token: "another"}
               {:error, :refused_here}
             end)

    assert File.read!(Ledger.path(home, "nimbus")) == before
  end

  test "concurrent updates each land, none lost to another's read", %{home: home} do
    {:ok, _ledger} = Ledger.update(home, "nimbus", &{:ok, Ledger.connect(&1, @token, @now)})

    tasks =
      for n <- 1..20 do
        Task.async(fn ->
          Ledger.update(home, "nimbus", fn ledger ->
            ip = %{id: "ip-#{n}", type: "ipv4", ip: "203.0.113.#{n}"}
            {:ok, %{ledger | primary_ips: [ip | ledger.primary_ips]}}
          end)
        end)
      end

    Enum.each(tasks, &({:ok, _ledger} = Task.await(&1, 10_000)))
    {:ok, ledger} = Ledger.read(home, "nimbus")

    assert ledger.primary_ips |> Enum.map(& &1.id) |> Enum.sort() ==
             Enum.sort(for n <- 1..20, do: "ip-#{n}")
  end

  test "a file that is not one this engine writes is refused by name", %{home: home} do
    File.mkdir_p!(Path.dirname(Ledger.path(home, "nimbus")))
    File.write!(Ledger.path(home, "nimbus"), ~s({"v": 1, "token": 5}))

    assert {:error, {:invalid_ledger, _path}} = Ledger.read(home, "nimbus")

    assert %{state: :unreadable, sentence: sentence} = Ledger.state(home, FakeCloudProvider)
    assert sentence =~ "could not read"
  end

  describe "state/1, what the summary reads" do
    test "connected, then creating from the first write until the server is created", %{
      home: home
    } do
      put!(home, &Ledger.connect(&1, @token, @now))
      assert %{state: :connected, token: :accepted} = Ledger.state(home, FakeCloudProvider)

      put!(home, &Ledger.begin_create(&1, "a3f9", server_facts()))
      assert %{state: :creating, server: nil} = Ledger.state(home, FakeCloudProvider)

      put!(
        home,
        &Ledger.put_firewall(&1, %{name: "fermix-general-a3f9", id: "1203", status: :created})
      )

      put!(home, &Ledger.put_server(&1, Map.merge(server_facts(), %{status: :requested})))

      assert %{state: :creating, server: %{status: :requested, id: nil}} =
               Ledger.state(home, FakeCloudProvider)

      put!(home, &Ledger.put_server(&1, created_server(:creating)))

      assert %{state: :creating, server: %{id: "61839204"}} =
               Ledger.state(home, FakeCloudProvider)

      put!(home, &Ledger.put_server(&1, created_server(:created)))

      assert %{
               state: :created,
               server: %{name: "fermix-general-a3f9", type: "cpx22", location: "fsn1"}
             } = Ledger.state(home, FakeCloudProvider)
    end

    test "failed with its reason and sentence, until a new create begins", %{home: home} do
      put!(home, &Ledger.connect(&1, @token, @now))
      put!(home, &Ledger.begin_create(&1, "a3f9", server_facts()))

      put!(
        home,
        &Ledger.put_failure(&1, %{
          reason: "resource_unavailable",
          sentence: "Oslo has no Small 4 right now.",
          next_location: "nbg1",
          at: @now
        })
      )

      assert %{
               state: :failed,
               failure: %{
                 reason: "resource_unavailable",
                 sentence: "Oslo has no Small 4 right now.",
                 next_location: "nbg1",
                 at: @now
               }
             } = Ledger.state(home, FakeCloudProvider)

      put!(home, &Ledger.begin_create(&1, "b7c2", %{server_facts() | location: "nbg1"}))
      assert %{state: :creating, failure: nil} = Ledger.state(home, FakeCloudProvider)
    end

    test "deleting, gone, and connected again once everything is deleted", %{home: home} do
      put!(home, &Ledger.connect(&1, @token, @now))
      put!(home, &Ledger.begin_create(&1, "a3f9", server_facts()))
      put!(home, &Ledger.put_server(&1, created_server(:created)))

      put!(home, &Ledger.put_server(&1, created_server(:gone)))
      assert %{state: :gone} = Ledger.state(home, FakeCloudProvider)

      put!(home, &Ledger.put_server(&1, created_server(:deleting)))
      assert %{state: :deleting} = Ledger.state(home, FakeCloudProvider)

      put!(home, &Ledger.clear(&1))

      assert %{state: :connected, server: nil, failure: nil} =
               Ledger.state(home, FakeCloudProvider)

      {:ok, ledger} = Ledger.read(home, "nimbus")
      assert ledger.token == @token and ledger.ref == nil
    end

    test "a token its provider stopped accepting is said beside the state", %{home: home} do
      put!(home, &Ledger.connect(&1, @token, @now))
      put!(home, &Ledger.token_refused/1)
      assert %{state: :connected, token: :refused} = Ledger.state(home, FakeCloudProvider)

      put!(home, &Ledger.connect(&1, "invented-new-token", @now))
      assert %{token: :accepted} = Ledger.state(home, FakeCloudProvider)
    end

    test "never answers the token", %{home: home} do
      put!(home, &Ledger.connect(&1, @token, @now))
      refute inspect(Ledger.state(home, FakeCloudProvider)) =~ @token
    end
  end

  # M75 lean v1 §4.3, §7 `on` Details "Replace the server": a linked desktop
  # creates a new server for the home, the old one keeps the home until the
  # move to the new one is done, and only then is the old one deleted.
  describe "a replace" do
    setup %{home: home} do
      put!(home, &Ledger.connect(&1, @token, @now))
      put!(home, &Ledger.begin_create(&1, "a3f9", server_facts()))
      put!(home, &Ledger.put_server(&1, created_server(:created)))
      put!(home, &Ledger.put_primary_ips(&1, [%{id: "91", type: "ipv4", ip: "203.0.113.7"}]))
      :ok
    end

    test "sets the server it replaces aside, and the new one is created in its place", %{
      home: home
    } do
      {:ok, ledger} = Ledger.read(home, "nimbus")
      assert Ledger.replacing(ledger) == :begin

      {:ok, _ledger} = Ledger.update(home, "nimbus", &Ledger.begin_replace(&1, 5, @now))
      {:ok, ledger} = Ledger.read(home, "nimbus")

      assert %{ref: nil, server: nil, firewall: nil, primary_ips: [], failure: nil} = ledger
      assert Ledger.replaced_ref(ledger) == "a3f9"

      assert %{from_epoch: 5, started_at: @now, old: %{ref: "a3f9", server: %{id: "61839204"}}} =
               ledger.replace

      assert %{
               state: :connected,
               server: nil,
               replace: %{state: :creating, current: :old, old: %{name: "fermix-general-a3f9"}}
             } = Ledger.state(home, FakeCloudProvider)

      # A create that had not begun its new server goes on with it.
      assert Ledger.replacing(ledger) == :continue
      assert {:ok, ^ledger} = Ledger.begin_replace(ledger, 9, @now)
    end

    test "creating, waiting, moving, deleting the old one, done", %{home: home} do
      begin_replace!(home)
      put!(home, &Ledger.begin_create(&1, "b7c2", new_facts()))

      assert %{replace: %{state: :creating, current: :old}} =
               Ledger.state(home, FakeCloudProvider)

      put!(home, &Ledger.put_server(&1, new_server(:created)))

      assert %{state: :created, server: %{name: "fermix-general-b7c2"}, replace: replace} =
               Ledger.state(home, FakeCloudProvider)

      assert %{state: :waiting, current: :old, old: %{name: "fermix-general-a3f9"}} = replace

      {:ok, _ledger} =
        Ledger.update(home, "nimbus", &Ledger.move_started(&1, "cand-b7c2", @now))

      assert %{replace: %{state: :moving, current: :old}} = Ledger.state(home, FakeCloudProvider)
      {:ok, ledger} = Ledger.read(home, "nimbus")
      assert ledger.replace.candidate_id == "cand-b7c2"
      assert {:error, :live_home} = Ledger.retired(ledger)

      {:ok, _ledger} = Ledger.update(home, "nimbus", &Ledger.moved(&1, 6, @now))

      assert %{replace: %{state: :deleting, current: :new}} =
               Ledger.state(home, FakeCloudProvider)

      {:ok, ledger} = Ledger.read(home, "nimbus")
      assert {:ok, %{server: %{name: "fermix-general-a3f9"}}} = Ledger.retired(ledger)

      put!(home, &Ledger.replaced_deleted(&1, @now))

      assert %{state: :created, replace: %{state: :done, current: :new, old: nil}} =
               Ledger.state(home, FakeCloudProvider)

      {:ok, ledger} = Ledger.read(home, "nimbus")
      assert {:error, :nothing_to_delete} = Ledger.retired(ledger)
      # The new server is the one the home lives on, so it can be replaced in turn.
      assert Ledger.replacing(ledger) == :begin
    end

    test "failed with its reason: the new server's create stopped, or the old one's delete", %{
      home: home
    } do
      begin_replace!(home)
      put!(home, &Ledger.begin_create(&1, "b7c2", new_facts()))
      put!(home, &Ledger.put_failure(&1, failure("account_limit")))

      assert %{
               state: :failed,
               replace: %{state: :failed, current: :old, failure: %{reason: "account_limit"}}
             } = Ledger.state(home, FakeCloudProvider)

      put!(home, &Ledger.begin_create(&1, "b7c2", new_facts()))
      put!(home, &Ledger.put_server(&1, new_server(:created)))
      {:ok, _ledger} = Ledger.update(home, "nimbus", &Ledger.moved(&1, 6, @now))
      put!(home, &Ledger.put_replace_failure(&1, failure("unreachable")))

      assert %{replace: %{state: :failed, current: :new, failure: %{reason: "unreachable"}}} =
               Ledger.state(home, FakeCloudProvider)

      {:ok, ledger} = Ledger.read(home, "nimbus")
      assert Ledger.replacing(ledger) == {:error, :old_server_remains}
      assert {:ok, %{ref: "a3f9"}} = Ledger.retired(ledger)
    end

    test "a new server deleted at its provider before the move is a failed replace", %{home: home} do
      begin_replace!(home)
      put!(home, &Ledger.begin_create(&1, "b7c2", new_facts()))
      put!(home, &Ledger.put_server(&1, new_server(:gone)))

      assert %{state: :gone, replace: %{state: :failed, current: :old, failure: failure}} =
               Ledger.state(home, FakeCloudProvider)

      assert failure.reason == "gone"

      assert failure.sentence ==
               "Your new server was deleted in Nimbus, so replace the server again."
    end

    test "cancelling the new one gives the ledger back the server it would have replaced", %{
      home: home
    } do
      {:ok, before} = Ledger.read(home, "nimbus")
      begin_replace!(home)
      put!(home, &Ledger.begin_create(&1, "b7c2", new_facts()))
      put!(home, &Ledger.put_server(&1, new_server(:deleting)))

      assert %{state: :deleting, replace: %{state: :cancelling, current: :old}} =
               Ledger.state(home, FakeCloudProvider)

      put!(home, &Ledger.clear/1)
      assert {:ok, ^before} = Ledger.read(home, "nimbus")
      assert %{state: :created, replace: nil} = Ledger.state(home, FakeCloudProvider)
    end

    test "no second replace while one waits, moves or leaves its old server", %{home: home} do
      begin_replace!(home)
      put!(home, &Ledger.begin_create(&1, "b7c2", new_facts()))
      put!(home, &Ledger.put_server(&1, new_server(:created)))
      {:ok, ledger} = Ledger.read(home, "nimbus")
      assert Ledger.replacing(ledger) == {:error, :replacement_exists}
      assert {:error, :replacement_exists} = Ledger.begin_replace(ledger, 5, @now)

      {:ok, moving} = Ledger.move_started(ledger, "cand-b7c2", @now)
      assert Ledger.replacing(moving) == {:error, :replace_moving}

      assert Ledger.replacing(Ledger.empty()) == {:error, :not_primary}
    end

    test "the desktop's sight of the server's epoch says when the move is done, or undone", %{
      home: home
    } do
      begin_replace!(home)
      put!(home, &Ledger.begin_create(&1, "b7c2", new_facts()))
      put!(home, &Ledger.put_server(&1, new_server(:created)))
      {:ok, waiting} = Ledger.read(home, "nimbus")

      # The old server still answering, before or after a move it undid.
      assert Ledger.replace_due(waiting, 5) == :none
      assert Ledger.replace_due(waiting, 6) == :clean_up
      {:ok, moving} = Ledger.move_started(waiting, "cand-b7c2", @now)
      assert Ledger.replace_due(moving, 5) == :undone
      assert {:ok, %{replace: %{move_started_at: nil}}} = Ledger.move_undone(moving)
      assert {:error, :not_moved} = Ledger.moved(moving, 5, @now)

      {:ok, moved} = Ledger.moved(moving, 6, @now)
      # Seen again: still due, so a delete a restart cut short is carried on.
      assert Ledger.replace_due(moved, 6) == :clean_up
      assert {:ok, ^moved} = Ledger.moved(moved, 7, ~U[2031-05-04 11:00:00Z])

      failed = Ledger.put_replace_failure(moved, failure("unreachable"))
      assert Ledger.replace_due(failed, 6) == :none
      assert Ledger.replace_due(Ledger.replaced_deleted(moved, @now), 6) == :none
      assert Ledger.replace_due(Ledger.empty(), 6) == :none
    end
  end

  defp begin_replace!(home) do
    {:ok, _ledger} = Ledger.update(home, "nimbus", &Ledger.begin_replace(&1, 5, @now))
  end

  defp new_facts, do: %{name: "fermix-general-b7c2", type: "cpx32", location: "nbg1"}

  defp new_server(status) do
    Map.merge(new_facts(), %{
      id: "61839377",
      status: status,
      ipv4: "203.0.113.9",
      created_at: @now
    })
  end

  defp failure(reason),
    do: %{reason: reason, sentence: "Invented sentence.", next_location: nil, at: @now}

  defp put!(home, transform) do
    {:ok, _ledger} = Ledger.update(home, "nimbus", &{:ok, transform.(&1)})
  end

  defp server_facts,
    do: %{name: "fermix-general-a3f9", type: "cpx22", location: "fsn1"}

  defp created_server(status) do
    Map.merge(server_facts(), %{
      id: "61839204",
      status: status,
      ipv4: "203.0.113.7",
      created_at: @now
    })
  end
end
