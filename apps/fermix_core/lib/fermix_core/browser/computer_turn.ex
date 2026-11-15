defmodule FermixCore.Browser.ComputerTurn do
  @moduledoc """
  A turn's browser on the home's computers, on the server (M97 §6.4). One
  process per turn that used a computer's browser, by the turn's process
  (`turn/1`: the loop context's `:turn_pid` where a turn runs each tool call
  in a process of its own, as a voice call does, else the process making
  the call, since the agent loop runs its tools inline), holding two facts
  and a duty:

    * **where the turn's browser runs** (`continues_on/2`): the computer its
      last browser call ran on. A later call that names no computer runs
      there (`Computers.Choice`, through the capability's `continues_on/1`),
      so a task that started in a computer's browser is never carried on in
      the server's own browser, silently, mid-task; one that names another
      computer moves the task there, in its own words;
    * **every computer the turn's browser used**, each told when the turn
      ends (`browser.end`), normally or not, so that computer ends the turn's
      pane task as the end of a turn here ends one, and keeps it for the
      conversation's next turn only after a normal end that handed the tabs
      over (`Browser.HeldTurn`, on the computer). That computer's own bound
      ends it when the notice never arrives.

  The fact is the registry's value, read without a call; the process exists
  only while its turn does, and ends after the notices.
  """

  use GenServer, restart: :temporary

  require Logger

  alias FermixCore.Computers
  alias FermixCore.Computers.Capabilities.Browser, as: BrowserCapability
  alias FermixCore.Computers.Computer
  alias FermixCore.Computers.Outcome

  @notice_deadline_ms 10_000
  # What the notice needs of the turn's context to name its turn and origin
  # (`Computers.Origin.of/1`), and nothing more.
  @notice_keys [
    :session_id,
    :computer_use_origin,
    :trigger,
    :subagent_depth,
    :skill_depth,
    :harness_continuation_depth,
    :source_trust
  ]

  @typedoc "Where the turns live: their registry and their supervisor."
  @type seams :: %{registry: atom(), supervisor: atom()}

  @doc """
  The process that is the turn of the loop context `context` (the
  moduledoc): its `:turn_pid` (a voice call, whose tool calls each run in a
  process of their own), else the calling process.
  """
  @spec turn(map()) :: pid()
  def turn(%{turn_pid: turn}) when is_pid(turn), do: turn
  def turn(context) when is_map(context), do: self()

  @doc """
  The turn `turn` ran a browser call on `computer`, with the loop context
  `context` (its call options included): that computer is where its browser
  runs from now on, and it is told when the turn ends.
  """
  @spec used(seams(), pid(), Computer.t(), map()) :: :ok
  def used(%{registry: _, supervisor: _} = seams, turn, %Computer{} = computer, context)
      when is_pid(turn) and is_map(context) do
    notice = %{
      context: Map.take(context, @notice_keys),
      call_opts: Map.get(context, :computer_call_opts, [])
    }

    GenServer.call(ensure(seams, turn), {:used, computer, notice})
  end

  @doc "The device id of the computer `turn`'s browser runs on, or nil."
  @spec continues_on(seams(), pid()) :: String.t() | nil
  def continues_on(%{registry: registry}, turn) when is_pid(turn) do
    case Registry.lookup(registry, key(turn)) do
      [{_pid, device_id}] -> device_id
      [] -> nil
    end
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    registry = Keyword.fetch!(opts, :registry)
    turn = Keyword.fetch!(opts, :turn)
    name = {:via, Registry, {registry, key(turn), nil}}
    GenServer.start_link(__MODULE__, {registry, turn}, name: name)
  end

  @impl true
  def init({registry, turn}) do
    {:ok, %{registry: registry, turn: turn, ref: Process.monitor(turn), used: %{}, notice: nil}}
  end

  @impl true
  def handle_call({:used, %Computer{device_id: device} = computer, notice}, _from, state) do
    {_old, _new} = Registry.update_value(state.registry, key(state.turn), fn _ -> device end)
    {:reply, :ok, %{state | used: Map.put(state.used, device, computer), notice: notice}}
  end

  # The turn ended: each computer its browser used hears it, then this ends.
  # Nothing calls this process once its turn is gone, so the notices may wait.
  @impl true
  def handle_info({:DOWN, ref, :process, _turn, reason}, %{ref: ref} = state) do
    ending = if reason == :normal, do: "ended", else: "stopped"
    Enum.each(state.used, fn {_device, computer} -> notify(computer, ending, state.notice) end)
    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp notify(computer, ending, notice) do
    opts = Keyword.put(notice.call_opts, :deadline_ms, @notice_deadline_ms)

    case Computers.call(
           computer,
           BrowserCapability,
           "browser.end",
           %{"turn" => ending},
           notice.context,
           opts
         ) do
      {:ok, _outcome} ->
        :ok

      {:error, %Outcome{} = outcome} ->
        Logger.warning(
          "#{computer.name} was not told a turn's browser ended (#{outcome.status}); " <>
            "it ends the turn there on its own"
        )
    end
  end

  defp ensure(seams, turn) do
    spec = {__MODULE__, registry: seams.registry, turn: turn}

    case DynamicSupervisor.start_child(seams.supervisor, spec) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  defp key(turn), do: {:computer_turn, turn}
end
