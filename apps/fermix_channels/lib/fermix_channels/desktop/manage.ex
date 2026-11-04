defmodule FermixChannels.Desktop.Manage do
  @moduledoc """
  The forwarded management family of a desktop session, on the primary
  (M75 §6, B12).

  A desktop's engine sends each Fermix-wide management call its app makes on
  the local `daemon.sock` as one `manage` (its params JSON chunked). The
  primary answers it as its own `daemon.sock` would
  (`Fermix.CLI.Daemon.serve_forwarded/3`): through `Management.Router` with
  the options the daemon passes it and the actor `{:desktop, device_id}`,
  with the authority of the owner's app, since the desktop placed its own
  caller before forwarding (an owner decision such as `mobile.pair.decide`
  included, D16). A device-class request is refused with
  `device_class_method`: it belongs to the desktop. The response goes back as
  `manage_result`, the envelope exactly as `daemon.sock` writes it.

  Each call runs in a task of its own (`:task_supervisor`), never in the
  desktop's peer; at most 8 run at once for one desktop, and a ninth, or a
  call id already running, is answered at once with the management error
  that says so (`busy`, `invalid_request`).

  A test names its seams as the family's options (`Desktop.Peer`'s
  `{module, options}`): `:serve` (in place of the daemon's
  `serve_forwarded/3`, a function of the request frame and the device id) and
  `:task_supervisor`.
  """

  @behaviour FermixChannels.Desktop.Family

  require Logger

  alias Fermix.CLI.Daemon
  alias FermixChannels.Desktop.Peer
  alias FermixCore.Management.Protocol, as: ManagementProtocol

  @max_in_flight 8

  @doc "The most forwarded calls one desktop has running at once."
  @spec max_in_flight() :: pos_integer()
  def max_in_flight, do: @max_in_flight

  @impl true
  def init(%{device_id: device_id, registry: registry} = context) do
    opts = Map.get(context, :options, [])

    {:ok,
     %{
       device_id: device_id,
       registry: registry,
       serve: Keyword.get(opts, :serve, &serve_with_daemon/2),
       task_supervisor: Keyword.get(opts, :task_supervisor, FermixCore.TaskSupervisor),
       running: MapSet.new()
     }}
  end

  @impl true
  def handle_event("manage", %{"call_id" => call_id} = fields, params, state) do
    cond do
      MapSet.member?(state.running, call_id) ->
        answer(state, call_id, refusal(call_id, :invalid_request, %{"field" => "call_id"}))
        {:ok, state}

      MapSet.size(state.running) >= @max_in_flight ->
        busy = %{"operation" => "forwarded management", "limit" => @max_in_flight}
        answer(state, call_id, refusal(call_id, :busy, busy))
        {:ok, state}

      true ->
        {:ok, start_call(call_id, fields, params, state)}
    end
  end

  @impl true
  def handle_info({:call_done, call_id}, state),
    do: {:ok, %{state | running: MapSet.delete(state.running, call_id)}}

  def handle_info(message, state) do
    Logger.debug("desktop manage family ignored #{inspect(message)}")
    {:ok, state}
  end

  @impl true
  def terminate(_reason, _state), do: :ok

  defp start_call(call_id, fields, params, state) do
    %{device_id: device_id, registry: registry, serve: serve} = state

    job = fn ->
      try do
        answer(state, call_id, call(call_id, fields, params, device_id, serve))
      after
        Peer.tell(device_id, :manage, {:call_done, call_id}, registry: registry)
      end
    end

    case Task.Supervisor.start_child(state.task_supervisor, job) do
      {:ok, _pid} ->
        %{state | running: MapSet.put(state.running, call_id)}

      {:error, reason} ->
        Logger.error("desktop manage: call #{call_id} could not start: #{inspect(reason)}")
        answer(state, call_id, refusal(call_id, :internal_error, %{}))
        state
    end
  end

  # The request as `daemon.sock` would read it: the call id is its request id.
  defp call(
         call_id,
         %{"method" => method, "protocol_version" => version},
         params,
         device_id,
         serve
       ) do
    case Jason.decode(params) do
      {:ok, %{} = decoded} ->
        frame =
          Jason.encode!(%{
            "request_id" => call_id,
            "protocol_version" => version,
            "method" => method,
            "params" => decoded
          })

        serve.(frame, device_id)

      _not_an_object ->
        refusal(call_id, :invalid_params, %{"field" => "params"})
    end
  end

  defp serve_with_daemon(frame, device_id) do
    Daemon.serve_forwarded(frame, device_id)
  catch
    :exit, reason ->
      Logger.error(
        "desktop manage: the daemon did not answer a forwarded call: #{inspect(reason)}"
      )

      {:ok, %{"request_id" => request_id}} = Jason.decode(frame)
      refusal(request_id, :internal_error, %{})
  end

  defp refusal(call_id, code, details) do
    {:ok, response} = ManagementProtocol.respond(call_id, {:error, code, details})
    response
  end

  # A response past the wire's 4 MiB cannot travel; the desktop hears that it
  # could not be completed rather than nothing.
  defp answer(state, call_id, response) do
    event = %{"t" => "manage_result", "call_id" => call_id}

    case Peer.send(state.device_id, event, Jason.encode!(response), registry: state.registry) do
      :ok ->
        :ok

      {:error, {:payload_too_large, _type, _size, _bound}} ->
        too_large(state, call_id, event)

      {:error, reason} ->
        Logger.warning("desktop manage: #{call_id} not answered: #{inspect(reason)}")
    end
  end

  defp too_large(state, call_id, event) do
    Logger.error("desktop manage: the answer to #{call_id} is past the wire's bound")
    payload = Jason.encode!(refusal(call_id, :internal_error, %{}))
    _ = Peer.send(state.device_id, event, payload, registry: state.registry)
    :ok
  end
end
