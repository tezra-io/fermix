defmodule FermixCore.Sandbox.EnvHealth do
  @moduledoc """
  The daemon's own record of which allowed sandbox variables it can read.

  Readiness reads this, never the environment: a probe from a Doctor run or a
  settings poll would inspect the world the probe runs in, and the operator's
  shell is exactly the world that had the variable while the service did not.
  The record is written where the truth is produced: once at boot, again on
  every config apply, and by every shell command's real resolution, so a bad
  entry shows up the moment it lands and clears the moment it resolves. A poll
  reads the record and never spawns a helper.

  The boot and config-apply probes run off this process. A `command` source
  spawns its helper, each bounded by its own timeout, and readiness asks this
  process at boot and on every settings poll; a caller must get its answer
  while a helper is slow (a keychain waiting on a prompt), never a call
  timeout, so the probe is a task that records its outcome like any command.

  The record keeps names, reasons and times only, never a value. Readiness
  reports a name only while it is on the allow list in force, so an entry for
  a name the operator removed is simply never published.

  It is advisory by construction. A trading credential that stops resolving
  must never mark messaging or repair as unfinished, so nothing here gates
  boot, and the process holds no state a restart cannot rebuild.

  Logging is on transition only. A command that fails the same way a hundred
  times writes one line on the way in and one on the way out.

  A tree-less command line verb has no process, and the defined answer there
  is "nothing recorded": `unresolved/1` answers `[]`, and `record/2` and
  `refresh/1` are no-ops.
  """

  use GenServer

  require Logger

  alias FermixCore.Sandbox.Config
  alias FermixCore.Sandbox.Env

  @typedoc """
  One allowed name the daemon cannot read, and when its current reason was
  first seen. A reason that changes (a missing value becomes a failing helper)
  is a new observation with its own time.
  """
  @type entry :: %{name: String.t(), reason: term(), since: DateTime.t()}

  @typedoc "What a resolution produced: the allowed names read, and the ones not."
  @type report :: %{resolved: [String.t()], unresolved: [Env.unresolved()]}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Record one resolution. Only the names and reasons travel, never a value."
  @spec record(report() | map(), keyword()) :: :ok
  def record(%{resolved: resolved, unresolved: unresolved}, opts \\ [])
      when is_list(resolved) and is_list(unresolved) and is_list(opts) do
    cast(opts, {:record, %{resolved: resolved, unresolved: unresolved}})
  end

  @doc "Resolve the current allow list off this process and record the outcome."
  @spec refresh(keyword()) :: :ok
  def refresh(opts \\ []) when is_list(opts), do: cast(opts, :refresh)

  @doc "Every name the daemon could not read, by name."
  @spec unresolved(keyword()) :: [entry()]
  def unresolved(opts \\ []) when is_list(opts) do
    case whereis(opts) do
      nil -> []
      server -> GenServer.call(server, :unresolved)
    end
  end

  @impl true
  def init(_opts), do: {:ok, %{}, {:continue, :refresh}}

  @impl true
  def handle_continue(:refresh, state), do: {:noreply, start_probe(state)}

  @impl true
  def handle_cast(:refresh, state), do: {:noreply, start_probe(state)}
  def handle_cast({:record, report}, state), do: {:noreply, apply_report(state, report)}

  @impl true
  def handle_call(:unresolved, _from, state) do
    {:reply, state |> Map.values() |> Enum.sort_by(& &1.name), state}
  end

  defp cast(opts, message) do
    case whereis(opts) do
      nil -> :ok
      server -> GenServer.cast(server, message)
    end
  end

  defp whereis(opts), do: opts |> Keyword.get(:server, __MODULE__) |> GenServer.whereis()

  # `Env.build/1` with no requested names cannot fail, so the match is the
  # loud assertion of that contract, inside a task this process never waits on.
  defp start_probe(state) do
    server = self()

    {:ok, _pid} =
      Task.Supervisor.start_child(FermixCore.TaskSupervisor, fn ->
        {:ok, report} = Env.build(Config.current())
        GenServer.cast(server, {:record, Map.take(report, [:resolved, :unresolved])})
      end)

    state
  end

  defp apply_report(state, %{resolved: resolved, unresolved: unresolved}) do
    state
    |> clear_resolved(resolved)
    |> note_unresolved(unresolved)
  end

  defp clear_resolved(state, names) do
    Enum.reduce(names, state, fn name, acc ->
      if Map.has_key?(acc, name) do
        Logger.info("sandbox env: #{name} resolves again")
        Map.delete(acc, name)
      else
        acc
      end
    end)
  end

  defp note_unresolved(state, unresolved) do
    Enum.reduce(unresolved, state, fn %{name: name, reason: reason}, acc ->
      case Map.get(acc, name) do
        %{reason: ^reason} -> acc
        _new_or_changed -> Map.put(acc, name, note(name, reason))
      end
    end)
  end

  defp note(name, reason) do
    Logger.warning(
      "sandbox env: #{name}: #{Env.format_error(reason)} Sandboxed commands run without it."
    )

    %{name: name, reason: reason, since: DateTime.utc_now()}
  end
end
