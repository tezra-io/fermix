defmodule FermixCore.Computers.Calls do
  @moduledoc """
  The invocations the server waits on (M97 §5.2, §6.1), on the primary: the
  one place a computer's answers are routed to the process that asked.

  A caller (`FermixCore.Computers.call/6`) registers each invocation before
  it sends it (`register/2`), with the computer it went to, its capability
  and op, whether it changes something and its deadline, and forgets it
  once answered (`forget/2`). The computer's server-side family
  (`FermixChannels.Desktop.InvokeFamily`) hands each `invoke_result` here
  (`deliver/4`) and each part's progress, bytes or failure (`part/4`); each
  goes to its caller as `{:computer_invoke, id, {:result, fields, payload}}`
  or `{:computer_invoke, id, {:part, message}}`. A word from another
  computer than the one an invocation went to is dropped and logged.

  The waiters live here and not in the session's peer, so a session that
  ends and comes back loses none: as the computer's next session starts,
  its family says so (`reconnected/2`), and each caller still waiting on
  that computer is told `{:computer_invoke, id, :reconnected}`. The caller
  asks for its invocation's state itself (`invoke_status`), once it has
  sent the request: one process sends a request and every status ask about
  it, so the computer is never asked about a request it was not sent yet,
  and never hears the ask before the request (Erlang keeps the order of one
  process's messages to another). The answer comes here as any other.

  It monitors each caller; one that ends without forgetting its invocation
  has the invocation cancelled on the computer (`invoke_cancel`, through the
  transport it registered), best-effort and logged.

  Primary-only (`Home.Role`). If it restarts, its waiters lose their
  routing and time out (an effect's outcome is then `unknown`); the
  computer's journal still holds the truth. Seams: `:name`.
  """

  use GenServer

  require Logger

  alias FermixCore.Computers.Transport

  @typedoc "One invocation waited on."
  @type call :: %{
          required(:id) => String.t(),
          required(:device_id) => String.t(),
          required(:capability) => String.t(),
          required(:op) => String.t(),
          required(:caller) => pid(),
          required(:effect?) => boolean(),
          required(:started_at) => DateTime.t(),
          required(:deadline_at) => DateTime.t() | nil,
          optional(:transport) => Transport.t()
        }

  @typedoc "What the family says of an answer's part."
  @type part_message ::
          {:progress, non_neg_integer(), pos_integer()}
          | {:done, binary()}
          | {:error, String.t()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Waits on `call` for its caller: answered once it is registered."
  @spec register(GenServer.server(), call()) :: :ok
  def register(
        server \\ __MODULE__,
        %{id: id, device_id: device, capability: capability, op: op, caller: caller} = call
      )
      when is_binary(id) and is_binary(device) and is_binary(capability) and is_binary(op) and
             is_pid(caller),
      do: GenServer.call(server, {:register, call})

  @doc """
  The computer `device_id` has a new session: each caller still waiting on
  it is told `{:computer_invoke, id, :reconnected}`, and asks for its
  invocation's state once its request is sent.
  """
  @spec reconnected(GenServer.server(), String.t()) :: :ok
  def reconnected(server \\ __MODULE__, device_id) when is_binary(device_id),
    do: GenServer.call(server, {:reconnected, device_id})

  @doc "The computer `device_id` answered the invocation `id`."
  @spec deliver(GenServer.server(), String.t(), String.t(), {map(), binary()}) :: :ok
  def deliver(server \\ __MODULE__, device_id, id, {fields, payload})
      when is_binary(device_id) and is_binary(id) and is_map(fields) and is_binary(payload),
      do: GenServer.cast(server, {:deliver, device_id, id, {:result, fields, payload}})

  @doc "The part of the invocation `id`'s answer from `device_id`: progress, bytes or failure."
  @spec part(GenServer.server(), String.t(), String.t(), part_message()) :: :ok
  def part(server \\ __MODULE__, device_id, id, message)
      when is_binary(device_id) and is_binary(id),
      do: GenServer.cast(server, {:deliver, device_id, id, {:part, message}})

  @doc """
  The invocations still waited on from the computer `device_id`, their
  requests sent or about to be.
  """
  @spec outstanding(GenServer.server(), String.t()) :: [String.t()]
  def outstanding(server \\ __MODULE__, device_id) when is_binary(device_id),
    do: GenServer.call(server, {:outstanding, device_id})

  @doc "The invocations that change something, still waited on, on any computer."
  @spec running_effects(GenServer.server()) :: [
          %{id: String.t(), device_id: String.t(), started_at: DateTime.t()}
        ]
  def running_effects(server \\ __MODULE__), do: GenServer.call(server, :running_effects)

  @doc "The invocation `id` is answered, or given up on: no more words for it."
  @spec forget(GenServer.server(), String.t()) :: :ok
  def forget(server \\ __MODULE__, id) when is_binary(id),
    do: GenServer.call(server, {:forget, id})

  @impl true
  def init(_opts), do: {:ok, %{calls: %{}, monitors: %{}}}

  @impl true
  def handle_call({:register, call}, _from, state), do: {:reply, :ok, registered(call, state)}

  def handle_call({:outstanding, device_id}, _from, state),
    do: {:reply, ids_on(state, device_id), state}

  def handle_call({:reconnected, device_id}, _from, state),
    do: {:reply, tell_reconnected(state, device_id), state}

  def handle_call(:running_effects, _from, state), do: {:reply, effects(state), state}
  def handle_call({:forget, id}, _from, state), do: {:reply, :ok, dropped(id, state)}

  @impl true
  def handle_cast({:deliver, device_id, id, message}, state) do
    :ok = route(state, device_id, id, message)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _caller, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _monitors} -> {:noreply, state}
      {id, monitors} -> {:noreply, abandoned(id, %{state | monitors: monitors})}
    end
  end

  # -- the waiters ---------------------------------------------------------------

  defp registered(%{id: id, caller: caller} = call, state) do
    ref = Process.monitor(caller)

    %{
      state
      | calls: Map.put(state.calls, id, Map.put(call, :monitor, ref)),
        monitors: Map.put(state.monitors, ref, id)
    }
  end

  defp ids_on(state, device_id),
    do: for({id, %{device_id: ^device_id}} <- state.calls, do: id) |> Enum.sort()

  defp tell_reconnected(state, device_id) do
    for {id, %{device_id: ^device_id, caller: caller}} <- state.calls,
        do: send(caller, {:computer_invoke, id, :reconnected})

    :ok
  end

  defp effects(state) do
    for {id, %{effect?: true} = call} <- state.calls,
        do: %{id: id, device_id: call.device_id, started_at: call.started_at}
  end

  defp route(state, device_id, id, message) do
    case Map.fetch(state.calls, id) do
      {:ok, %{device_id: ^device_id, caller: caller}} ->
        send(caller, {:computer_invoke, id, message})
        :ok

      {:ok, %{device_id: other}} ->
        Logger.warning(
          "computer #{device_id} answered invocation #{id}, which went to computer #{other}: dropped"
        )

      :error ->
        Logger.debug("computer #{device_id} answered invocation #{id}, which nobody waits on")
    end
  end

  defp dropped(id, state) do
    case Map.pop(state.calls, id) do
      {nil, _calls} ->
        state

      {call, calls} ->
        Process.demonitor(call.monitor, [:flush])
        %{state | calls: calls, monitors: Map.delete(state.monitors, call.monitor)}
    end
  end

  # A caller that ended without forgetting its invocation: the computer is
  # told to stop it.
  defp abandoned(id, state) do
    case Map.pop(state.calls, id) do
      {nil, _calls} ->
        state

      {call, calls} ->
        _sent = send_cancel(call)
        %{state | calls: calls}
    end
  end

  defp send_cancel(%{id: id, device_id: device_id} = call) do
    {transport, opts} = Map.get_lazy(call, :transport, &Transport.impl/0)
    about = Map.take(call, [:id, :capability, :op])

    case transport.cancel(device_id, about, opts) do
      :ok ->
        :ok

      {:error, reason} = error ->
        Logger.warning(
          "invocation #{id} on computer #{device_id} was not cancelled: #{inspect(reason)}"
        )

        error
    end
  end
end
