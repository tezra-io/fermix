defmodule FermixCore.ComputerHistory.SurfacesTest do
  # M97 §8.3: whether history can surface is the home's fact, never this host's
  # platform: this machine records, a computer offers its history, or a home
  # with no recorder of its own holds notes.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias FermixCore.ComputerHistory
  alias FermixCore.Computers.Computer
  alias FermixCore.Computers.Facts
  alias FermixCore.Computers.Offers
  alias FermixCore.Computers.Switches
  alias FermixCore.Memory.Repo
  alias FermixTestSupport.SafeRm

  defp computer(state),
    do: %Computer{
      device_id: "studio-7f3a",
      name: "studio Mac",
      offers: [%{id: "history", state: state, sentence: nil, detail: nil}]
    }

  defp repo_with(notes) do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-ch-surfaces-#{unique}.db")
    repo = :"ch_surfaces_repo_#{unique}"
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})
    on_exit(fn -> Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &SafeRm.rm/1) end)

    for n <- 1..notes//1 do
      {:ok, _id} =
        Repo.computer_history_insert_memory(
          %{
            created_at: n,
            provenance_from_ts: n,
            provenance_to_ts: n,
            summary: "note #{n}",
            model: "m",
            event_count: 1,
            computer_id: "studio-7f3a"
          },
          server: repo
        )
    end

    repo
  end

  test "this machine recording is enough" do
    assert ComputerHistory.surfaces?(recording?: true, computers: [], recorder?: true)
  end

  test "a computer whose history is on is enough; one whose history is off is not" do
    repo = repo_with(0)
    base = [recording?: false, recorder?: false, repo: repo]

    assert ComputerHistory.surfaces?([computers: [computer(:on)]] ++ base)
    refute ComputerHistory.surfaces?([computers: [computer(:off)]] ++ base)
    refute ComputerHistory.surfaces?([computers: [computer(:unavailable)]] ++ base)
  end

  # M97 D27: one rule decides whether a computer's history reaches the home:
  # its recorder on, under its master switch and the review. The home reads it
  # from the offer the computer works out by that rule, so a computer whose
  # recorder is off never counts, whatever an earlier switch said.
  test "a computer contributes and surfaces exactly while its recorder and master are on" do
    repo = repo_with(0)

    for enabled <- [true, false], reviewed <- [true, false], recording <- [true, false] do
      facts =
        Facts.read(
          os: :macos,
          arch: "arm64",
          landlock: :not_asked,
          helpers: %{computer_use: false},
          sandbox_mode: :standard,
          screen: %{actions: [], input_methods: []},
          recording: recording
        )

      switches = Switches.only([:files_and_shell], enabled: enabled, reviewed: reviewed)

      computer = %Computer{
        device_id: "studio-7f3a",
        name: "studio Mac",
        offers: Offers.compute(Offers.modules(), switches, facts)
      }

      expected = enabled and reviewed and recording
      seen = inspect({enabled, reviewed, recording})

      assert {:ok, contributors} =
               ComputerHistory.contributors(repo: repo, recording?: false, computers: [computer])

      assert "studio-7f3a" in contributors == expected, seen

      assert ComputerHistory.surfaces?(
               recording?: false,
               recorder?: false,
               repo: repo,
               computers: [computer]
             ) == expected,
             seen
    end
  end

  test "a server holding notes surfaces them; a Mac that switched its own history off does not" do
    repo = repo_with(2)

    assert ComputerHistory.surfaces?(
             recording?: false,
             recorder?: false,
             computers: [],
             repo: repo
           )

    refute ComputerHistory.surfaces?(
             recording?: false,
             recorder?: true,
             computers: [],
             repo: repo
           )
  end

  test "a home whose store does not answer denies, and says so" do
    log =
      capture_log(fn ->
        refute ComputerHistory.surfaces?(
                 recording?: false,
                 recorder?: false,
                 computers: [],
                 repo: :ch_surfaces_absent_repo
               )
      end)

    assert log =~ "whether the home holds notes is unknown"
  end
end
