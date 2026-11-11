defmodule FermixCore.ComputerUse.ServerControlTest do
  # M97 §8.7: the stretches Fermix on the server drove this computer's screen,
  # recorded where this computer's history recorder can read them.
  use ExUnit.Case, async: true

  alias FermixCore.ComputerUse.ServerControl
  alias FermixTestSupport.SafeRm

  setup do
    home = SafeRm.make_tmp_dir!("server_control")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    %{home: home}
  end

  test "a stretch opens and closes, an open one has no end", %{home: home} do
    first = ~U[2026-11-09 21:14:03Z]
    :ok = ServerControl.started(home, "cua_a", first)
    :ok = ServerControl.ended(home, "cua_a", ~U[2026-11-09 21:16:40Z], :closed)
    :ok = ServerControl.started(home, "cua_b", ~U[2026-11-09 22:00:00Z])

    assert {:ok,
            [
              %{
                seat: "cua_a",
                started_at: ^first,
                ended_at: ~U[2026-11-09 21:16:40Z],
                why: :closed
              },
              %{seat: "cua_b", ended_at: nil, why: nil}
            ]} = ServerControl.stretches(home)
  end

  test "nothing recorded is no stretch, and an unreadable line is skipped", %{home: home} do
    assert {:ok, []} = ServerControl.stretches(home)

    :ok = ServerControl.started(home, "cua_a", ~U[2026-11-09 21:14:03Z])
    File.write!(ServerControl.path(home), "not json\n", [:append])

    assert {:ok, [%{seat: "cua_a"}]} = ServerControl.stretches(home)
  end

  test "it holds no screen content: only times, the seat and a closed word", %{home: home} do
    :ok = ServerControl.started(home, "cua_a", ~U[2026-11-09 21:14:03Z])
    :ok = ServerControl.ended(home, "cua_a", ~U[2026-11-09 21:15:00Z], :stopped)

    for line <- home |> ServerControl.path() |> File.read!() |> String.split("\n", trim: true) do
      keys = line |> Jason.decode!() |> Map.keys() |> Enum.sort()
      assert keys in [~w(at e seat v), ~w(at e seat v why)]
    end
  end

  test "past its bound it keeps the newest lines", %{home: home} do
    at = ~U[2026-11-09 21:14:03Z]

    line =
      Jason.encode!(%{
        "v" => 1,
        "e" => "started",
        "at" => "2026-11-09T21:00:00Z",
        "seat" => "old"
      })

    File.mkdir_p!(Path.dirname(ServerControl.path(home)))
    File.write!(ServerControl.path(home), String.duplicate(line <> "\n", 2_000))

    :ok = ServerControl.started(home, "cua_new", at)

    lines = home |> ServerControl.path() |> File.read!() |> String.split("\n", trim: true)
    assert length(lines) == 1_000
    assert List.last(lines) =~ "cua_new"
  end
end
