defmodule FermixCore.Home.Provision.LedgerTest do
  # M75 lean v1 §4.3: the provisioner's one file, `device/provision/<host>.json`,
  # holds the host's API token and the resources Fermix created there, written
  # whole and owner-only, and read by the summary through `state/1`.
  use ExUnit.Case, async: true

  alias FermixCore.Home.DeviceLocal
  alias FermixCore.Home.Provision.Ledger
  alias FermixTestSupport.SafeRm

  @now ~U[2031-05-04 10:00:00Z]
  @token "invented-hetzner-token-6d1f0c9a2b7e4f3a"

  setup do
    home = SafeRm.make_tmp_dir!("provision-ledger")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    %{home: home}
  end

  test "the file lives on this machine, owner-only, in a folder of its own", %{home: home} do
    assert Ledger.path(home, "hetzner") ==
             Path.join([home, "device", "provision", "hetzner.json"])

    assert DeviceLocal.excluded?("device/provision/hetzner.json")

    assert {:ok, ledger} =
             Ledger.update(home, "hetzner", &{:ok, Ledger.connect(&1, @token, @now)})

    assert ledger.token == @token

    assert Bitwise.band(File.stat!(Ledger.path(home, "hetzner")).mode, 0o777) == 0o600

    assert Bitwise.band(File.stat!(Path.dirname(Ledger.path(home, "hetzner"))).mode, 0o777) ==
             0o700

    assert {:ok, ^ledger} = Ledger.read(home, "hetzner")
    assert File.ls!(Path.dirname(Ledger.path(home, "hetzner"))) == ["hetzner.json"]
  end

  test "an absent file is an empty ledger, and the summary says none", %{home: home} do
    assert {:ok, %{token: nil, server: nil, firewall: nil, primary_ips: []}} =
             Ledger.read(home, "hetzner")

    assert %{state: :none, token: :none, server: nil, failure: nil} = Ledger.state(home)
    refute File.exists?(Ledger.path(home, "hetzner"))
  end

  test "an update that answers an error writes nothing", %{home: home} do
    {:ok, _ledger} = Ledger.update(home, "hetzner", &{:ok, Ledger.connect(&1, @token, @now)})
    before = File.read!(Ledger.path(home, "hetzner"))

    assert {:error, :refused_here} =
             Ledger.update(home, "hetzner", fn ledger ->
               _changed = %{ledger | token: "another"}
               {:error, :refused_here}
             end)

    assert File.read!(Ledger.path(home, "hetzner")) == before
  end

  test "concurrent updates each land, none lost to another's read", %{home: home} do
    {:ok, _ledger} = Ledger.update(home, "hetzner", &{:ok, Ledger.connect(&1, @token, @now)})

    tasks =
      for n <- 1..20 do
        Task.async(fn ->
          Ledger.update(home, "hetzner", fn ledger ->
            ip = %{id: n, type: "ipv4", ip: "203.0.113.#{n}"}
            {:ok, %{ledger | primary_ips: [ip | ledger.primary_ips]}}
          end)
        end)
      end

    Enum.each(tasks, &({:ok, _ledger} = Task.await(&1, 10_000)))
    {:ok, ledger} = Ledger.read(home, "hetzner")
    assert ledger.primary_ips |> Enum.map(& &1.id) |> Enum.sort() == Enum.to_list(1..20)
  end

  test "a file that is not one this engine writes is refused by name", %{home: home} do
    File.mkdir_p!(Path.dirname(Ledger.path(home, "hetzner")))
    File.write!(Ledger.path(home, "hetzner"), ~s({"v": 1, "token": 5}))

    assert {:error, {:invalid_ledger, _path}} = Ledger.read(home, "hetzner")

    assert %{state: :unreadable, sentence: sentence} = Ledger.state(home)
    assert sentence =~ "could not read"
  end

  describe "state/1, what the summary reads" do
    test "connected, then creating from the first write until the server is created", %{
      home: home
    } do
      put!(home, &Ledger.connect(&1, @token, @now))
      assert %{state: :connected, token: :accepted} = Ledger.state(home)

      put!(home, &Ledger.begin_create(&1, "a3f9", server_facts()))
      assert %{state: :creating, server: nil} = Ledger.state(home)

      put!(
        home,
        &Ledger.put_firewall(&1, %{name: "fermix-general-a3f9", id: 1203, status: :created})
      )

      put!(home, &Ledger.put_server(&1, Map.merge(server_facts(), %{status: :requested})))
      assert %{state: :creating, server: %{status: :requested, id: nil}} = Ledger.state(home)

      put!(home, &Ledger.put_server(&1, created_server(:creating)))
      assert %{state: :creating, server: %{id: 61_839_204}} = Ledger.state(home)

      put!(home, &Ledger.put_server(&1, created_server(:created)))

      assert %{
               state: :created,
               server: %{name: "fermix-general-a3f9", type: "cpx22", location: "fsn1"}
             } = Ledger.state(home)
    end

    test "failed with its reason and sentence, until a new create begins", %{home: home} do
      put!(home, &Ledger.connect(&1, @token, @now))
      put!(home, &Ledger.begin_create(&1, "a3f9", server_facts()))

      put!(
        home,
        &Ledger.put_failure(&1, %{
          reason: "resource_unavailable",
          sentence: "Falkenstein has no CPX22 right now.",
          next_location: "nbg1",
          at: @now
        })
      )

      assert %{
               state: :failed,
               failure: %{
                 reason: "resource_unavailable",
                 sentence: "Falkenstein has no CPX22 right now.",
                 next_location: "nbg1",
                 at: @now
               }
             } = Ledger.state(home)

      put!(home, &Ledger.begin_create(&1, "b7c2", %{server_facts() | location: "nbg1"}))
      assert %{state: :creating, failure: nil} = Ledger.state(home)
    end

    test "deleting, gone, and connected again once everything is deleted", %{home: home} do
      put!(home, &Ledger.connect(&1, @token, @now))
      put!(home, &Ledger.begin_create(&1, "a3f9", server_facts()))
      put!(home, &Ledger.put_server(&1, created_server(:created)))

      put!(home, &Ledger.put_server(&1, created_server(:gone)))
      assert %{state: :gone} = Ledger.state(home)

      put!(home, &Ledger.put_server(&1, created_server(:deleting)))
      assert %{state: :deleting} = Ledger.state(home)

      put!(home, &Ledger.clear(&1))
      assert %{state: :connected, server: nil, failure: nil} = Ledger.state(home)
      {:ok, ledger} = Ledger.read(home, "hetzner")
      assert ledger.token == @token and ledger.ref == nil
    end

    test "a token Hetzner stopped accepting is said beside the state", %{home: home} do
      put!(home, &Ledger.connect(&1, @token, @now))
      put!(home, &Ledger.token_refused/1)
      assert %{state: :connected, token: :refused} = Ledger.state(home)

      put!(home, &Ledger.connect(&1, "invented-new-token", @now))
      assert %{token: :accepted} = Ledger.state(home)
    end

    test "never answers the token", %{home: home} do
      put!(home, &Ledger.connect(&1, @token, @now))
      refute inspect(Ledger.state(home)) =~ @token
    end
  end

  defp put!(home, transform) do
    {:ok, _ledger} = Ledger.update(home, "hetzner", &{:ok, transform.(&1)})
  end

  defp server_facts,
    do: %{name: "fermix-general-a3f9", type: "cpx22", location: "fsn1"}

  defp created_server(status) do
    Map.merge(server_facts(), %{
      id: 61_839_204,
      status: status,
      ipv4: "203.0.113.7",
      created_at: @now
    })
  end
end
