defmodule FermixChannels.Desktop.LoopbackForward do
  @moduledoc """
  The primary's half of the sign-in loopback forward (M75 D17, §9): the
  `loopback` family of a connected desktop (`Desktop.Family`).

  Every OAuth sign-in listens on this engine's `127.0.0.1`
  (`FermixCore.Auth.LoopbackRegistry`). One a desktop started over the rail
  (its management call carried the actor `{:desktop, device_id}`) opens its
  authorize url in that desktop's browser, so the provider's redirect lands on
  the desktop. While the listener is open, this family tells the desktop to
  listen on the same port (`loopback_open`, for as long as the listener has
  left, at most 900 s), and closes it there when the listener closes
  (`loopback_close`): the sign-in ended, failed or expired.

  Each request the desktop's browser makes there arrives as
  `loopback_request` and is replayed, as it came, against this engine's own
  listener (`LoopbackHttp.replay/4`), so no provider changes; its answer goes
  back as `loopback_response`. At most 8 requests per loopback; a ninth is
  answered `429` without reaching the listener, and a request for a loopback
  that has ended `410`. A replay runs in a task of its own, so the desktop's
  session never waits on it.

  A desktop that cannot listen on a port says so (`loopback_failed`), and the
  sign-in ends with that sentence (`LoopbackRegistry.fail/3`).

  The family subscribes the desktop's peer to the registry when it starts, so
  a sign-in already open when the desktop reconnects is opened there again.
  Test seams, the family's options (`Desktop.Peer`'s `{module, options}`):
  `:loopback_registry`, `:device_name`, `:send` (in place of
  `Desktop.Peer.send/4`), `:replay` (in place of `LoopbackHttp.replay/4`),
  `:task_supervisor`, `:now`.
  """

  @behaviour FermixChannels.Desktop.Family

  require Logger

  alias FermixChannels.Desktop.LoopbackHttp
  alias FermixChannels.Desktop.Peer
  alias FermixChannels.Mobile.DeviceStore
  alias FermixCore.Auth.LoopbackRegistry

  @max_requests 8
  @peers FermixChannels.Desktop.Peers
  @max_open_s 900
  @replay_timeout_ms 30_000
  @reasons %{
    "port_in_use" => :port_in_use,
    "not_permitted" => :not_permitted,
    "failed" => :failed
  }

  @doc "The most requests one loopback forwards."
  @spec max_requests() :: pos_integer()
  def max_requests, do: @max_requests

  @doc "The reasons a desktop gives for a port it could not listen on, by their wire word."
  @spec failure_reasons() :: [String.t()]
  def failure_reasons, do: Map.keys(@reasons)

  @impl true
  def init(context) do
    options = Map.get(context, :options, [])

    state = %{
      device_id: context.device_id,
      peers: Map.get(context, :registry) || @peers,
      device_name: Keyword.get(options, :device_name),
      registry: Keyword.get(options, :loopback_registry, LoopbackRegistry),
      send: Keyword.get(options, :send, &Peer.send/4),
      replay: Keyword.get(options, :replay, &LoopbackHttp.replay/3),
      task_supervisor: Keyword.get(options, :task_supervisor, FermixCore.TaskSupervisor),
      now: Keyword.get(options, :now, &DateTime.utc_now/0),
      loopbacks: %{}
    }

    {:ok, entries} =
      LoopbackRegistry.subscribe(&{:desktop_family, :loopback, &1}, state.registry)

    {:ok, Enum.reduce(entries, state, &opened/2)}
  end

  @impl true
  def handle_event("loopback_request", fields, body, state) do
    %{"loopback_id" => id, "request_id" => request_id} = fields

    case Map.fetch(state.loopbacks, id) do
      :error ->
        answer(state, request_id, 410, "This sign-in has ended.")
        {:ok, state}

      {:ok, %{requests: count}} when count >= @max_requests ->
        answer(state, request_id, 429, "This sign-in has had all the requests it takes.")
        {:ok, state}

      {:ok, loopback} ->
        replay(state, loopback.port, request_id, request(fields, body))
        {:ok, put_in(state.loopbacks[id].requests, loopback.requests + 1)}
    end
  end

  def handle_event("loopback_failed", %{"loopback_id" => id} = fields, _body, state) do
    failure = %{
      desktop: name(state),
      port: fields["port"],
      reason: Map.fetch!(@reasons, fields["reason"])
    }

    case LoopbackRegistry.fail(id, failure, state.registry) do
      :ok -> {:ok, state}
      {:error, :unknown_loopback} -> {:ok, state}
    end
  end

  @impl true
  def handle_info({:opened, entry}, state), do: {:ok, opened(entry, state)}
  def handle_info({:closed, entry}, state), do: {:ok, closed(entry, state)}

  @impl true
  def terminate(_reason, state) do
    :ok = LoopbackRegistry.unsubscribe(state.registry)
  catch
    :exit, _registry_gone -> :ok
  end

  # A listener of this desktop's sign-in: opened there for the time it has
  # left. Any other caller's is not this desktop's business.
  defp opened(%{owner: {:desktop, device_id}} = entry, %{device_id: device_id} = state) do
    expires_in = DateTime.diff(entry.expires_at, state.now.(), :second)

    if expires_in > 0 do
      event = %{
        "t" => "loopback_open",
        "loopback_id" => entry.id,
        "ports" => [entry.port],
        "expires_in_s" => min(expires_in, @max_open_s)
      }

      tell(state, event)
      put_in(state.loopbacks[entry.id], %{port: entry.port, requests: 0})
    else
      state
    end
  end

  defp opened(_entry, state), do: state

  defp closed(%{id: id}, state) do
    case Map.pop(state.loopbacks, id) do
      {nil, _loopbacks} ->
        state

      {_loopback, loopbacks} ->
        tell(state, %{"t" => "loopback_close", "loopback_id" => id})
        %{state | loopbacks: loopbacks}
    end
  end

  defp request(fields, body) do
    %{
      method: fields["method"],
      target: fields["target"],
      headers: fields["headers"],
      body: body
    }
  end

  defp replay(state, port, request_id, request) do
    job = fn -> respond(state, request_id, state.replay.(port, request, @replay_timeout_ms)) end

    case Task.Supervisor.start_child(state.task_supervisor, job) do
      {:ok, _pid} -> :ok
      {:error, reason} -> Logger.error("loopback forward: no replay: #{inspect(reason)}")
    end
  end

  defp respond(state, request_id, {:ok, %{status: status, headers: headers, body: body}}) do
    if LoopbackHttp.valid_headers?(headers),
      do: response(state, request_id, status, headers, body),
      else: answer(state, request_id, 502, "The sign-in answered in a way Fermix cannot forward.")
  end

  defp respond(state, request_id, {:error, reason}) do
    Logger.warning("loopback forward: the replay of #{request_id} failed: #{inspect(reason)}")
    answer(state, request_id, 502, "The sign-in on the server did not answer.")
  end

  defp answer(state, request_id, status, text) do
    headers = [["Content-Type", "text/plain; charset=utf-8"], ["Cache-Control", "no-store"]]
    response(state, request_id, status, headers, text)
  end

  defp response(state, request_id, status, headers, body) do
    tell(
      state,
      %{
        "t" => "loopback_response",
        "request_id" => request_id,
        "status" => status,
        "headers" => headers
      },
      body
    )
  end

  defp tell(state, event, payload \\ <<>>) do
    case state.send.(state.device_id, event, payload, registry: state.peers) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("loopback forward: #{event["t"]} not sent: #{inspect(reason)}")
    end
  end

  # The desktop's name, read from its row when a sentence needs it. A row
  # that cannot be read is logged, and the sentence names the desktop's id.
  defp name(%{device_name: name}) when is_binary(name), do: name

  defp name(%{device_id: device_id}) do
    case DeviceStore.fetch(DeviceStore, device_id) do
      {:ok, %{name: name}} ->
        name

      {:error, reason} ->
        Logger.error("loopback forward: desktop #{device_id}'s row: #{inspect(reason)}")
        device_id
    end
  end
end
