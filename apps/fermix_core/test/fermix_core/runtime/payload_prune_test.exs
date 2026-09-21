defmodule FermixCore.Runtime.PayloadPruneTest do
  @moduledoc """
  The bounded cleanup of superseded Burrito payload directories.

  Naming each payload directory after the payload's digest is what stops an
  upgrade reusing the previous engine, and it is also what makes the
  directories accumulate: one per build rather than one forever. This is the
  other half of that change, and the dangerous half -- a payload removed from
  under a live daemon is a process that dies on its next lazy module load,
  which is worse than the staleness being fixed and much harder to attribute.
  """

  use ExUnit.Case, async: true

  alias FermixCore.Runtime.PayloadPrune
  alias FermixTestSupport.SafeRm

  setup do
    base = SafeRm.make_tmp_dir!("payload_prune")
    on_exit(fn -> SafeRm.rm_rf!(base) end)
    %{base: base}
  end

  # The layout measured on a real install: an extraction is a directory inside
  # the `.burrito` base carrying Burrito's own `_metadata.json` marker.
  defp payload(base, name, minutes_old) do
    directory = Path.join(base, name)
    File.mkdir_p!(Path.join(directory, "releases"))
    File.write!(Path.join(directory, "_metadata.json"), "{}")

    :ok = File.touch!(directory, System.os_time(:second) - minutes_old * 60)
    directory
  end

  defp names(paths), do: paths |> Enum.map(&Path.basename/1) |> Enum.sort()

  describe "run/3" do
    test "the directory in use is never removed, however old it is", context do
      in_use = payload(context.base, "build-a+k", 900)
      payload(context.base, "build-b+k", 1)

      assert {:ok, report} = PayloadPrune.run(context.base, in_use, keep: 0)

      assert File.dir?(in_use)
      refute in_use in report.removed
    end

    test "superseded payloads are removed and named in the report", context do
      in_use = payload(context.base, "build-new+k", 0)
      old = payload(context.base, "build-old+k", 500)

      assert {:ok, report} = PayloadPrune.run(context.base, in_use, keep: 0)

      assert names(report.removed) == ["build-old+k"]
      refute File.dir?(old)
    end

    test "the newest superseded payloads are kept, to survive a rollback", context do
      in_use = payload(context.base, "build-d+k", 0)
      payload(context.base, "build-c+k", 10)
      payload(context.base, "build-b+k", 20)
      payload(context.base, "build-a+k", 30)

      assert {:ok, report} = PayloadPrune.run(context.base, in_use, keep: 2)

      assert names(report.removed) == ["build-a+k"]
      assert File.dir?(Path.join(context.base, "build-c+k"))
      assert File.dir?(Path.join(context.base, "build-b+k"))
    end

    test "no more than the cap are removed in one run, and the rest are reported",
         context do
      in_use = payload(context.base, "build-now+k", 0)
      for n <- 1..9, do: payload(context.base, "build-#{n}+k", 100 + n)

      assert {:ok, report} = PayloadPrune.run(context.base, in_use, keep: 0, max_removals: 3)

      assert length(report.removed) == 3
      assert report.deferred == 6
    end

    # The oldest first, so repeated runs converge instead of churning the same
    # few directories.
    test "the cap spends itself on the oldest first", context do
      in_use = payload(context.base, "build-now+k", 0)
      for n <- 1..4, do: payload(context.base, "build-#{n}+k", 100 + n)

      assert {:ok, report} = PayloadPrune.run(context.base, in_use, keep: 0, max_removals: 2)

      assert names(report.removed) == ["build-3+k", "build-4+k"]
    end

    # Before the keying, every build extracted into <base>/.burrito directly.
    # The owner still has one of those from 13:28 that served every package
    # installed after it. Nothing will ever choose it again, which is the fix --
    # but nothing removed it either, so it would sit there forever. Once this
    # process is running from a keyed directory, that one is provably not in
    # use, because the only thing that ever ran from it was an engine this
    # launch replaced.
    test "the legacy unkeyed extraction is removed like any other superseded one",
         context do
      in_use = payload(context.base, "build-new+k", 0)
      legacy = Path.join(context.base, "fermix_linux_package_erts-16.3_0.10.5")
      File.mkdir_p!(legacy)
      File.write!(Path.join(legacy, "_metadata.json"), "{}")

      assert {:ok, report} = PayloadPrune.run(context.base, in_use, keep: 0)

      assert legacy in report.removed
      refute File.dir?(legacy)
    end

    # It is the oldest thing in the tree, so a keep would never save it, but it
    # must not consume the removal budget ahead of directories that cost more.
    test "the legacy extraction counts against the same bound as the rest", context do
      in_use = payload(context.base, "build-new+k", 0)
      old = Path.join(context.base, "fermix_linux_package_erts-16.3_0.10.4")
      File.mkdir_p!(old)
      File.write!(Path.join(old, "_metadata.json"), "{}")
      payload(context.base, "build-1+k", 200)

      assert {:ok, report} = PayloadPrune.run(context.base, in_use, keep: 0, max_removals: 1)

      assert length(report.removed) == 1
      assert report.deferred == 1
    end

    # The owner's machine has one of these: an extraction from before the
    # version keying, named `..._0.10.5` with no build metadata. `keep` exists
    # so a ROLLBACK finds its payload already unpacked, but nothing can ever
    # roll back to an unkeyed directory -- no build will ever bear that name
    # again -- so keeping it is pure cost. Found by running a real daemon
    # against a real one and watching it survive.
    test "an unkeyed legacy extraction is removed even when keep would hold it",
         context do
      in_use = payload(context.base, "fermix_linux_package_erts-16.3_0.10.5+new", 0)
      legacy = payload(context.base, "fermix_linux_package_erts-16.3_0.10.5", 900)

      assert {:ok, report} = PayloadPrune.run(context.base, in_use, [])

      assert report.removed == [legacy]
      refute File.dir?(legacy)
    end

    test "a keyed superseded extraction is still held by keep", context do
      in_use = payload(context.base, "fermix_linux_package_erts-16.3_0.10.5+new", 0)
      keyed = payload(context.base, "fermix_linux_package_erts-16.3_0.10.5+old", 900)

      assert {:ok, report} = PayloadPrune.run(context.base, in_use, [])

      assert report.removed == []
      assert keyed in report.kept
      assert File.dir?(keyed)
    end

    test "a sibling that is not a payload directory is left alone", context do
      in_use = payload(context.base, "build-now+k", 0)
      stranger = Path.join(context.base, "notes.txt")
      File.write!(stranger, "not ours")
      unrelated = Path.join(context.base, "unrelated")
      File.mkdir_p!(unrelated)

      assert {:ok, report} = PayloadPrune.run(context.base, in_use, keep: 0)

      assert report.removed == []
      assert File.exists?(stranger)
      assert File.dir?(unrelated)
    end

    test "a base that does not exist yet is nothing to prune, not a failure", context do
      absent = Path.join(context.base, "never-created")

      assert {:ok, report} = PayloadPrune.run(absent, Path.join(absent, "build-a+k"), [])
      assert report.removed == []
    end

    test "an in-use directory outside the base is refused", context do
      assert {:error, {:outside_base, _path}} =
               PayloadPrune.run(context.base, "/tmp/elsewhere/build-a", [])
    end

    test "a relative base is refused rather than resolved against the cwd", context do
      assert {:error, {:not_absolute, "runtime"}} =
               PayloadPrune.run("runtime", Path.join(context.base, "build-a+k"), [])
    end
  end

  describe "run_for_launch/1" do
    # The realistic path now that nothing sets an install-dir variable: the
    # running VM's code root sits inside the extraction, so the directory in
    # use is found by walking up to the child of the `.burrito` base.
    test "finds the directory in use from the running release's own root", context do
      burrito = Path.join(context.base, ".burrito")
      File.mkdir_p!(burrito)
      in_use = payload(burrito, "fermix_linux_package_erts-16.3_0.10.5+new", 0)
      old = payload(burrito, "fermix_linux_package_erts-16.3_0.10.5+old", 500)

      assert {:ok, report} =
               PayloadPrune.run_for_launch(
                 keep: 0,
                 getenv: fn _name -> nil end,
                 code_root: fn -> Path.join(in_use, "erts-16.3") end
               )

      assert report.removed == [old]
      refute File.dir?(old)
      assert File.dir?(in_use)
    end

    # Reversed: this used to assert the install-dir variable decided the
    # directory in use. It does not -- it names Burrito's BASE, and the
    # extraction is inside it, so honouring it here pruned one level too high
    # and found nothing. The running VM's own code root is authoritative in
    # every case, so the variable is not consulted at all.
    test "the install-dir variable does not decide the directory in use", context do
      burrito = Path.join(context.base, ".burrito")
      File.mkdir_p!(burrito)
      in_use = payload(burrito, "fermix_linux_package_erts-16.3_0.10.5+new", 0)

      assert PayloadPrune.in_use_directory(
               getenv: fn _name -> context.base end,
               code_root: fn -> Path.join(in_use, "erts-16.3") end
             ) == in_use
    end

    # A source or dev run is not inside a Burrito extraction at all, so there is
    # nothing it is entitled to delete. Guessing a base would be a deletion
    # outside anything this process was told about.
    test "a run that is not inside an extraction prunes nothing", _context do
      assert PayloadPrune.run_for_launch(
               getenv: fn _name -> nil end,
               code_root: fn -> "/usr/lib/erlang" end
             ) == :not_packaged

      assert PayloadPrune.run_for_launch(
               getenv: fn _name -> "" end,
               code_root: fn -> nil end
             ) == :not_packaged
    end
  end
end
