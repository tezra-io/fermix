defmodule FermixCore.Meetings.SignIn do
  @moduledoc """
  Drives the meetbot sidecar's one-time interactive Google sign-in.

  `fermix-meetbot signin --profile-dir <dir>` opens a headed Chromium the
  operator signs into by hand; this module spawns it, streams its NDJSON status
  to a progress callback, and turns the exit code into a verdict. On success the
  bot's signed-in state lives in the Chromium profile — the daemon never reads
  inside it, only records that a sign-in finished (`SidecarInstaller`).

  ## macOS disclaim

  The sidecar launches a GUI Chromium, and a GUI child spawned bare inherits
  fermix as its TCC responsible process — the App Management prompt that re-fires
  every release. So on macOS it is spawned through the `disclaim` exec shim,
  exactly as `FermixCore.Browser.ChromeLauncher.spawn_plan/4` and
  `FermixCore.Meetings.Sidecar.Port` do. A missing shim refuses loud; there is
  no undisclaimed spawn.

  This is NOT the packet-4 meeting wire — it is a plain subprocess with
  line-delimited stdout, so it opens its own `{:line, _}` port rather than
  reusing `Sidecar.Port`.
  """

  alias FermixCore.Meetings.SidecarInstaller
  alias FermixCore.ProcessGroup

  require Logger

  # The sidecar owns the real 10-minute human deadline; this is only a backstop
  # for a wedged child that never exits.
  @default_timeout_ms 11 * 60_000
  @line_bytes 65_536

  @shim_missing_message "macOS disclaim shim is not built — rebuild fermix (mix compile) or reinstall"

  @type result :: {:ok, :signed_in} | {:error, :cancelled | :timeout | :not_installed | term()}
  @type progress :: ({:state, atom()} | {:result, atom()} -> any())

  @doc """
  Runs the interactive sign-in to a verdict, blocking the calling process
  (the setup LiveView runs it in a Task).

  `opts`: `progress` (arity-1 callback, default no-op), `timeout_ms`, and the
  test seams `binary_path`, `profile_dir`, and `args`.
  """
  @spec run(keyword()) :: result()
  def run(opts \\ []) when is_list(opts) do
    progress = Keyword.get(opts, :progress, fn _event -> :ok end)

    with {:ok, binary} <- resolve_binary(opts),
         {:ok, {executable, args}} <-
           spawn_plan(binary, subcommand_args(opts), :os.type(), disclaim_shim_path()) do
      spawn_and_wait(
        executable,
        args,
        progress,
        Keyword.get(opts, :timeout_ms, @default_timeout_ms)
      )
    end
  end

  @doc """
  Computes the spawn target and argv. Exposed for tests; on macOS the sidecar is
  never spawned directly (see the moduledoc). A deliberate ~15-line duplicate of
  the ChromeLauncher rule, pinned by its own failure-copy test.
  """
  @spec spawn_plan(String.t(), [String.t()], {atom(), atom()}, String.t() | nil) ::
          {:ok, {String.t(), [String.t()]}} | {:error, {:disclaim_shim_missing, String.t()}}
  def spawn_plan(_binary, _args, {:unix, :darwin}, nil),
    do: {:error, {:disclaim_shim_missing, @shim_missing_message}}

  def spawn_plan(binary, args, {:unix, :darwin}, shim) when is_binary(shim),
    do: {:ok, {shim, [binary | args]}}

  def spawn_plan(binary, args, _os_type, _shim), do: {:ok, {binary, args}}

  defp resolve_binary(opts) do
    case Keyword.get(opts, :binary_path) do
      path when is_binary(path) -> {:ok, path}
      nil -> SidecarInstaller.binary_path() |> normalize_binary_error()
    end
  end

  defp normalize_binary_error({:ok, path}), do: {:ok, path}
  defp normalize_binary_error({:error, :not_installed}), do: {:error, :not_installed}

  defp subcommand_args(opts) do
    case Keyword.get(opts, :args) do
      args when is_list(args) ->
        args

      nil ->
        [
          "signin",
          "--profile-dir",
          Keyword.get(opts, :profile_dir, SidecarInstaller.profile_dir())
        ]
    end
  end

  defp spawn_and_wait(executable, args, progress, timeout_ms) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        {:line, @line_bytes},
        :exit_status,
        :hide,
        {:args, args}
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    try do
      collect(port, os_pid, progress, deadline, "")
    after
      teardown(port, os_pid)
    end
  rescue
    ArgumentError -> {:error, {:spawn_failed, executable}}
  end

  # One receive loop, bounded by the backstop deadline. The exit status is the
  # verdict; status lines only feed progress.
  defp collect(port, os_pid, progress, deadline, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :timeout}
    else
      receive do
        {^port, {:data, {:eol, line}}} ->
          report(acc <> line, progress)
          collect(port, os_pid, progress, deadline, "")

        {^port, {:data, {:noeol, chunk}}} ->
          collect(port, os_pid, progress, deadline, acc <> chunk)

        {^port, {:exit_status, status}} ->
          verdict(status)
      after
        remaining -> {:error, :timeout}
      end
    end
  end

  defp verdict(0) do
    :ok = SidecarInstaller.mark_signed_in()
    {:ok, :signed_in}
  end

  defp verdict(2), do: {:error, :cancelled}
  defp verdict(3), do: {:error, :timeout}
  defp verdict(status), do: {:error, {:signin_failed, status}}

  # A status line is best-effort telemetry to the caller; a malformed one is
  # logged and dropped rather than failing the run, because the exit code — not
  # the line — is what decides.
  defp report(line, progress) do
    case Jason.decode(String.trim(line)) do
      {:ok, %{"event" => "signin_state", "state" => state}} ->
        emit(progress, {:state, state_atom(state)})

      {:ok, %{"event" => "signin_result", "status" => status}} ->
        emit(progress, {:result, result_atom(status)})

      _other ->
        :ok
    end
  end

  defp emit(progress, event) do
    progress.(event)
    :ok
  end

  defp state_atom("launching"), do: :launching
  defp state_atom("awaiting_signin"), do: :awaiting_signin
  defp state_atom("signed_in"), do: :signed_in
  defp state_atom(_other), do: :unknown

  defp result_atom("ok"), do: :ok
  defp result_atom("cancelled"), do: :cancelled
  defp result_atom("timeout"), do: :timeout
  defp result_atom(_other), do: :error

  # Close the port, then group-SIGKILL: the sidecar is a process-group leader and
  # its Chromium descendants die only with the group. `:esrch` is silent success.
  defp teardown(port, os_pid) do
    if Port.info(port), do: Port.close(port)
    ProcessGroup.signal(os_pid, :sigkill)
    :ok
  rescue
    ArgumentError -> ProcessGroup.signal(os_pid, :sigkill)
  end

  defp disclaim_shim_path do
    path = Application.app_dir(:fermix_nif, "priv/disclaim")
    if File.regular?(path), do: path, else: nil
  end
end
