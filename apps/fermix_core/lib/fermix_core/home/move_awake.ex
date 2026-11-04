defmodule FermixCore.Home.MoveAwake do
  @moduledoc """
  Keeps the computer a move leaves awake while the move runs, and only then
  (M75 L16): from the start of the move worker
  (`FermixChannels.Home.MoveWorker`), in the device-role engine Move now
  restarts into, until the worker ends, which is the engine's restart as a
  desktop of the new primary, or as the primary again when the move was
  undone. The primary that takes Move now holds nothing: it restarts into the
  worker at once. Nothing is held while a server waits for Move now: it keeps
  trying until its code expires. On a move back, the computer the home comes
  back to holds it too (`FermixChannels.Home.Candidate` of kind `return`):
  from `receiving` until the restart that makes it the primary again.

  Each inhibitor ends when the engine ends, by its own rule:

    * macOS: `/usr/bin/caffeinate -i -w <the BEAM's pid>`, spawned through the
      `disclaim` exec shim (`fermix_nif` priv, the macOS TCC identity rule);
      with no shim nothing is spawned;
    * Linux: `systemd-inhibit --what=sleep:idle --who=Fermix
      --why="Fermix is moving to your server" --mode=block tail
      --pid=<the BEAM's pid> -f /dev/null`: logind holds the lock while the
      tail runs, and the tail ends with the BEAM.

  `hold/1` starts a holder under the core task supervisor that owns the
  inhibitor's port and monitors the process that asked, its owner. The holder
  ends the inhibitor's process group (`FermixCore.ProcessGroup.signal/2`)
  when `release/1` asks, when the owner ends however it ends (a crash or a
  kill included), or after #{26} hours, past the longest a move waits; an
  inhibitor that ends by itself is logged with what it printed. A hold that
  cannot start (no inhibitor on this system, a refused spawn) is an error
  the worker logs: the move goes on, and the computer may sleep.

  `:why` is the reason systemd-inhibit lists ("Fermix is moving to your server" unless
  said).

  Seams: `:os_type`, `:os_pid` (the BEAM's, `System.pid/0`), `:disclaim` and
  `:caffeinate` (paths, or nil), `:find_executable`, `:spawn` (2-arity, the
  executable and its argv to `{:ok, %{port: port, os_pid: pos_integer}}`),
  `:kill` (1-arity, the group), `:task_supervisor`.
  """

  alias FermixCore.ProcessGroup

  require Logger

  @why "Fermix is moving to your server"
  @max_hold_ms 26 * 3_600_000
  @wait_ms 10_000
  @max_output_bytes 2_048
  @caffeinate "/usr/bin/caffeinate"
  @shim_missing "macOS disclaim shim is not built — rebuild fermix (mix compile) or reinstall"

  @type plan :: {String.t(), [String.t()]}

  @doc "The longest a hold lasts, in milliseconds."
  @spec max_hold_ms() :: pos_integer()
  def max_hold_ms, do: @max_hold_ms

  @doc """
  Starts keeping this computer awake for the calling process: `{:ok, holder}`,
  or `{:error, reason}` when nothing could be held (`describe/1` words it).
  """
  @spec hold(keyword()) :: {:ok, pid()} | {:error, term()}
  def hold(opts \\ []) when is_list(opts) do
    owner = self()
    supervisor = Keyword.get(opts, :task_supervisor, FermixCore.TaskSupervisor)
    {:ok, holder} = Task.Supervisor.start_child(supervisor, fn -> hold_for(owner, opts) end)
    ref = Process.monitor(holder)

    receive do
      {:move_awake, ^holder, result} ->
        Process.demonitor(ref, [:flush])
        held(result, holder)

      {:DOWN, ^ref, :process, ^holder, reason} ->
        {:error, {:holder_down, reason}}
    after
      @wait_ms ->
        Process.demonitor(ref, [:flush])
        Process.exit(holder, :kill)
        {:error, :holder_timeout}
    end
  end

  defp held(:ok, holder), do: {:ok, holder}
  defp held({:error, _reason} = error, _holder), do: error

  @doc "Ends a hold `hold/1` started; nil (nothing held) is nothing to do."
  @spec release(pid() | nil) :: :ok
  def release(nil), do: :ok

  def release(holder) when is_pid(holder) do
    ref = Process.monitor(holder)
    send(holder, :release)

    receive do
      {:DOWN, ^ref, :process, ^holder, _reason} -> :ok
    after
      @wait_ms ->
        Logger.error("move: the sleep guard did not end within #{@wait_ms} ms; stopping it")
        Process.exit(holder, :kill)
        :ok
    end
  end

  @doc "The inhibitor this system runs: its executable and argv, or why there is none."
  @spec plan({atom(), atom()}, keyword()) :: {:ok, plan()} | {:error, term()}
  def plan({:unix, :darwin}, opts) when is_list(opts) do
    shim = Keyword.get_lazy(opts, :disclaim, &disclaim_shim/0)
    caffeinate = Keyword.get_lazy(opts, :caffeinate, &caffeinate/0)

    cond do
      shim == nil -> {:error, {:disclaim_shim_missing, @shim_missing}}
      caffeinate == nil -> {:error, {:not_found, "caffeinate"}}
      true -> {:ok, {shim, [caffeinate, "-i", "-w", os_pid(opts)]}}
    end
  end

  def plan({:unix, :linux}, opts) when is_list(opts) do
    find = Keyword.get(opts, :find_executable, &System.find_executable/1)

    case {find.("systemd-inhibit"), find.("tail")} do
      {nil, _tail} -> {:error, {:not_found, "systemd-inhibit"}}
      {_inhibit, nil} -> {:error, {:not_found, "tail"}}
      {inhibit, tail} -> {:ok, {inhibit, inhibit_args(tail, os_pid(opts), why(opts))}}
    end
  end

  def plan({_family, os}, opts) when is_list(opts), do: {:error, {:unsupported, os}}

  @doc "Why nothing keeps this computer awake, in a few plain words."
  @spec describe(term()) :: String.t()
  def describe({:not_found, name}), do: "#{name} is not installed"
  def describe({:disclaim_shim_missing, sentence}), do: sentence
  def describe({:unsupported, _os}), do: "this system has no sleep guard Fermix uses"
  def describe({:spawn_failed, executable}), do: "#{executable} could not be started"
  def describe(reason), do: inspect(reason)

  # -- the holder -------------------------------------------------------------

  defp hold_for(owner, opts) do
    owner_ref = Process.monitor(owner)
    spawn = Keyword.get(opts, :spawn, &spawn_inhibitor/2)

    with {:ok, {executable, args}} <- plan(Keyword.get_lazy(opts, :os_type, &:os.type/0), opts),
         {:ok, %{port: _port, os_pid: os_pid} = inhibitor} when is_integer(os_pid) <-
           spawn.(executable, args) do
      send(owner, {:move_awake, self(), :ok})
      Process.send_after(self(), :expired, @max_hold_ms)
      kill = Keyword.get(opts, :kill, &kill_group/1)
      wait(%{owner_ref: owner_ref, inhibitor: inhibitor, output: "", kill: kill})
    else
      {:error, _reason} = error -> send(owner, {:move_awake, self(), error})
    end
  end

  # Message-driven, and the bound's own timer ends it at the latest.
  defp wait(%{owner_ref: owner_ref, inhibitor: %{port: port}} = state) do
    receive do
      :release ->
        stop(state)

      {:DOWN, ^owner_ref, :process, _owner, _reason} ->
        stop(state)

      :expired ->
        Logger.warning(
          "move: the sleep guard reached its bound of 26 hours; this computer may sleep again"
        )

        stop(state)

      {^port, {:data, data}} ->
        wait(%{state | output: tail(state.output <> data)})

      {^port, {:exit_status, status}} ->
        ended(state, status)
    end
  end

  defp ended(state, status) do
    Logger.warning(
      "move: the sleep guard ended by itself (exit #{status}): " <>
        "#{String.trim(state.output)}; this computer may sleep while the move runs"
    )

    stop(state)
  end

  # The group signal is what ends the inhibitor and anything it started (the
  # tail under systemd-inhibit); a group already gone is silent success.
  defp stop(%{inhibitor: %{port: port, os_pid: os_pid}, kill: kill}) do
    :ok = kill.(os_pid)
    close_port(port)
  end

  defp close_port(port) do
    if is_port(port) and Port.info(port), do: Port.close(port)
    :ok
  rescue
    # The inhibitor exited between the check and the close: the end state holds.
    ArgumentError -> :ok
  end

  defp tail(output) when byte_size(output) <= @max_output_bytes, do: output

  defp tail(output),
    do: binary_part(output, byte_size(output) - @max_output_bytes, @max_output_bytes)

  # -- spawning ---------------------------------------------------------------

  defp spawn_inhibitor(executable, args) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, args}
      ])

    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> {:ok, %{port: port, os_pid: os_pid}}
      nil -> {:error, {:spawn_failed, executable}}
    end
  rescue
    # A file that is there but cannot be run.
    ArgumentError -> {:error, {:spawn_failed, executable}}
  end

  defp kill_group(os_pid), do: ProcessGroup.signal(os_pid, :sigkill)

  defp inhibit_args(tail, os_pid, why) do
    [
      "--what=sleep:idle",
      "--who=Fermix",
      "--why=#{why}",
      "--mode=block",
      tail,
      "--pid=#{os_pid}",
      "-f",
      "/dev/null"
    ]
  end

  defp os_pid(opts), do: Keyword.get_lazy(opts, :os_pid, &System.pid/0)
  defp why(opts), do: Keyword.get(opts, :why, @why)

  defp caffeinate, do: if(File.regular?(@caffeinate), do: @caffeinate)

  defp disclaim_shim do
    path = Application.app_dir(:fermix_nif, "priv/disclaim")
    if File.regular?(path), do: path
  end
end
