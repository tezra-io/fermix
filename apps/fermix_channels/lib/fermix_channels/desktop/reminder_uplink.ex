defmodule FermixChannels.Desktop.ReminderUplink do
  @moduledoc """
  How a press of Snooze on a reminder's notification on this computer reaches
  the reminder, which its server holds (M99 §10.1): one `reminders.snooze`
  invocation toward the home (`FermixCore.Temporal.NotificationSnooze`), sent
  through this computer's relay with origin `computer`, and its
  `invoke_result` waited for here, in a process of its own, so the press never
  holds the Fermix app's native host connection that carried it.

  - `snooze/3` hands the press over and returns at once: a cast, never a
    call, since the native host connection that makes it serves the app's
    calls. Only a computer linked to its server runs this process; with none
    running the press is `{:error, :not_running}`.
  - At most #{16} snoozes are in flight; past that a press is dropped and
    logged (`busy`). Each is sent by a task of its own (the relay's send waits
    for its lane), with a deadline of #{15} s on the server and a timer here
    #{5} s past it: past that it asks the server to cancel, naming the
    request's capability and op, and says so in the log.
  - `answer/4`, which `Desktop.Invoke.Admission` calls with every answer the
    home sends whose id starts `snz-`, hands it here; the server's answer is
    logged, a snooze it refused in its own words.

  Options (a test's seams): `:name`, `:relay`, `:tasks` (the
  `Task.Supervisor` the sends run under), `:send` (3-arity, in place of
  `Relay.send_event/3`), `:epoch` (0-arity, the link's epoch, in place of
  `Relay.status/1`'s) and `:timer` (2-arity, `Process.send_after/3` to this
  process).
  """

  use GenServer

  require Logger

  alias FermixChannels.Desktop.Relay
  alias FermixCore.Computers.Outcome

  @deadline_ms 15_000
  @margin_ms 5_000
  @max_in_flight 16

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc """
  Hands over the press that snoozes `reminder_id` by `minutes`, and returns at
  once: `{:error, :not_running}` when no uplink runs (this computer is not
  linked to a server).
  """
  @spec snooze(String.t(), pos_integer(), GenServer.server()) :: :ok | {:error, :not_running}
  def snooze(reminder_id, minutes, server \\ __MODULE__)
      when is_binary(reminder_id) and reminder_id != "" and is_integer(minutes) and minutes > 0 do
    case GenServer.whereis(server) do
      nil ->
        {:error, :not_running}

      pid ->
        GenServer.cast(pid, {:snooze, reminder_id, minutes})
    end
  end

  @doc """
  The home's answer to a snooze this computer sent, handed on to the uplink;
  `:unknown` when none runs.
  """
  @spec answer(String.t(), map(), binary(), GenServer.server()) :: :ok | :unknown
  def answer(id, fields, payload, server \\ __MODULE__)
      when is_binary(id) and is_map(fields) and is_binary(payload) do
    case GenServer.whereis(server) do
      nil ->
        :unknown

      pid ->
        send(pid, {:answer, id, fields, payload})
        :ok
    end
  end

  @doc false
  # The `invoke_open` of one snooze under `epoch`, with an id never used
  # before, in the wire's alphabet. Public so its test holds it against the
  # codec.
  @spec request(pos_integer(), String.t()) :: map()
  def request(epoch, id \\ mint_id()) when is_integer(epoch) and epoch > 0 and is_binary(id) do
    %{
      "t" => "invoke_open",
      "id" => id,
      "capability" => "reminders",
      "op" => "snooze",
      "deadline_ms" => @deadline_ms,
      "epoch" => epoch,
      "origin" => "computer"
    }
  end

  @impl true
  def init(opts) do
    relay = Keyword.get(opts, :relay, Relay)

    {:ok,
     %{
       relay: relay,
       tasks: Keyword.get(opts, :tasks, FermixCore.TaskSupervisor),
       send: Keyword.get(opts, :send, &Relay.send_event/3),
       epoch: Keyword.get(opts, :epoch, fn -> link_epoch(relay) end),
       timer: Keyword.get(opts, :timer, &Process.send_after(self(), &1, &2)),
       in_flight: %{},
       sending: %{}
     }}
  end

  @impl true
  def handle_cast({:snooze, reminder_id, minutes}, state) do
    if map_size(state.in_flight) < @max_in_flight do
      {:noreply, sent(reminder_id, minutes, state)}
    else
      Logger.warning(
        "reminder #{reminder_id} was not snoozed: #{@max_in_flight} snoozes already wait on " <>
          "the server"
      )

      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:answer, id, fields, payload}, state) do
    case Map.pop(state.in_flight, id) do
      {nil, _in_flight} ->
        Logger.warning(
          "snooze #{id}: an answer came for a snooze this computer is not waiting on"
        )

        {:noreply, state}

      {snooze, in_flight} ->
        _left = Process.cancel_timer(snooze.timer)
        :ok = answered(snooze, fields, payload)
        {:noreply, %{state | in_flight: in_flight}}
    end
  end

  def handle_info({:deadline, id}, state) do
    case Map.pop(state.in_flight, id) do
      {nil, _in_flight} ->
        {:noreply, state}

      {snooze, in_flight} ->
        Logger.warning(
          "reminder #{snooze.reminder_id} was not snoozed: the server did not answer in time"
        )

        :ok = cancel(id, state)
        {:noreply, %{state | in_flight: in_flight}}
    end
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.pop(state.sending, ref) do
      {nil, _sending} ->
        {:noreply, state}

      {id, sending} ->
        Process.demonitor(ref, [:flush])
        {:noreply, sent_result(id, result, %{state | sending: sending})}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.sending, ref) do
      {nil, _sending} ->
        {:noreply, state}

      {id, sending} ->
        {:noreply, sent_result(id, {:error, {:exit, reason}}, %{state | sending: sending})}
    end
  end

  def handle_info(message, state) do
    Logger.debug("the reminder uplink ignored #{inspect(message)}")
    {:noreply, state}
  end

  # -- sending ---------------------------------------------------------------------------

  defp sent(reminder_id, minutes, state) do
    id = mint_id()
    timer = state.timer.({:deadline, id}, @deadline_ms + @margin_ms)
    %{send: send, relay: relay, epoch: epoch} = state
    args = Jason.encode!(%{"reminder_id" => reminder_id, "minutes" => minutes})

    task =
      Task.Supervisor.async_nolink(state.tasks, fn -> send_open(send, relay, epoch, id, args) end)

    snooze = %{reminder_id: reminder_id, minutes: minutes, timer: timer}

    %{
      state
      | in_flight: Map.put(state.in_flight, id, snooze),
        sending: Map.put(state.sending, task.ref, id)
    }
  end

  defp send_open(send, relay, epoch, id, args) do
    with {:ok, epoch} <- epoch.(), do: send.(relay, request(epoch, id), args)
  end

  defp sent_result(_id, :ok, state), do: state

  # Not sent: nothing reached the server, and nothing waits for its answer.
  defp sent_result(id, {:error, reason}, state) do
    case Map.pop(state.in_flight, id) do
      {nil, _in_flight} ->
        state

      {snooze, in_flight} ->
        _left = Process.cancel_timer(snooze.timer)

        Logger.warning(
          "reminder #{snooze.reminder_id} was not snoozed: the press was not sent to the " <>
            "server: #{inspect(reason, limit: 5, printable_limit: 200)}"
        )

        %{state | in_flight: in_flight}
    end
  end

  # The request's own cancel, naming its capability and op so it rides the
  # same lane, sent beside this process.
  defp cancel(id, state) do
    %{send: send, relay: relay} = state
    event = %{"t" => "invoke_cancel", "id" => id, "capability" => "reminders", "op" => "snooze"}

    {:ok, _pid} =
      Task.Supervisor.start_child(state.tasks, fn ->
        case send.(relay, event, <<>>) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.info("snooze #{id}: the cancel was not sent: #{inspect(reason)}")
        end
      end)

    :ok
  end

  defp answered(snooze, fields, payload) do
    case Outcome.from_wire(fields, payload) do
      {:ok, %Outcome{status: :ok, result: result}} ->
        Logger.info(
          "reminder #{snooze.reminder_id} snoozed #{snooze.minutes} minutes on the server " <>
            "(#{inspect(result["status"])})"
        )

      {:ok, %Outcome{} = outcome} ->
        Logger.warning(
          "reminder #{snooze.reminder_id} was not snoozed: " <>
            Outcome.sentence(outcome, "the server")
        )

      {:error, reason} ->
        Logger.warning(
          "reminder #{snooze.reminder_id}: the server's answer could not be read: " <>
            inspect(reason)
        )
    end
  end

  defp link_epoch(relay) do
    case Relay.status(relay) do
      %{connected: true, epoch: epoch} when is_integer(epoch) and epoch > 0 -> {:ok, epoch}
      _away -> {:error, :unreachable}
    end
  end

  defp mint_id, do: "snz-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
end
