defmodule FermixCore.Management.ComputerTest do
  # M97 §6.3, §7.4: the owner's read of what Fermix on its server did on
  # this computer, answered on the computer itself.
  use ExUnit.Case, async: true

  alias FermixCore.Computers.Journal
  alias FermixCore.Home.AlwaysOnRelease
  alias FermixCore.Management.Computer
  alias FermixCore.Management.Placement
  alias FermixCore.Management.Router
  alias FermixTestSupport.SafeRm

  @at ~U[2031-06-08 09:14:02.120Z]

  setup do
    home = SafeRm.make_tmp_dir!("management_computer")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    %{home: home}
  end

  defp route(params, opts) do
    request = %{
      request_id: "req-1",
      protocol_version: 2,
      method: "computer.journal.list",
      params: params
    }

    Router.route(request, opts)
  end

  test "it lists the journal, the newest first, a page at a time", %{home: home} do
    dir = Journal.dir(home)

    for n <- 1..3 do
      fields = %{
        id: "inv-#{n}",
        at: DateTime.add(@at, n, :second),
        capability: "system",
        op: "echo",
        target: "echo",
        origin: :chat,
        epoch: 3,
        turn_session: nil
      }

      :ok = Journal.append_started(dir, fields)
    end

    assert {:ok, %{"entries" => [newest], "more" => true}} =
             route(%{"limit" => 1}, operation_opts: [home: home])

    assert %{"id" => "inv-3", "status" => nil, "finished_at" => nil, "origin" => "chat"} = newest

    assert {:ok, %{"entries" => older, "more" => false}} =
             route(%{"before" => "inv-3"}, operation_opts: [home: home])

    assert Enum.map(older, & &1["id"]) == ["inv-2", "inv-1"]
  end

  test "a computer that never moved has no entries", %{home: home} do
    assert Computer.journal_list(%{}, home: home) == {:ok, %{"entries" => [], "more" => false}}
  end

  test "what it does not take is refused by field", %{home: home} do
    opts = [operation_opts: [home: home]]

    assert {:error, :invalid_params, %{"field" => "limit"}} = route(%{"limit" => 0}, opts)
    assert {:error, :invalid_params, %{"field" => "limit"}} = route(%{"limit" => 201}, opts)
    assert {:error, :invalid_params, %{"field" => "before"}} = route(%{"before" => "a b"}, opts)
    assert {:error, :invalid_params, %{"field" => "after"}} = route(%{"after" => "x"}, opts)
  end

  test "a journal it cannot read is said in a sentence", %{home: home} do
    File.mkdir_p!(Path.join(home, "device"))
    File.write!(Journal.dir(home), "not a directory")

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:error, :unavailable, %{"sentence" => sentence}} =
               Computer.journal_list(%{}, home: home)

      assert sentence =~ "could not be read"
    end)
  end

  test "it is this computer's: answered here, never by its server" do
    assert Placement.place("computer.journal.list", %{}) == :device
    assert Placement.place("computer_use.permissions.get", %{}) == :device
    refute Placement.served_forwarded?("computer.journal.list", %{})
  end

  test "it is gated with Always On", %{home: home} do
    assert "computer.journal.list" in AlwaysOnRelease.methods()

    assert {:error, :unavailable, %{"method" => "computer.journal.list"}} =
             route(%{}, operation_opts: [home: home], always_on: false)
  end
end
