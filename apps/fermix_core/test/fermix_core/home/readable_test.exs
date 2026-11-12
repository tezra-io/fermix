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
    @migrations Enum.to_list(1..39) ++ [41, 42, 43] ++ Enum.to_list(45..61)
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
