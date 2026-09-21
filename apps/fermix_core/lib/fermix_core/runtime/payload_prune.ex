defmodule FermixCore.Runtime.PayloadPrune do
  @moduledoc """
  Removes superseded Burrito payload directories, with a bound and a report.

  The packaged Linux release is assembled under a version carrying the build
  identity as semver build metadata, so Burrito names each extraction
  `fermix_linux_package_erts-<erts>_0.10.5+<build id>` and a new build cannot
  land in the directory an old one left behind. That fixes the staleness and
  creates this: because build metadata is ignored in semver precedence, every
  build compares EQUAL to every other, so Burrito's own launch-time cleaner
  (which removes only strictly-older siblings) never reclaims any of them. One
  directory per build accumulates in each root, and nothing else tends them.

  The removal is deliberately timid, because the two failures are not
  symmetrical. Keeping a directory too long costs disk. Removing one a live
  daemon is still running costs that daemon: Burrito's payload is loaded lazily,
  so the process does not fail at the moment of deletion but at whatever later
  moment first needs an absent module. This therefore never removes the
  directory it was told is in use, keeps the most recent superseded ones so a
  rollback finds its payload already unpacked, removes at most `max_removals` in
  one pass, and names in its report exactly what it did and what it left.

  It is called from the one place that knows which directory is in use and that
  the previous generation has already stopped: the daemon's own startup.
  """

  require Logger

  @keep 2
  @max_removals 8
  @install_suffix ".burrito"
  # Burrito names each extraction `<release>_erts-<erts>_<version>`, and this is
  # the packaged Linux release's name from mix.exs. A constant rather than a
  # Mix lookup: Mix does not exist in a release, and this code runs in one.
  @release_name "fermix_linux_package"

  @typedoc "What a pass did, and what it left for the next one."
  @type report :: %{removed: [Path.t()], kept: [Path.t()], deferred: non_neg_integer()}

  @doc """
  Prunes `base` of payload directories other than `in_use`.

  `keep` is how many superseded directories survive, newest first, and
  `max_removals` caps one pass. Both refusals are structural: a relative base
  would resolve against whatever directory the daemon happens to have, and an
  `in_use` outside the base means the caller and this function disagree about
  which tree is being pruned, which is not a thing to guess at.
  """
  @spec run(Path.t(), Path.t(), keyword()) ::
          {:ok, report()} | {:error, {:not_absolute, Path.t()} | {:outside_base, Path.t()}}
  def run(base, in_use, opts \\ [])
      when is_binary(base) and (is_binary(in_use) or is_nil(in_use)) and is_list(opts) do
    keep = Keyword.get(opts, :keep, @keep)
    max_removals = Keyword.get(opts, :max_removals, @max_removals)

    with :ok <- check_absolute(base),
         :ok <- check_within(base, in_use) do
      {:ok, prune(base, in_use && Path.expand(in_use), keep, max_removals, opts)}
    end
  end

  @doc """
  Prunes the payload tree this process was launched from, if there is one.

  Sweeps both roots: the service's own base, named by the vendor unit, and the
  base a CLI invocation uses, which nothing else reclaims. The directory in use
  is found from the running VM rather than from an environment variable, so a
  run that is not inside a Burrito extraction at all answers `:not_packaged`
  rather than erroring -- there is nothing such a process may safely delete.
  """
  @spec run_for_launch(keyword()) :: {:ok, report()} | :not_packaged | {:error, term()}
  def run_for_launch(opts \\ []) when is_list(opts) do
    case in_use_directory(opts) do
      nil -> :not_packaged
      in_use -> run_both_roots(in_use, opts)
    end
  end

  # Two roots, because the service and the CLI deliberately do not share one.
  # The vendor unit points the service at its own base so that Burrito's
  # launch-time cleaner, which deletes older sibling extractions on EVERY run,
  # can never reach the running daemon's payload from an ordinary `fermix`
  # command. That protection costs a second tree nothing else tends: every
  # build is `0.10.5+<build id>`, so the CLI's extractions all compare equal
  # and Burrito's cleaner never reclaims any of them.
  #
  # The daemon sweeps it, and only the daemon: this runs from `service run`,
  # never from a CLI path, for the same reason the roots are separate.
  defp run_both_roots(in_use, opts) do
    service = run(Path.dirname(in_use), in_use, opts)

    case {service, cli_root(opts)} do
      {{:ok, report}, nil} -> {:ok, report}
      {{:ok, report}, root} -> {:ok, merge(report, sweep_cli_root(root, opts))}
      {refusal, _root} -> refusal
    end
  end

  # Nothing here is in use by this process, and a long-running `fermix chat`
  # might be using one, so this keeps the same margin the service root gets
  # rather than emptying the tree.
  defp sweep_cli_root(root, opts) do
    case run(root, nil, Keyword.put(opts, :release_prefix, release_prefix())) do
      {:ok, report} -> report
      {:error, _refusal} -> empty_report()
    end
  end

  defp cli_root(opts) do
    case Keyword.get(opts, :cli_root, &default_cli_root/0).() do
      root when is_binary(root) -> root
      _absent -> nil
    end
  end

  # Burrito's default base, which is where a CLI invocation that sets nothing
  # extracts. `:filename.basedir/3` is the same rule zig's `getAppDataDir`
  # follows, so this names the directory Burrito actually used.
  defp default_cli_root do
    case System.fetch_env("HOME") do
      {:ok, home} -> Path.join([home, ".local", "share", @install_suffix])
      :error -> nil
    end
  end

  # Other Burrito applications may share this base, and they are not ours to
  # delete. Only extractions Burrito named for THIS release are candidates.
  defp release_prefix, do: @release_name <> "_erts-"

  defp merge(first, second) do
    %{
      removed: first.removed ++ second.removed,
      kept: first.kept ++ second.kept,
      deferred: first.deferred + second.deferred
    }
  end

  defp empty_report, do: %{removed: [], kept: [], deferred: 0}

  @doc """
  The payload directory this process is running out of, or nil.

  Burrito extracts into `<base>/<release>_erts-<erts>_<version>` and then runs
  the release from inside it, so the running VM's own code root is underneath
  the directory in use -- which is how this finds it without an environment
  variable and without Burrito exposing one. The install-dir variable is NOT
  consulted: it names Burrito's BASE, not the extraction inside it, so reading
  it here pruned one level too high and silently found nothing -- caught by
  running a real daemon, not by the test, which had encoded the same mistake.
  Walking up to the directory whose
  name Burrito built is more honest than reconstructing that name from the
  release name, the ERTS version and the app version: a reconstruction is a
  guess that agrees with reality until one of the three drifts, and it would
  name a directory to DELETE.
  """
  @spec in_use_directory(keyword()) :: Path.t() | nil
  def in_use_directory(opts \\ []) when is_list(opts) do
    case Keyword.get(opts, :code_root, &default_code_root/0).() do
      root when is_binary(root) -> ancestor_payload(Path.expand(root))
      _absent -> nil
    end
  end

  defp default_code_root, do: :code.root_dir() |> to_string()

  # Up from the code root until the release's own extraction directory, which
  # is the one sitting directly inside a `.burrito` base.
  defp ancestor_payload(path) do
    parent = Path.dirname(path)

    cond do
      parent == path -> nil
      Path.basename(parent) == @install_suffix -> path
      true -> ancestor_payload(parent)
    end
  end

  defp check_absolute(base) do
    if Path.type(base) == :absolute, do: :ok, else: {:error, {:not_absolute, base}}
  end

  defp check_within(_base, nil), do: :ok

  defp check_within(base, in_use) do
    parent = base |> Path.expand() |> Path.join("")
    expanded = Path.expand(in_use)

    if String.starts_with?(expanded, parent) and expanded != Path.expand(base) do
      :ok
    else
      {:error, {:outside_base, in_use}}
    end
  end

  defp prune(base, in_use, keep, max_removals, opts) do
    # `keep` buys a rollback a payload that is already unpacked, so it only
    # applies to directories a rollback could actually land on. An unkeyed one
    # -- named `..._0.10.5` with no `+<build id>`, from before the version
    # keying -- can never be chosen again by any build, so holding it is pure
    # cost and it is always a candidate.
    {legacy, keyed} =
      base
      |> superseded(in_use, Keyword.get(opts, :release_prefix))
      |> Enum.sort_by(& &1.mtime, :desc)
      |> Enum.split_with(&legacy?(&1.path))

    {kept, superseded_keyed} = Enum.split(keyed, keep)
    candidates = legacy ++ superseded_keyed

    # Oldest first, so that repeated capped passes converge on the same tail
    # rather than taking a different slice each time.
    removable = candidates |> Enum.reverse() |> Enum.take(max_removals)

    removed = Enum.flat_map(removable, &remove(&1.path))
    report = %{
      removed: removed,
      kept: Enum.map(kept, & &1.path),
      deferred: length(candidates) - length(removable)
    }

    log(base, report)
    report
  end

  # Only a directory that actually holds an extracted payload, so that anything
  # else sharing this parent is not ours to delete.
  defp superseded(base, in_use, release_prefix) do
    case File.ls(base) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&named_for_this_release?(&1, release_prefix))
        |> Enum.map(&Path.join(base, &1))
        |> Enum.reject(&(&1 == in_use))
        |> Enum.filter(&payload_directory?/1)
        |> Enum.map(&%{path: &1, mtime: mtime(&1)})

      {:error, _absent} ->
        []
    end
  end

  # Two shapes. A keyed directory holds its extraction in a `.burrito`
  # subdirectory. The legacy unkeyed extraction, from before the directory was
  # named after the payload, IS the `.burrito` directory: every build shared it,
  # which is the defect the keying ends. It is superseded by definition once
  # this process is running from a keyed directory, so it prunes like the rest
  # rather than being left to sit in the account forever.
  # Burrito's own marker. It writes `_metadata.json` into an extraction once it
  # is complete, and reuses any directory that has one, so a directory carrying
  # it is exactly a payload and a directory without one is not ours to remove.
  # Measured against a real install rather than assumed: the extraction holds
  # `_metadata.json`, `bin`, `erts-<v>`, `lib` and `releases`.
  # In the service's own base every extraction is ours, so no prefix is given.
  # In the CLI's base, which other Burrito applications may share, only a name
  # Burrito built for THIS release is a candidate.
  defp named_for_this_release?(_name, nil), do: true
  defp named_for_this_release?(name, prefix), do: String.starts_with?(name, prefix)

  # Burrito builds the name as `<release>_erts-<erts>_<version>`, and every
  # version this engine is assembled under now carries `+<build id>`.
  defp legacy?(path), do: not String.contains?(Path.basename(path), "+")

  defp payload_directory?(path) do
    File.dir?(path) and File.regular?(Path.join(path, "_metadata.json"))
  end

  defp mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> mtime
      {:error, _gone} -> 0
    end
  end

  # A removal that fails is reported and not retried: the next start will see
  # the directory again, and a daemon must not refuse to boot over cache
  # housekeeping.
  defp remove(path) do
    case File.rm_rf(path) do
      {:ok, _removed} ->
        [path]

      {:error, reason, offender} ->
        Logger.warning(
          "could not remove the superseded runtime payload #{path}: #{:file.format_error(reason)} at #{offender}"
        )

        []
    end
  end

  defp log(base, %{removed: [], deferred: 0} = report) do
    # Logged even when there was nothing to do: a silent pass is
    # indistinguishable from a pass that never happened, which is exactly how
    # the retention bug above hid on a real install.
    Logger.debug(
      "pruned runtime payloads under #{base}: nothing superseded, kept #{length(report.kept)}"
    )
  end

  defp log(base, report) do
    Logger.info(
      "pruned runtime payloads under #{base}: removed #{length(report.removed)}, " <>
        "kept #{length(report.kept)}, deferred #{report.deferred}"
    )
  end
end
