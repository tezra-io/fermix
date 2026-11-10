defmodule FermixCore.Computers.RegistryTest do
  # M97 §3.2: what the home knows live of each connected computer.
  use ExUnit.Case, async: true

  alias FermixCore.Computers.Registry
  alias FermixCore.Computers.Store
  alias FermixTestSupport.SafeRm

  @studio "6f1e2d3c-4b5a-4968-8778-695a4b3c2d1e"
  @since ~U[2031-06-01 09:00:00Z]
  @ended ~U[2031-06-01 11:30:00Z]
  @offers [%{id: "files", state: :on, sentence: nil, detail: nil}]

  setup do
    home = SafeRm.make_tmp_dir!("computer_registry")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    name = :"computers_registry_#{System.unique_integer([:positive])}"
    test = self()

    start_supervised!(
      {Registry,
       name: name,
       home: home,
       clock: fn -> @ended end,
       status_changed: fn -> send(test, :computers_changed) && :ok end}
    )

    %{home: home, name: name}
  end

  defp session do
    pid = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> send(pid, :stop) end)
    pid
  end

  # Casts are in order: a call after them reads their effect.
  defp settled(name), do: :sys.get_state(name)

  test "a session starts offering nothing, then what it sent", %{name: name, home: home} do
    session = session()
    :ok = Registry.connected(name, @studio, %{since: @since, session: session})
    settled(name)

    assert %{@studio => %{offers: [], path: nil, since: @since}} = Registry.live(name)
    assert_receive :computers_changed

    :ok = Registry.offers(name, @studio, session, @offers, "0123456789abcdef")
    :ok = Registry.path(name, @studio, session, :relay)
    settled(name)

    assert %{@studio => %{offers: @offers, offers_rev: "0123456789abcdef", path: :relay}} =
             Registry.live(name)

    assert {:ok, %{@studio => %{offers: @offers}}} = Store.read_all(home)
  end

  test "a refused payload is nothing offered, kept as such", %{name: name, home: home} do
    session = session()
    :ok = Registry.connected(name, @studio, %{since: @since, session: session})
    :ok = Registry.offers(name, @studio, session, @offers, "0123456789abcdef")
    :ok = Registry.offers(name, @studio, session, [], nil)
    settled(name)

    assert %{@studio => %{offers: []}} = Registry.live(name)
    assert {:ok, %{@studio => %{offers: [], offers_rev: nil}}} = Store.read_all(home)
  end

  test "an older session's word is not the computer's", %{name: name} do
    old = session()
    new = session()
    :ok = Registry.connected(name, @studio, %{since: @since, session: old})
    :ok = Registry.connected(name, @studio, %{since: @ended, session: new})
    :ok = Registry.offers(name, @studio, old, @offers, "0123456789abcdef")
    :ok = Registry.disconnected(name, @studio, old)
    settled(name)

    assert %{@studio => %{offers: [], session: ^new, since: @ended}} = Registry.live(name)
  end

  test "the session's end records when the home last heard it", %{name: name, home: home} do
    session = session()
    :ok = Registry.connected(name, @studio, %{since: @since, session: session})
    :ok = Registry.disconnected(name, @studio, session)
    settled(name)

    assert Registry.live(name) == %{}
    assert {:ok, %{@studio => %{seen_at: @ended}}} = Store.read_all(home)
  end

  test "a session that ends with no word is let go all the same", %{name: name} do
    session = session()
    :ok = Registry.connected(name, @studio, %{since: @since, session: session})
    assert_receive :computers_changed

    send(session, :stop)
    # The end is told as a change, once the registry saw the session go.
    assert_receive :computers_changed
    assert Registry.live(name) == %{}
  end

  test "a registry that does not run lists nothing" do
    assert Registry.live(:computers_registry_absent) == %{}
  end
end
