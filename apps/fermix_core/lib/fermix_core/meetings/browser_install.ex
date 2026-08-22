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
  """

  alias FermixCore.Meetings.SidecarInstaller
  alias FermixCore.ProcessGroup

  # A fresh Chromium download is ~150 MB; the sidecar owns the real work, and
  # this is only a backstop for a wedged child that never exits.
  @default_timeout_ms 10 * 60_000
  @line_bytes 65_536

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
    ArgumentError -> {:error, {:spawn_failed, binary}}
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
          collect(port, os_pid, progress, deadline, acc <> chunk, outcome)

        {^port, {:exit_status, status}} ->
          verdict(status, outcome)
      after
        remaining -> {:error, :timeout}
      end
    end
  end

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
