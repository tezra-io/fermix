defmodule FermixCore.Browser.Bridge.Peer do
  @moduledoc """
  One connected browser extension: the socket, its grants, and its in-flight ids.

  The wire is one JSON object per `{packet, 4}` frame. The extension opens with
  `hello`; anything before that, and any protocol number this daemon does not
  speak, is answered with `refused` and the connection is closed — a version
  skew is never guessed at. After the handshake the peer does three jobs:

    * grants and revokes reach `Bridge.Grants`, which is where a conversation
      finds a tab and where exactly one conversation can hold it,
    * a `cdp` from a transport is given an id MINTED HERE (ids are the peer's,
      never a transport's, so two profiles cannot collide), sent, and its
      `cdp_result`/`cdp_error` sent back to the transport that is waiting,
    * an `event` is handed to the transport bound to its tab.

  The in-flight map is bounded: the oldest id is dropped when a new command
  would push it past `@max_inflight`, and a reply for an id that is no longer
  there is counted and discarded. It is never matched by position — a reply
  whose id we do not hold belongs to a command that already timed out, and
  handing it to whoever asked next would answer one command with another's
  result.
  """

  use GenServer, restart: :temporary

  require Logger

  alias FermixCore.Browser.Bridge.Grants
  alias FermixCore.Browser.Error

  # The one protocol number this daemon speaks. A bump is a paired change with
  # the extension, which is why it is refused rather than negotiated.
  @protocol 1
  # Six live profiles each block on one command, so this is an order of
  # magnitude of headroom over the reachable maximum.
  @max_inflight 64
  # A connection that never says hello holds one of the listener's few slots, so
  # it is given a bounded moment to say it. The `status` probe is exempt by
  # construction: it is answered and closed inside the same frame.
  @hello_timeout_ms 10_000

  @spec protocol() :: pos_integer()
  def protocol, do: @protocol

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    Process.send_after(self(), :hello_deadline, @hello_timeout_ms)

    {:ok,
     %{
       socket: Keyword.fetch!(opts, :socket),
       grants: Keyword.get(opts, :grants, Grants),
       handshake: :pending,
       next_id: 1,
       inflight: %{},
       order: [],
       dropped: 0
     }}
  end

  @impl true
  def handle_info(:socket_handover, state), do: rearm(state)

  def handle_info({:tcp, socket, frame}, %{socket: socket} = state) do
    case Jason.decode(frame) do
      {:ok, message} when is_map(message) -> dispatch(message, state)
      _not_an_object -> refuse("malformed_frame", state)
    end
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state), do: {:stop, :normal, state}

  def handle_info({:tcp_error, socket, reason}, %{socket: socket} = state) do
    Logger.warning("browser bridge: peer socket error #{inspect(reason)}")
    {:stop, :normal, state}
  end

  # A transport's command. The id is minted here so two profiles talking to one
  # extension cannot collide on it.
  def handle_info({:bridge_command, from, ref, tab_id, method, params, session_id}, state) do
    id = state.next_id
    state = remember(state, id, from, ref)

    frame = %{
      type: "cdp",
      id: id,
      tab_id: tab_id,
      method: method,
      params: params || %{},
      session_id: session_id
    }

    case send_frame(frame, state) do
      :ok -> {:noreply, %{state | next_id: id + 1}}
      {:error, reason} -> {:stop, {:shutdown, reason}, state}
    end
  end

  def handle_info({:release_tab, tab_id}, state) do
    _ = send_frame(%{type: "release", tab_id: tab_id}, state)
    {:noreply, state}
  end

  def handle_info(:hello_deadline, %{handshake: :pending} = state) do
    refuse("hello_timeout", state)
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _ = :gen_tcp.close(state.socket)
    :ok
  end

  # ── the wire ───────────────────────────────────────────────────────────────

  defp dispatch(%{"type" => "hello", "protocol" => @protocol}, %{handshake: :pending} = state) do
    :ok = Grants.attach_peer(state.grants, self())

    case send_frame(%{type: "hello_ack", protocol: @protocol}, state) do
      :ok -> rearm(%{state | handshake: :ready})
      {:error, reason} -> {:stop, {:shutdown, reason}, state}
    end
  end

  defp dispatch(%{"type" => "hello", "protocol" => _other}, state) do
    refuse("unsupported_protocol", state)
  end

  # The one exchange a not-yet-handshaken connection may make: `fermix browser
  # bridge status` asks the daemon what it is serving and closes. It never says
  # hello, so it is never counted as a connected extension.
  defp dispatch(%{"type" => "status"}, state) do
    summary = Grants.summary(state.grants)
    frame = %{type: "status_ok", protocol: @protocol, extensions: summary.extensions}
    _ = send_frame(Map.put(frame, :granted_tabs, summary.tabs), state)
    {:stop, :normal, state}
  end

  defp dispatch(_message, %{handshake: :pending} = state), do: refuse("hello_required", state)

  defp dispatch(%{"type" => "grant", "tab_id" => tab_id} = message, state)
       when is_integer(tab_id) do
    :ok = Grants.grant(state.grants, self(), tab_id, message)
    rearm(state)
  end

  defp dispatch(%{"type" => "revoke", "tab_id" => tab_id} = message, state)
       when is_integer(tab_id) do
    reason = Map.get(message, "reason", "user")
    :ok = Grants.revoke(state.grants, self(), tab_id, to_string(reason))
    rearm(state)
  end

  defp dispatch(%{"type" => "cdp_result", "id" => id} = message, state) when is_integer(id) do
    reply(id, {:ok, Map.get(message, "result")}, state)
  end

  defp dispatch(%{"type" => "cdp_error", "id" => id} = message, state) when is_integer(id) do
    text = Map.get(message, "message", "the extension reported a CDP error")
    reply(id, {:error, Error.new("cdp_error", to_string(text))}, state)
  end

  defp dispatch(%{"type" => "event", "tab_id" => tab_id, "method" => method} = message, state)
       when is_integer(tab_id) and is_binary(method) do
    relay_event(tab_id, method, Map.get(message, "params", %{}), state)
    rearm(state)
  end

  defp dispatch(_message, state), do: soft_refuse("unknown_message", state)

  # A refusal that ends the connection: the extension and this daemon do not
  # agree on what they are speaking, so nothing after it would mean anything.
  defp refuse(reason, state) do
    _ = send_frame(%{type: "refused", reason: reason}, state)
    {:stop, :normal, state}
  end

  # A refusal that does not: one message this daemon does not know, on a session
  # whose handshake was good. Answered by name and the connection continues.
  defp soft_refuse(reason, state) do
    _ = send_frame(%{type: "refused", reason: reason}, state)
    rearm(state)
  end

  # Scoped to THIS peer's grant for that tab id: another browser's tab 7 is not
  # this browser's tab 7, and an event delivered across that line would put one
  # person's page into another conversation.
  defp relay_event(tab_id, method, params, state) do
    case Grants.transport_for(state.grants, self(), tab_id) do
      {:ok, pid} -> send(pid, {:bridge_event, method, params})
      :error -> :ok
    end
  end

  defp reply(id, outcome, state) do
    case Map.pop(state.inflight, id) do
      {nil, _inflight} ->
        Logger.debug("browser bridge: dropped a reply for unknown id #{id}")
        rearm(%{state | dropped: state.dropped + 1})

      {{pid, ref}, inflight} ->
        send(pid, {:bridge_reply, ref, outcome})
        rearm(%{state | inflight: inflight, order: List.delete(state.order, id)})
    end
  end

  defp remember(state, id, from, ref) do
    state = evict_oldest(state)
    %{state | inflight: Map.put(state.inflight, id, {from, ref}), order: state.order ++ [id]}
  end

  defp evict_oldest(%{order: [oldest | rest]} = state)
       when map_size(state.inflight) >= @max_inflight do
    %{state | inflight: Map.delete(state.inflight, oldest), order: rest}
  end

  defp evict_oldest(state), do: state

  defp send_frame(frame, state) do
    case :gen_tcp.send(state.socket, Jason.encode!(frame)) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp rearm(state) do
    case :inet.setopts(state.socket, [{:active, :once}]) do
      :ok -> {:noreply, state}
      {:error, reason} -> {:stop, {:shutdown, reason}, state}
    end
  end
end
