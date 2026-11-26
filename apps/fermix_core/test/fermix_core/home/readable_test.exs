defmodule FermixCore.Home.ReadableTest do
  # M97 §3.4, D16: an engine reads a home by the home's format, never by the
  # engine that wrote it.
  use ExUnit.Case, async: true

  alias FermixCore.Home.Archive.Manifest
  alias FermixCore.Home.Readable
  alias FermixCore.Memory.Repo
  alias FermixTestSupport.SafeRm

  describe "readable?/2" do
    test "a home of this engine's format or an older one is read, whichever engine wrote it" do
      for {format, writer} <- [{1, "0.9.0"}, {2, "4.12.3"}, {2, "99.0.0"}, {1, "latest"}] do
        assert Readable.readable?(%{home_format: format, engine_version: writer}, 2) == :ok
      end
    end

    test "a home of a newer format is refused by name, both formats said" do
      assert Readable.readable?(%{home_format: 3, engine_version: "0.1.0"}, 2) ==
               {:error, {:newer_home_format, 3, 2}}
    end

    # The engines before home formats wrote no `home_format`; each of them is
    # older than the first engine that writes one, so its home is format 1,
    # and no engine version is compared.
    test "a home that names no format is format 1, whatever engine version it names" do
      for writer <- ["0.17.0", "99.0.0", nil] do
        assert Readable.format(%{home_format: nil, engine_version: writer}) == 1
        assert Readable.readable?(%{home_format: nil, engine_version: writer}, 1) == :ok
      end
    end

    test "this engine reads by its own format, which a manifest it writes carries" do
      ours = Readable.home_format()
      assert is_integer(ours) and ours >= 1
      assert Readable.readable?(%{home_format: ours, engine_version: "99.0.0"}) == :ok

      assert Readable.readable?(%{home_format: ours + 1, engine_version: "0.1.0"}) ==
               {:error, {:newer_home_format, ours + 1, ours}}
    end
  end

  describe "reads?/2" do
    test "an engine that names a format reads every home at or below it" do
      reader = %{home_format: 2, engine_version: "4.1.0"}

      assert Readable.reads?(reader, %{home_format: 2, engine_version: "9.0.0"})
      assert Readable.reads?(reader, %{home_format: nil, engine_version: "9.0.0"})
      refute Readable.reads?(reader, %{home_format: 3, engine_version: "4.0.0"})
    end

    # Such an engine's own code compares engine versions: it refuses a home
    # any newer engine wrote, and one whose version does not parse.
    test "an engine from before formats reads only a home its own version or an older one wrote" do
      reader = %{home_format: nil, engine_version: "4.1.0"}

      for writer <- ["4.1.0", "4.0.9", "3.0.0"] do
        assert Readable.reads?(reader, %{home_format: 1, engine_version: writer}), writer
      end

      for writer <- ["4.1.1", "4.2.0", "latest", nil] do
        refute Readable.reads?(reader, %{home_format: 1, engine_version: writer}), inspect(writer)
      end

      refute Readable.reads?(%{home_format: nil, engine_version: "4.1"}, %{
               home_format: 1,
               engine_version: "4.0.0"
             })
    end
  end

  test "the refusal says what to do, and names no version" do
    sentence = Readable.refusal_sentence()
    assert sentence =~ "Update Fermix on this computer first"
    refute sentence =~ ~r/\d+\.\d+/
  end

  # The format is raised by hand, in the change that makes this engine write
  # what an engine at the current format cannot read (`Home.Readable`'s
  # moduledoc says when). So a new memory.db migration or a new manifest key
  # fails here until its author decides: when an engine at the current format
  # could not read a home that carries it, raise `@home_format`; either way,
  # add it to the lists below.
  describe "what the current home format was decided for" do
    @decided_format 1
    # 63 (M89 §05, the owner's trips) adds two tables an engine at this format
    # never reads and changes nothing it does, so the format stays.
    # 64 (M89 D10, where a trip or a day is) adds a nullable `near` to both trip
    # tables: an engine at this format selects and writes them by column name
    # and never names it, so it reads past it, and a row it makes has none.
    # 65 (M89 D13 B, the place words a stop waits on) adds one table an engine at
    # this format never reads; its rows go with their trip row by cascade. An
    # engine at this format that edits a waiting stop's place does not clear its
    # wait, so a newer engine's placer may later place it: an edge between two
    # engines on one home, not a home either cannot read, so the format stays.
    # 66 (M89, the town each near in force names) adds one table an engine at
    # this format never reads, keyed by the near's words and gone with its
    # trip by cascade. An engine at this format that changes a near leaves
    # the old words' row behind, which no near then matches and the next
    # newer engine's edit clears: the format stays.
    # 67 (M94 §09, the phone-call ledger) adds one table an engine at this
    # format never reads or writes, and changes nothing it does: the format
    # stays.
    # 68 (M94 §09, §12, the call ledger as it stands) rebuilds that table with
    # four nullable columns, a wider unique key and one more release reason,
    # every row kept, and an engine at this format never reads it: the format
    # stays.
    # 69 (M106 §5.1, a run's failure kind and tool timeline) adds one table an
    # engine at this format never reads; its rows go with their run by
    # cascade. `job_runs`, which that engine reads with `SELECT *`, is left as
    # it was, so every run row keeps the width it reads: the format stays.
    # 70 (M106 §5.3, a job's retry) adds one table an engine at this format
    # never reads; its rows go with their job by cascade. `scheduled_jobs`,
    # which that engine reads with `SELECT *`, is left as it was. A retry a
    # newer engine left is never run by that engine, which reads only a job's
    # next run, so the job waits for it: the format stays.
    # 71 (M106 §5.4, a job's heal) adds two tables an engine at this format
    # never reads; a heal goes with its job, and a heal's run with its run, by
    # cascade. `job_runs` and `scheduled_jobs` are left as they were. A heal a
    # newer engine opened is never sent by that engine, and its runs end in
    # their failure line as they always did: the format stays.
    # 72 (M106 §5.5, §5.9, a heal's diagnosis and verdict) adds columns to
    # `job_heals` only, a table an engine at this format never reads; every
    # heal row is kept as it was. `job_runs` and `scheduled_jobs` keep their
    # widths. A newer engine's raised limit or pause is a value in a column
    # that engine already reads, and a rerun is an ordinary manual run: the
    # format stays.
    # 73 (M106 §6, a run's tool tally and the tool a heal is about) adds a
    # column to `job_run_facts` and one to `job_heals`, tables that engine
    # reads by column name or not at all: its run read names the two facts it
    # knows, so it reads past the tally. `job_runs` and `scheduled_jobs` keep
    # their widths, and a run it writes has no tally, which only breaks a
    # newer engine's streak: the format stays.
    # 74 (M106 §5.7, D5, a proposal's version, the owner's answer to it and
    # the surface it came from, and the mark of an owner's write while a heal
    # run diagnoses, JOB-12) adds columns to `job_heals` only, a table an
    # engine at this format never reads; every heal row is kept as it was. `job_runs` and `scheduled_jobs`
    # keep their widths. A change the owner approved is a value in a column
    # that engine already reads, written as an owner's edit is: the format
    # stays.
    # 75 (M107, the active-hours index) adds a partial index on `messages`, a
    # table that engine reads and writes. SQLite keeps the index on every
    # write whichever engine makes it, and every read that engine runs returns
    # the rows it did: the format stays.
    # 76 (M106 §5.7, D5, stage S4b, a proposal's card: its token's digest, the
    # chat it went to, and the token while its send is pending) adds columns
    # and a unique index to `job_heals` only, a table an engine at this
    # format never reads; every heal row is kept as it was. `job_runs` and
    # `scheduled_jobs` keep their widths. A card that engine never sent is no
    # card it answers, and an answer a newer engine applied is a value in a
    # column it already reads: the format stays.
    @migrations Enum.to_list(1..39) ++ [41, 42, 43] ++ Enum.to_list(45..76)
    @manifest_keys ~w(created_at engine_version files format home_format home_root host links
                      primary_epoch)
    @entry_keys ~w(bytes mode path sha256)
    @link_keys ~w(path target)

    setup do
      tmp = SafeRm.make_tmp_dir!("readable")
      on_exit(fn -> SafeRm.rm_rf!(tmp) end)
      %{tmp: tmp}
    end

    test "the format is the one these lists were decided under" do
      assert Readable.home_format() == @decided_format,
             "the home format moved to #{Readable.home_format()}: set @decided_format to it " <>
               "and check the lists below still say what that format holds"
    end

    test "every memory.db migration was decided", %{tmp: tmp} do
      name = :"readable_guard_repo_#{System.unique_integer([:positive])}"
      db = Path.join(tmp, "memory.db")
      start_supervised!({Repo, name: name, enabled: true, database_path: db})

      assert {:ok, versions} = Repo.migration_versions(server: name)

      assert versions == @migrations,
             "memory.db's migrations are #{numbers(versions -- @migrations)} beyond, and " <>
               "#{numbers(@migrations -- versions)} short of, what home format " <>
               "#{@decided_format} was decided for. If an engine at that format could not " <>
               "read a home a new one ran on (a column it uses renamed, dropped or retyped, a " <>
               "constraint its writes break), raise @home_format in FermixCore.Home.Readable; " <>
               "then list the migration here."
    end

    test "every manifest key was decided" do
      files = [%{path: "config.toml", bytes: 1, sha256: String.duplicate("a", 64), mode: 0o600}]
      links = [%{path: "plugins/installed/notes/current", target: "1.0.0"}]
      header = %{primary_epoch: 2, home_root: "/home/invented/.fermix", host: "linux-x86_64"}
      manifest = header |> Manifest.new(files, links) |> Manifest.encode() |> Jason.decode!()

      decided = "home format #{@decided_format} was decided for"
      raise_it = "raise @home_format in FermixCore.Home.Readable if an older engine must read it"

      assert manifest |> Map.keys() |> Enum.sort() == @manifest_keys,
             "the manifest's keys are not the ones #{decided}: #{raise_it}"

      assert manifest["files"] |> hd() |> Map.keys() |> Enum.sort() == @entry_keys,
             "a manifest entry's keys are not the ones #{decided}: #{raise_it}"

      assert manifest["links"] |> hd() |> Map.keys() |> Enum.sort() == @link_keys,
             "a manifest link's keys are not the ones #{decided}: #{raise_it}"
    end
  end

  defp numbers(list), do: inspect(list, charlists: :as_lists)
end
