defmodule FermixChannels.Desktop.InvokeFamily do
  @moduledoc """
  The server's side of a computer's invocations (M97 §5.2, §6.1), in that
  computer's `Desktop.Peer`: it routes, and waits on nothing itself. The
  waiters are `FermixCore.Computers.Calls`', so a session that ends loses
  none.

  - **A new session reconciles.** As the computer's peer starts (each
    session), it tells `Calls` (`Calls.reconnected/2`), and each caller
    still waiting on the computer asks for its invocation's state
    (`invoke_status`) once it has sent the request, never before: the ask
    and the request come from one process, in that order. Each answer comes
    back as any other.
  - **`invoke_result`** (put back together by the peer) goes to `Calls`.
  - **`invoke_part`** frames are put back together here, one part per
    invocation, at most 20 MiB each and #{64} MiB across the computer's;
    one with a gap, a frame past its announced size or a size that changes
    is told failed ("The answer's file did not arrive whole.") and its later
    frames dropped, and the session stays open. Its progress is told every
    #{16} frames, and its bytes once whole.
  - **`invoke_open`** from the computer asks one of the home's services
    (`:services`: `system`, and `history.submit`, a finished sitting of
    computer history, M97 §8.1), run in a process of its own, which is told
    the computer that asked, and
    answered with `invoke_result`; `invoke_cancel` and `invoke_status` for
    one are answered as the computer answers its server's.

  Options in the context (a test's seams): `:calls` (the `Calls` server),
  `:services`, `:home` and `:history` (`ComputerHistory.Submission`'s options).
  """

  @behaviour FermixChannels.Desktop.Family

  require Logger

  alias FermixChannels.Desktop.Peer
  alias FermixCore.ComputerHistory.HomeService, as: HistoryService
  alias FermixCore.Computers.Calls
  alias FermixCore.Computers.Capabilities.System, as: SystemCapability
  alias FermixCore.Computers.Origin
  alias FermixCore.Computers.Outcome
  alias FermixCore.Computers.Telemetry
  alias FermixCore.Setup.ConfigStore

  @services %{"system" => SystemCapability, "history" => HistoryService}
  @max_part_bytes 20 * 1_024 * 1_024
  @max_parts_bytes 64 * 1_024 * 1_024
  @progress_every 16
  @lost_part "The answer's file did not arrive whole."

  @impl true
  def init(%{device_id: device_id, registry: registry} = context) do
    options = context.options

    state = %{
      device_id: device_id,
      registry: registry,
      calls: Keyword.get(options, :calls, Calls),
      services: Keyword.get(options, :services, @services),
      history: Keyword.get(options, :history, []),
      home: Keyword.get_lazy(options, :home, &ConfigStore.fermix_home/0),
      parts: %{},
      running: %{}
    }

    :ok = reconcile(state)
    {:ok, state}
  end

  @impl true
  def handle_event("invoke_result", %{"id" => id} = fields, payload, state) do
    :ok = Calls.deliver(state.calls, state.device_id, id, {fields, payload})
    {:ok, state}
  end

  def handle_event("invoke_part", fields, bytes, state), do: {:ok, part(fields, bytes, state)}

  def handle_event("invoke_open", fields, payload, state),
    do: {:ok, serve(fields, payload, state)}

  def handle_event("invoke_cancel", %{"id" => id}, _payload, state), do: {:ok, cancel(id, state)}
  def handle_event("invoke_status", %{"id" => id}, _payload, state), do: {:ok, status(id, state)}

  @impl true
  def handle_info({:service_done, id}, state),
    do: {:ok, %{state | running: Map.delete(state.running, id)}}

  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _state), do: :ok

  # -- a new session ---------------------------------------------------------------

  # Every caller still waiting on this computer is told, and asks for its own
  # invocation once its request is sent; a Calls that does not answer leaves
  # its waiters to their deadlines, said once.
  defp reconcile(state) do
    Calls.reconnected(state.calls, state.device_id)
  catch
    :exit, reason ->
      Logger.error(
        "computer #{state.device_id}: its invocations were not asked again: #{inspect(reason)}"
      )

      :ok
  end

  # -- an answer's part ----------------------------------------------------------------

  defp part(%{"id" => id, "index" => index, "last" => last, "size_bytes" => size}, bytes, state) do
    current =
      Map.get(state.parts, id, %{next: 0, size: size, received: 0, chunks: [], failed: false})

    received = current.received + byte_size(bytes)

    cond do
      current.failed ->
        drop_failed(id, last, state)

      index != current.next or size != current.size ->
        lost(id, last, state)

      received > size or size > @max_part_bytes ->
        lost(id, last, state)

      held(state) + byte_size(bytes) > @max_parts_bytes ->
        lost(id, last, state)

      true ->
        took(
          id,
          %{current | next: index + 1, received: received, chunks: [bytes | current.chunks]},
          last,
          state
        )
    end
  end

  defp took(id, current, false, state) do
    if rem(current.next, @progress_every) == 0,
      do:
        :ok =
          Calls.part(
            state.calls,
            state.device_id,
            id,
            {:progress, current.received, current.size}
          )

    %{state | parts: Map.put(state.parts, id, current)}
  end

  defp took(id, current, true, state) do
    bytes = current.chunks |> Enum.reverse() |> IO.iodata_to_binary()
    message = if byte_size(bytes) == current.size, do: {:done, bytes}, else: {:error, @lost_part}
    :ok = Calls.part(state.calls, state.device_id, id, message)
    %{state | parts: Map.delete(state.parts, id)}
  end

  defp lost(id, last, state) do
    Logger.warning("invocation #{id}: its answer's file did not arrive whole")
    :ok = Calls.part(state.calls, state.device_id, id, {:error, @lost_part})
    failed = %{next: 0, size: 0, received: 0, chunks: [], failed: true}
    drop_failed(id, last, %{state | parts: Map.put(state.parts, id, failed)})
  end

  # A failed part's later frames are dropped until its last.
  defp drop_failed(id, true, state), do: %{state | parts: Map.delete(state.parts, id)}
  defp drop_failed(_id, false, state), do: state

  defp held(state),
    do: Enum.reduce(state.parts, 0, fn {_id, part}, sum -> sum + part.received end)

  # -- the home's services ---------------------------------------------------------------

  defp serve(%{"id" => id} = fields, payload, state) do
    module = Map.get(state.services, fields["capability"])
    meta = meta(fields)
    :ok = Telemetry.started(meta)

    case service_args(module, fields["op"], payload) do
      {:ok, args} -> run_service(module, args, fields, meta, state)
      {:error, outcome} -> answered(id, outcome, meta, state)
    end
  end

  defp service_args(nil, _op, _payload), do: {:error, unknown()}

  defp service_args(module, op, payload) do
    with true <- op in module.ops(),
         {:ok, %{} = args} <- Jason.decode(payload),
         :ok <- module.validate(op, args) do
      {:ok, args}
    else
      false ->
        {:error, unknown()}

      {:error, sentence} when is_binary(sentence) ->
        {:error, %Outcome{status: :failed, message: sentence}}

      _not_an_object ->
        {:error,
         %Outcome{status: :failed, message: "The request's arguments are not a JSON object."}}
    end
  end

  defp unknown,
    do: Outcome.refused(:unavailable, "Fermix on this server does not know how to do that.")

  # Run in a process of its own, which answers and tells the family it is
  # done.
  defp run_service(module, args, %{"id" => id, "op" => op} = fields, meta, state) do
    context = %{
      id: id,
      computer: state.device_id,
      history: state.history,
      origin: :computer,
      epoch: fields["epoch"],
      turn: nil,
      home: state.home,
      switches: [],
      clock: &DateTime.utc_now/0,
      deadline_ms: fields["deadline_ms"]
    }

    device_id = state.device_id
    registry = state.registry
    started = System.monotonic_time(:millisecond)

    {:ok, pid} =
      Task.start(fn ->
        outcome = service_outcome(module.run(op, args, nil, context))
        duration = System.monotonic_time(:millisecond) - started
        :ok = send_answer(device_id, registry, id, %{outcome | duration_ms: duration}, meta)
        Peer.tell(device_id, :invoke, {:service_done, id}, registry: registry)
      end)

    %{state | running: Map.put(state.running, id, %{pid: pid, meta: meta})}
  end

  defp service_outcome({:ok, result, nil}), do: %Outcome{status: :ok, result: result}
  defp service_outcome({:failed, sentence}), do: %Outcome{status: :failed, message: sentence}
  defp service_outcome({:refused, refusal, sentence}), do: Outcome.refused(refusal, sentence)

  defp service_outcome(other) do
    Logger.error("a home service answered #{inspect(other)}")
    %Outcome{status: :failed, message: "It answered in a way this server cannot send."}
  end

  defp cancel(id, state) do
    case Map.pop(state.running, id) do
      {nil, _running} ->
        status(id, state)

      {%{pid: pid, meta: meta}, running} ->
        Process.exit(pid, :kill)
        answered(id, %Outcome{status: :cancelled}, meta, %{state | running: running})
    end
  end

  # A service still running answers when it ends; the server holds no
  # answer once sent, so any other is not known.
  defp status(id, state) do
    if Map.has_key?(state.running, id) do
      state
    else
      :ok =
        send_wire(
          state.device_id,
          state.registry,
          %{"id" => id, "status" => "unknown", "duration_ms" => 0},
          "{}"
        )

      state
    end
  end

  defp answered(id, outcome, meta, state) do
    :ok = send_answer(state.device_id, state.registry, id, outcome, meta)
    state
  end

  defp send_answer(device_id, registry, id, outcome, meta) do
    {fields, payload} = Outcome.to_wire(%{outcome | invocation: id})
    :ok = Telemetry.finished(meta, outcome, byte_size(payload))
    send_wire(device_id, registry, fields, payload)
  end

  defp send_wire(device_id, registry, fields, payload) do
    case Peer.send(device_id, Map.put(fields, "t", "invoke_result"), payload, registry: registry) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("invocation #{fields["id"]}: its answer was not sent: #{inspect(reason)}")
    end
  end

  defp meta(fields) do
    {:ok, origin} = Origin.from_wire(fields["origin"])

    %{
      id: fields["id"],
      capability: fields["capability"],
      op: fields["op"],
      origin: origin,
      epoch: fields["epoch"]
    }
  end
end
