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

  # M97 §8.7: the server's browser work on this computer is marked the same
  # way, in a record of its own read by the same reader, so each record keeps
  # one writer.
  test "the browser's stretches are read with the screen's, from a record of their own",
       %{home: home} do
    :ok = ServerControl.started(home, "cua_a", ~U[2026-11-09 21:00:00Z])
    :ok = ServerControl.ended(home, "cua_a", ~U[2026-11-09 21:05:00Z], :closed)
    :ok = ServerControl.browser_started(home, ~U[2026-11-09 21:02:00Z])
    :ok = ServerControl.browser_ended(home, ~U[2026-11-09 21:10:00Z], :switched_off)
    :ok = ServerControl.browser_started(home, ~U[2026-11-09 22:00:00Z])

    assert {:ok,
            [
              %{seat: "cua_a", ended_at: ~U[2026-11-09 21:05:00Z], why: :closed},
              %{
                seat: "browser",
                started_at: ~U[2026-11-09 21:02:00Z],
                ended_at: ~U[2026-11-09 21:10:00Z],
                why: :switched_off
              },
              %{seat: "browser", started_at: ~U[2026-11-09 22:00:00Z], ended_at: nil}
            ]} = ServerControl.stretches(home)

    refute File.read!(ServerControl.path(home)) =~ "browser"
    assert {:ok, true} = ServerControl.browser_open?(home)
  end

  test "the browser's record holds only times, its word and a closed word, 0600",
       %{home: home} do
    assert {:ok, false} = ServerControl.browser_open?(home)
    :ok = ServerControl.browser_started(home, ~U[2026-11-09 21:14:03Z])
    :ok = ServerControl.browser_ended(home, ~U[2026-11-09 21:15:00Z], :closed)
    assert {:ok, false} = ServerControl.browser_open?(home)

    path = ServerControl.browser_path(home)
    assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600

    for line <- path |> File.read!() |> String.split("\n", trim: true) do
      keys = line |> Jason.decode!() |> Map.keys() |> Enum.sort()
      assert keys in [~w(at e seat v), ~w(at e seat v why)]
    end
  end

  test "the browser's record is bounded as the screen's is", %{home: home} do
    line =
      Jason.encode!(%{
        "v" => 1,
        "e" => "ended",
        "at" => "2026-11-09T21:00:00Z",
        "seat" => "browser",
        "why" => "closed"
      })

    File.mkdir_p!(Path.dirname(ServerControl.browser_path(home)))
    File.write!(ServerControl.browser_path(home), String.duplicate(line <> "\n", 2_000))

    :ok = ServerControl.browser_started(home, ~U[2026-11-09 21:14:03Z])

    lines = home |> ServerControl.browser_path() |> File.read!() |> String.split("\n", trim: true)
    assert length(lines) == 1_000
    assert List.last(lines) =~ ~s("e":"started")
  end
end
