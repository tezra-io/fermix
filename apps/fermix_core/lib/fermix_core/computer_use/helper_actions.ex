defmodule FermixCore.ComputerUse.HelperActions do
  @moduledoc """
  Which actions the installed helper says it has, as the tool's schema offers
  them (M86 F1).

  **Why this exists.** The action enum used to be `Compux.Protocol.actions/0`, a
  list compiled into the library, so the model was offered every verb the WIRE
  can carry rather than every verb this HELPER can do. On Linux that is
  `elements`, `inspect`, `press` and `set_value`, which always refuse there. The
  helper already says what it has, in the `actions` of the `hello` it answers at
  the handshake; this process keeps the latest such reading so the schema can be
  built from it on every turn.

  **What it holds.** The intersection of the helper's `actions` with the ones
  this build's library encodes (the library validates at encode, so a verb the
  helper has and the library does not is a verb nobody can send). Until a helper
  has answered, it holds nothing, and what is offered is `pixel/0`: the actions
  every helper this build pairs with has had. Never the full list: offering a
  control the helper may not have is the defect this replaces.

  **Where the reading comes from.** Once at boot, when computer use is enabled,
  from a one-shot spawn of the installed helper (`Capabilities.read/1`, the same
  read `fermix doctor` makes). It runs in a task, so boot neither waits on the
  helper nor fails because of it, and a read that fails is logged and leaves the
  holder as it was. Then again at every session's handshake: the `Session`
  records what its own helper answered, which costs nothing (the transport
  answers a second `hello` from its cached identity). A session's reading is
  newer than the boot read by construction, so a boot answer that lands after one
  is dropped.

  Not running (computer use disabled, so no CU tree) answers `pixel/0` and
  records nothing — the same shape `CaptureHealth` and `OperatorStop` use for the
  same reason. The tool is not registered at all in that state.
  """

  use GenServer

  alias Compux.Protocol
  alias FermixCore.ComputerUse.Capabilities

  require Logger

  # Named once (M86 F1): the pointer, keyboard, clipboard and capture verbs every
  # paired helper has had on every system. Offered before any helper has
  # answered, and nothing that reaches a control through accessibility or binds a
  # window is in it.
  @pixel ~w(screenshot left_click right_click double_click mouse_move left_click_drag scroll
            type key wait wait_for_change paste windows)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The actions offered before any helper has answered."
  @spec pixel() :: [String.t()]
  def pixel, do: encodable(@pixel)

  @doc """
  The actions of `actions` this build's library encodes, in the library's order,
  so a schema built from them is stable whatever order a helper listed them in.
  """
  @spec encodable([String.t()]) :: [String.t()]
  def encodable(actions) when is_list(actions),
    do: Enum.filter(Protocol.actions(), &(&1 in actions))

  @doc """
  The actions the tool may offer: the latest reading, or `pixel/0` until there
  is one. The bound-window flag is applied by the tool, after this.
  """
  @spec offered(GenServer.server()) :: [String.t()]
  def offered(server \\ __MODULE__) do
    GenServer.call(server, :offered)
  catch
    # No CU tree: nothing has been read, so nothing beyond the pixel set is
    # known. Documented above.
    :exit, {:noproc, _call} -> pixel()
  end

  @doc """
  Record the `actions` a session's helper listed in its `hello`. Replaces the
  reading: the latest helper to answer is the one installed. A list with nothing
  this build encodes is logged and leaves the reading as it was.
  """
  @spec record([String.t()], GenServer.server()) :: :ok
  def record(actions, server \\ __MODULE__) when is_list(actions) do
    GenServer.call(server, {:record, actions})
  catch
    :exit, {:noproc, _call} -> :ok
  end

  @impl true
  def init(opts) do
    if Keyword.fetch!(opts, :read_at_boot?) do
      start_boot_read(
        Keyword.get(opts, :task_supervisor, FermixCore.TaskSupervisor),
        Keyword.get(opts, :read, &Capabilities.read/0)
      )
    end

    {:ok, %{offered: nil}}
  end

  @impl true
  def handle_call(:offered, _from, %{offered: nil} = state), do: {:reply, pixel(), state}
  def handle_call(:offered, _from, state), do: {:reply, state.offered, state}

  def handle_call({:record, actions}, _from, state),
    do: {:reply, :ok, take_reading(state, actions)}

  @impl true
  def handle_info({:boot_read, {:ok, capabilities}}, %{offered: nil} = state),
    do: {:noreply, take_reading(state, capabilities.actions)}

  def handle_info({:boot_read, {:ok, _capabilities}}, state) do
    Logger.debug("computer_use: a session read the helper first; the boot reading is dropped")
    {:noreply, state}
  end

  def handle_info({:boot_read, {:error, reason}}, state) do
    Logger.warning(
      "computer_use: could not read which actions the computer-use helper offers at boot, " <>
        "so the tool's offer stays as it was: " <> inspect(reason)
    )

    {:noreply, state}
  end

  # A reading with nothing this build encodes teaches nothing about the helper,
  # and offering it would be a schema whose action enum is empty, which providers
  # refuse. So it is a read that failed: logged, and the offer stays as it was —
  # which also leaves room for a boot answer still on its way.
  defp take_reading(state, actions) do
    case encodable(actions) do
      [] ->
        Logger.warning(
          "computer_use: the computer-use helper offers no action this build encodes " <>
            "(#{inspect(actions)}), so the tool's offer stays as it was"
        )

        state

      offered ->
        %{state | offered: offered}
    end
  end

  # The read runs under the task supervisor, unlinked, and sends its answer here.
  # A read that crashes sends nothing — the task supervisor logs the crash — and
  # the holder keeps what it had, which is the conservative answer.
  defp start_boot_read(task_supervisor, read) do
    holder = self()
    read_and_answer = fn -> send(holder, {:boot_read, read.()}) end

    case Task.Supervisor.start_child(task_supervisor, read_and_answer) do
      {:ok, _task} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "computer_use: could not start reading which actions the computer-use helper " <>
            "offers at boot: " <> inspect(reason)
        )
    end
  end
end
