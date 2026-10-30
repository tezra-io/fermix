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
    assert view["instance"]["instance_id"] == "i-0aa11bb22cc33dd44"
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
      instance: %{
        "provider" => "aws",
        "instance_id" => "i-0aa11bb22cc33dd44",
        "region" => "eu-north-1",
        "account_id" => "481516234200"
      },
      snapshots: nil
    }
  end
end
