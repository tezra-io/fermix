defmodule FermixCore.Home.CandidatesTest do
  use ExUnit.Case, async: true

  alias FermixCore.Home.Candidates
  alias FermixTestSupport.SafeRm

  @now ~U[2031-05-04 10:00:00Z]

  setup do
    home = SafeRm.make_tmp_dir!("candidates")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    %{home: home}
  end

  test "holds a candidate under a fresh id, 0600, never showing its keys", %{home: home} do
    assert {:ok, []} = Candidates.list(home, @now)
    assert {:ok, record} = Candidates.add(home, attrs("north-box"), @now)
    assert "cand-" <> _hex = record.candidate_id
    assert record.expires_at == DateTime.add(@now, 24 * 3_600, :second)

    assert Bitwise.band(File.stat!(Candidates.path(home)).mode, 0o777) == 0o600
    assert {:ok, [^record]} = Candidates.list(home, @now)
    assert {:ok, ^record} = Candidates.fetch(home, record.candidate_id, @now)

    view = Candidates.view(record)
    refute Map.has_key?(view, "noise_pk")
    refute Map.has_key?(view, "recipient")
    refute Map.has_key?(view, "instance")
  end

  test "holds at most four, each for 24 hours", %{home: home} do
    for n <- 1..4, do: {:ok, _record} = Candidates.add(home, attrs("box-#{n}"), @now)
    assert {:error, :limit} = Candidates.add(home, attrs("box-5"), @now)

    later = DateTime.add(@now, 24 * 3_600, :second)
    assert {:ok, []} = Candidates.list(home, later)
    assert {:ok, _record} = Candidates.add(home, attrs("box-6"), later)

    assert {:error, {:unknown_candidate, "cand-0000"}} =
             Candidates.fetch(home, "cand-0000", later)
  end

  # Always On's move back: a candidate that enrolled through the window a
  # desktop opened to take the home back names that desktop, which is how
  # the server knows the move goes back and not to a server; any other names
  # none. The move's request carries it.
  test "a candidate a desktop's window enrolled names that desktop; any other none",
       %{home: home} do
    desktop = "6f1e2d3c-4b5a-4968-8778-695a4b3c2d1e"

    {:ok, back} =
      Candidates.add(home, Map.put(attrs("studio-mac"), :returning, desktop), @now)

    {:ok, server} = Candidates.add(home, attrs("north-box"), @now)

    assert back.returning == desktop
    assert server.returning == nil
    assert {:ok, [^back, ^server]} = Candidates.list(home, @now)
    assert {:ok, ^back} = back |> Candidates.encode() |> Candidates.decode()
    refute Map.has_key?(Candidates.view(back), "returning")
  end

  # Forget this server (Always On review M2): the owner drops one held
  # server; one no longer held is gone already.
  test "removes one held candidate, and an absent one is removed already", %{home: home} do
    {:ok, first} = Candidates.add(home, attrs("north-box"), @now)
    {:ok, second} = Candidates.add(home, attrs("south-box"), @now)

    assert :ok = Candidates.remove(home, first.candidate_id, @now)
    assert {:ok, [^second]} = Candidates.list(home, @now)
    assert :ok = Candidates.remove(home, first.candidate_id, @now)
    assert {:ok, [^second]} = Candidates.list(home, @now)
  end

  # A held server's 24 hours ran out (review M2): the list still names it
  # until the next write, which is how Always On tells the owner it lapsed.
  test "names a candidate whose 24 hours ran out until the list is written again",
       %{home: home} do
    {:ok, record} = Candidates.add(home, attrs("north-box"), @now)
    later = DateTime.add(@now, 24 * 3_600, :second)

    assert {:ok, []} = Candidates.lapsed(home, @now)
    assert {:ok, [^record]} = Candidates.lapsed(home, later)

    {:ok, _other} = Candidates.add(home, attrs("south-box"), later)
    assert {:ok, []} = Candidates.lapsed(home, later)
  end

  test "a file Fermix did not write is refused, not read", %{home: home} do
    File.mkdir_p!(Path.dirname(Candidates.path(home)))
    File.write!(Candidates.path(home), ~s({"v":1,"candidates":[{"name":"x"}]}))
    assert {:error, {:invalid_candidates, _file}} = Candidates.list(home, @now)
  end

  defp attrs(name) do
    %{
      name: name,
      os: "linux",
      arch: "aarch64",
      version: "9.9.9",
      node_id: String.duplicate("ab", 32),
      relays: [%{"url" => "https://eu1.relay.invalid/", "quic_port" => 7842}],
      noise_pk: :binary.copy(<<1>>, 32),
      recipient: :binary.copy(<<2>>, 32),
      snapshots: nil
    }
  end
end
