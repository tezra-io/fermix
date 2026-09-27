defmodule FermixCore.Meetings.BrowserInstall do
  @moduledoc """
  Drives the meetbot sidecar's `install-browser` step so the daemon can set the
  Meeting Notetaker up with no `npx` and no operator commands.

  `fermix-meetbot install-browser` installs the sidecar's own version-matched
  Chromium (idempotent — fast when already present). This module spawns it,
  streams its NDJSON status to a progress callback, turns the exit code into a
  verdict, and records success (`SidecarInstaller.mark_browser_installed/0`).

  Unlike `FermixCore.Meetings.SignIn`, this launches **no GUI** — it is a plain
  subprocess that downloads into Playwright's cache — so it is spawned as an
  ordinary `Port` with **no disclaim shim**. It is not the packet-4 meeting wire
  either, so it uses its own `{:line, _}` port rather than `Sidecar.Port`.

  The same Chromium is the task browser's last candidate
  (`FermixCore.Browser.ChromeLauncher`), so this module also answers where it
  landed (`chromium_path/1`), by the rules Playwright itself installs by.
  """

  alias FermixCore.Meetings.SidecarInstaller
  alias FermixCore.ProcessGroup

  # A fresh Chromium download is ~150 MB; the sidecar owns the real work, and
  # this is only a backstop for a wedged child that never exits.
  @default_timeout_ms 10 * 60_000
  @line_bytes 65_536

  # Where Playwright's `install chromium` puts the executable inside a
  # `chromium-<revision>` directory, per release target: the pinned sidecar's
  # Playwright lays it out this way (its `EXECUTABLE_PATHS`), and a sidecar pin
  # that moves it fails the install job's own check that a browser was found.
  # The revision is never named here; it is whichever complete one is newest.
  @chromium_layouts %{
    "macos-aarch64" => [
      "chrome-mac-arm64",
      "Google Chrome for Testing.app",
      "Contents",
      "MacOS",
      "Google Chrome for Testing"
    ],
    "macos-x86_64" => [
      "chrome-mac-x64",
      "Google Chrome for Testing.app",
      "Contents",
      "MacOS",
      "Google Chrome for Testing"
    ],
    "linux-x86_64" => ["chrome-linux64", "chrome"],
    "linux-aarch64" => ["chrome-linux", "chrome"]
  }
  @chromium_revision ~r/^chromium-(\d+)$/
  # Playwright writes this marker last, so a revision without it is a download
  # that never finished rather than a browser.
  @installation_complete "INSTALLATION_COMPLETE"

  @type result :: {:ok, :installed | :already} | {:error, :not_installed | term()}
  @type progress :: ({:state, atom()} | {:result, atom()} -> any())

  @doc """
  Installs the sidecar's browser to a verdict, blocking the calling process (the
  setup LiveView runs it in a Task).

  `opts`: `progress` (arity-1 callback, default no-op), `timeout_ms`, and the
  test seams `binary_path` and `args`.
  """
  @spec run(keyword()) :: result()
  def run(opts \\ []) when is_list(opts) do
    progress = Keyword.get(opts, :progress, fn _event -> :ok end)

    with {:ok, binary} <- resolve_binary(opts) do
      spawn_and_wait(
        binary,
        subcommand_args(opts),
        progress,
        Keyword.get(opts, :timeout_ms, @default_timeout_ms)
      )
    end
  end

  @doc """
  The Chromium `install-browser` placed, found on disk without spawning
  anything: the newest complete `chromium-<revision>` in Playwright's cache that
  holds this machine's executable.

  The cache is the one Playwright resolves, because the sidecar inherits this
  daemon's environment and installs there: `PLAYWRIGHT_BROWSERS_PATH` when it
  is set, otherwise the OS cache directory. `opts` carries the test seams `root`
  (the cache) and `target` (the release target).
  """
  @spec chromium_path(keyword()) :: {:ok, Path.t()} | {:error, :not_installed}
  def chromium_path(opts \\ []) when is_list(opts) do
    root = Keyword.get_lazy(opts, :root, &playwright_root/0)

    with {:ok, target} <- chromium_target(opts),
         {:ok, layout} <- Map.fetch(@chromium_layouts, target),
         {:ok, entries} <- File.ls(root) do
      entries
      |> chromium_revisions()
      |> Enum.find_value({:error, :not_installed}, &complete_chromium(root, &1, layout))
    else
      # No layout for this machine, and no cache directory, both mean nothing
      # was installed here, exactly as a missing file does for every other
      # candidate the launcher probes.
      _absent -> {:error, :not_installed}
    end
  end

  defp chromium_target(opts) do
    case Keyword.fetch(opts, :target) do
      {:ok, target} when is_binary(target) -> {:ok, target}
      :error -> SidecarInstaller.target()
    end
  end

  # Newest first, by the revision's number rather than its spelling, so
  # `chromium-1234` outranks `chromium-999`.
  defp chromium_revisions(entries) do
    entries
    |> Enum.flat_map(fn entry ->
      case Regex.run(@chromium_revision, entry) do
        [_entry, revision] -> [{String.to_integer(revision), entry}]
        nil -> []
      end
    end)
    |> Enum.sort(:desc)
    |> Enum.map(fn {_revision, entry} -> entry end)
  end

  defp complete_chromium(root, entry, layout) do
    revision = Path.join(root, entry)
    executable = Path.join([revision | layout])

    if File.regular?(Path.join(revision, @installation_complete)) and File.regular?(executable),
      do: {:ok, executable}
  end

  # Playwright's own resolution: an empty variable counts as unset, and a
  # relative one is taken from the working directory the sidecar shares.
  defp playwright_root do
    case System.get_env("PLAYWRIGHT_BROWSERS_PATH") do
      unset when unset in [nil, ""] -> Path.join(os_cache_dir(), "ms-playwright")
      path -> Path.expand(path)
    end
  end

  defp os_cache_dir do
    case :os.type() do
      {:unix, :darwin} -> Path.join([System.user_home!(), "Library", "Caches"])
      _unix -> xdg_cache_dir(System.get_env("XDG_CACHE_HOME"))
    end
  end

  defp xdg_cache_dir(unset) when unset in [nil, ""], do: Path.join(System.user_home!(), ".cache")
  defp xdg_cache_dir(path), do: path

  defp resolve_binary(opts) do
    case Keyword.get(opts, :binary_path) do
      path when is_binary(path) -> {:ok, path}
      nil -> normalize_binary_error(SidecarInstaller.binary_path())
    end
  end

  defp normalize_binary_error({:ok, path}), do: {:ok, path}
  defp normalize_binary_error({:error, :not_installed}), do: {:error, :not_installed}

  defp subcommand_args(opts), do: Keyword.get(opts, :args, ["install-browser"])

  defp spawn_and_wait(binary, args, progress, timeout_ms) do
    port =
      Port.open({:spawn_executable, binary}, [
        :binary,
        {:line, @line_bytes},
        :exit_status,
        :hide,
        {:args, args}
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    try do
      collect(port, os_pid, progress, deadline, "", :installed)
    after
      teardown(port, os_pid)
    end
  rescue
    ArgumentError ->
      {:error, {:spawn_failed, binary}}

    # A vanished or non-executable binary raises ErlangError (:enoent/:eacces)
    # from open_port, not ArgumentError — without this clause the typed
    # spawn_failed path was dead code and real failures killed the async Task.
    error in ErlangError ->
      {:error, {:spawn_failed, binary, error.original}}
  end

  # One receive loop, bounded by the backstop deadline. The exit status is the
  # verdict; status lines feed progress and remember whether the browser was
  # already present (so the caller can distinguish a download from a no-op).
  defp collect(port, os_pid, progress, deadline, acc, outcome) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :timeout}
    else
      receive do
        {^port, {:data, {:eol, line}}} ->
          outcome = report(acc <> line, progress, outcome)
          collect(port, os_pid, progress, deadline, "", outcome)

        {^port, {:data, {:noeol, chunk}}} ->
          collect(port, os_pid, progress, deadline, cap_line(acc <> chunk), outcome)

        {^port, {:exit_status, status}} ->
          verdict(status, outcome)
      after
        remaining -> {:error, :timeout}
      end
    end
  end

  # `{:line, @line_bytes}` bounds each PORT MESSAGE, not the accumulated line:
  # a child streaming newline-free bytes would otherwise grow the accumulator
  # until the multi-minute backstop. The exit code decides the verdict, so an
  # oversized line is truncated (its tail dropped), never fatal.
  @max_line_accumulator_bytes 1_048_576

  defp cap_line(acc) when byte_size(acc) > @max_line_accumulator_bytes,
    do: binary_part(acc, 0, @max_line_accumulator_bytes)

  defp cap_line(acc), do: acc

  defp verdict(0, outcome) do
    :ok = SidecarInstaller.mark_browser_installed()
    {:ok, outcome}
  end

  defp verdict(status, _outcome), do: {:error, {:browser_install_failed, status}}

  # A status line is best-effort telemetry; a malformed one is dropped because
  # the exit code — not the line — decides. The `already` flag on the result
  # line is remembered so a no-op reads as `:already`, a real fetch `:installed`.
  defp report(line, progress, outcome) do
    case Jason.decode(String.trim(line)) do
      {:ok, %{"event" => "browser_state", "state" => state}} ->
        emit(progress, {:state, state_atom(state)})
        outcome

      {:ok, %{"event" => "browser_result", "status" => status} = frame} ->
        emit(progress, {:result, result_atom(status)})
        if frame["already"] == true, do: :already, else: outcome

      _other ->
        outcome
    end
  end

  defp emit(progress, event) do
    progress.(event)
    :ok
  end

  defp state_atom("checking"), do: :checking
  defp state_atom("downloading"), do: :downloading
  defp state_atom("installed"), do: :installed
  defp state_atom(_other), do: :unknown

  defp result_atom("ok"), do: :ok
  defp result_atom(_other), do: :error

  # Close the port, then group-SIGKILL: the sidecar is a process-group leader.
  # `:esrch` is silent success.
  defp teardown(port, os_pid) do
    if Port.info(port), do: Port.close(port)
    ProcessGroup.signal(os_pid, :sigkill)
    :ok
  rescue
    ArgumentError -> ProcessGroup.signal(os_pid, :sigkill)
  end
end
