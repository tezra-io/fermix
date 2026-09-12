defmodule FermixCore.Meetings.Caffeinate do
  @moduledoc """
  Holds macOS awake for the length of a meeting (MILESTONE_21 C2 §2.6).

  A laptop that sleeps mid-meeting drops the capture, and the operator finds a
  transcript that stops at the moment the lid closed. `/usr/bin/caffeinate -dims`
  is the platform's own answer, so this module is a thin, bounded owner of one
  such process.

  Two modes, one per lane:

    * `{:watch_pid, os_pid}` — `caffeinate -w <pid>` self-exits when the watched
      process dies, so a sidecar teardown is also the guard's teardown.
    * `{:bounded, seconds}` — `caffeinate -t <seconds>` self-bounds, for a lane
      with no OS process of its own to watch. `stop/1` still kills it explicitly;
      the bound is the belt for a daemon that dies without running teardown.

  Off macOS, and on a macOS without the binary, `start/2` returns `:inactive` and
  the meeting proceeds. That is a visible degradation of a comfort feature, not a
  fallback path: nothing else is attempted, and the macOS-without-the-binary case
  logs once so a missing system tool is not silent.
  """

  alias FermixCore.ProcessGroup

  require Logger

  @binary "/usr/bin/caffeinate"

  @typedoc "A running sleep guard: the port and the OS process behind it."
  @type t :: %{port: port(), os_pid: pos_integer()}

  @type mode :: {:watch_pid, pos_integer()} | {:bounded, pos_integer()}

  @doc """
  Starts the sleep guard, or reports `:inactive` where there is nothing to hold.

  `opts[:os_type]` is the platform seam (default `:os.type/0`) — the suite drives
  the non-darwin branch through it and never spawns the real binary.
  """
  @spec start(mode(), keyword()) :: {:ok, t()} | :inactive
  def start(mode, opts \\ [])

  def start({:watch_pid, os_pid} = mode, opts) when is_integer(os_pid) and os_pid > 0 do
    start_for(os_type(opts), mode)
  end

  def start({:bounded, seconds} = mode, opts) when is_integer(seconds) and seconds > 0 do
    start_for(os_type(opts), mode)
  end

  @doc "Kills the guard and closes its port. Idempotent, and a no-op for `nil`."
  @spec stop(t() | nil) :: :ok
  def stop(nil), do: :ok

  def stop(%{port: port, os_pid: os_pid}) do
    # The port child leads its own process group, so the group signal is what
    # guarantees the kill; `:esrch` on an already-dead group is silent success.
    ProcessGroup.signal(os_pid, :sigkill)
    close_port(port)
    :ok
  end

  @doc """
  The argv for a mode. Exposed so the darwin branch is testable without spawning.
  """
  @spec caffeinate_args(mode()) :: [String.t()]
  def caffeinate_args({:watch_pid, os_pid}), do: ["-dims", "-w", Integer.to_string(os_pid)]
  def caffeinate_args({:bounded, seconds}), do: ["-dims", "-t", Integer.to_string(seconds)]

  # --- Private ---

  defp start_for({:unix, :darwin}, mode) do
    if File.regular?(@binary), do: open(mode), else: missing_binary()
  end

  defp start_for(_os_type, _mode), do: :inactive

  defp missing_binary do
    Logger.warning("meetings: #{@binary} is missing — the display may sleep during the meeting")

    :inactive
  end

  defp open(mode) do
    port =
      Port.open({:spawn_executable, @binary}, [
        :binary,
        :exit_status,
        {:args, caffeinate_args(mode)}
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    {:ok, %{port: port, os_pid: os_pid}}
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    # The guard exited between the liveness check and the close — the requested
    # end state already holds (the `Sidecar.Port.close/1` idiom).
    ArgumentError -> :ok
  end

  defp os_type(opts), do: Keyword.get_lazy(opts, :os_type, &:os.type/0)
end
