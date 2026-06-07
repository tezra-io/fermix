defmodule FermixCore.Browser.CDP.Connection do
  @moduledoc false

  use WebSockex

  alias FermixCore.Browser.Error

  @spec start_link(String.t(), keyword()) :: GenServer.on_start()
  def start_link(url, opts \\ []) when is_binary(url) and is_list(opts) do
    owner = Keyword.get(opts, :owner, self())

    WebSockex.start_link(url, __MODULE__, %{
      owner: owner,
      next_id: 1,
      pending: %{},
      keepalive_ms: Keyword.fetch!(opts, :keepalive_ms)
    })
  end

  @spec command(pid(), String.t(), map() | nil, String.t() | nil, pos_integer(), pos_integer()) ::
          {:ok, map() | list() | nil} | {:error, Error.t()}
  def command(pid, method, params, session_id, timeout_ms, grace_ms)
      when is_pid(pid) and is_binary(method) and is_integer(timeout_ms) and timeout_ms > 0 and
             is_integer(grace_ms) and grace_ms >= 0 do
    ref = make_ref()
    WebSockex.cast(pid, {:command, self(), ref, method, params, session_id, timeout_ms})

    receive do
      {:cdp_response, ^ref, reply} -> reply
    after
      timeout_ms + grace_ms ->
        {:error, Error.new("cdp_timeout", "CDP command timed out: #{method}")}
    end
  end

  @spec close(pid()) :: :ok
  def close(pid) when is_pid(pid), do: WebSockex.cast(pid, :close)

  @impl true
  def handle_connect(_conn, state) do
    schedule_keepalive(state.keepalive_ms)
    {:ok, state}
  end

  @impl true
  def handle_cast({:command, caller, ref, method, params, session_id, timeout_ms}, state) do
    id = state.next_id
    payload = payload(id, method, params, session_id)
    pending = Map.put(state.pending, id, {caller, ref})
    Process.send_after(self(), {:request_timeout, id, method}, timeout_ms)
    {:reply, {:text, Jason.encode!(payload)}, %{state | next_id: id + 1, pending: pending}}
  end

  def handle_cast(:close, state), do: {:close, state}

  @impl true
  def handle_frame({:text, payload}, state), do: handle_payload(payload, state)
  def handle_frame({:binary, payload}, state), do: handle_payload(payload, state)
  def handle_frame(_frame, state), do: {:ok, state}

  @impl true
  def handle_info(:keepalive, state) do
    schedule_keepalive(state.keepalive_ms)
    {:reply, {:ping, ""}, state}
  end

  def handle_info({:request_timeout, id, method}, state) do
    case Map.pop(state.pending, id) do
      {nil, pending} ->
        {:ok, %{state | pending: pending}}

      {{caller, ref}, pending} ->
        send(
          caller,
          {:cdp_response, ref,
           {:error, Error.new("cdp_timeout", "CDP command timed out: #{method}")}}
        )

        {:ok, %{state | pending: pending}}
    end
  end

  @impl true
  def handle_disconnect(_status, state) do
    Enum.each(state.pending, fn {_id, {caller, ref}} ->
      send(
        caller,
        {:cdp_response, ref, {:error, Error.new("cdp_closed", "CDP connection closed")}}
      )
    end)

    {:ok, %{state | pending: %{}}}
  end

  defp handle_payload(payload, state) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, %{"id" => id} = message} -> handle_response(id, message, state)
      {:ok, %{"method" => method} = event} -> handle_event(method, event, state)
      {:ok, _other} -> {:ok, state}
      {:error, _reason} -> {:ok, state}
    end
  end

  defp handle_response(id, message, state) do
    case Map.pop(state.pending, id) do
      {nil, pending} ->
        {:ok, %{state | pending: pending}}

      {{caller, ref}, pending} ->
        send(caller, {:cdp_response, ref, normalize_response(message)})
        {:ok, %{state | pending: pending}}
    end
  end

  defp handle_event(method, event, state) do
    send(state.owner, {:cdp_event, method, event})
    {:ok, state}
  end

  defp normalize_response(%{"error" => error}) do
    message = Map.get(error, "message", inspect(error))
    {:error, Error.new("cdp_error", message, %{"cdp" => error})}
  end

  defp normalize_response(%{"result" => result}), do: {:ok, result}
  defp normalize_response(_message), do: {:ok, nil}

  defp payload(id, method, nil, nil), do: %{id: id, method: method}
  defp payload(id, method, params, nil), do: %{id: id, method: method, params: params || %{}}
  defp payload(id, method, nil, session), do: %{id: id, method: method, sessionId: session}

  defp payload(id, method, params, session) do
    %{id: id, method: method, params: params || %{}, sessionId: session}
  end

  defp schedule_keepalive(ms), do: Process.send_after(self(), :keepalive, ms)
end
