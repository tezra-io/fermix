defmodule FermixChannels.Channels.IMessage.ComputerHelper do
  @moduledoc """
  The iMessage helper of a home that runs on a server (M97 §6.4): the
  `IMessage.Helper` the listener and the adapter speak to, reaching the Mac
  that carries Messages through invocations (`IMessage.Capability`), where
  the Mac's own helper answers (`IMessage.Bridge`). The server runs the
  listener and the adapter, which make turns; the Mac runs the helper.

  **Which Mac.** One home has one Messages bridge
  (`FermixCore.IMessage.carrier/1`): the one computer that offers `imessage`
  as it last said. While it carries Messages a second Mac that offers it is
  refused by name, logged once and named in health; when more than one offer
  it and none carries it yet, none is chosen, and each is named. The home's
  computers are read every #{5} s.

  **Requests.** `call/5` is one invocation each: a send is `imessage.send`
  (an effect, never sent twice by the link), every other method
  `imessage.call`, each with the origin of the turn that made it (its
  origin facts; none for the channel's own reads and the watch, which are
  `background`), so the Mac's rule that a delegated worker sends nothing is
  its own, and its journal names the turn's real origin. `policy.set` is never forwarded: who Fermix may write to
  is confirmed on the Mac's screen. A file travels as the invocation's part
  (at most 20 MiB) in both directions: `send.file` reads the file the
  adapter staged here and the Mac stages it in its own outbox;
  `attachment.fetch` writes the bytes into this home's inbox
  (`imessage/inbox/<guid>/`), where the adapter takes them, so no path of
  the Mac's is ever used here.

  **While that Mac is away the channel is away** (D4): every request is
  refused at once with the sentence that the Mac carrying Messages is
  asleep or offline (`"class" => "computer_away"`, which the adapter makes
  `{:permanent, :carrier_away}`), and nothing is queued. Health says
  `:away` (`poll_health/1`).

  **Notifications** come on one long-lived invocation, `imessage.watch`
  (`IMessage.Watch` on the Mac), asked again as soon as it answers, naming
  the last event taken, so a lost answer loses nothing: the Mac answers
  again from there. When the Mac's link comes back, or the listener
  attaches, the watch starts afresh: the Mac answers with its helper's
  state, the listener hears `{:imessage_helper, :up, handshake}` and
  catches up from the cursor it keeps for that computer (the handshake
  carries the computer's device id and name, `"carrier"` and
  `"carrier_name"`).

  Options: `:name`, `:home` (this engine's FERMIX_HOME), `:computers`
  (0-arity, the home's computers, `FermixCore.Computers.list/1`'s),
  `:call_opts` (`FermixCore.Computers.call/6`'s seams) and `:poll_ms`,
  `:retry_ms` (tests shrink these).
  """

  use GenServer

  @behaviour FermixChannels.Channels.IMessage.Helper

  require Logger

  alias FermixChannels.Channels.IMessage.Capability
  alias FermixChannels.Channels.IMessage.Protocol
  alias FermixChannels.Telemetry, as: ChannelTelemetry
  alias FermixCore.Computers
  alias FermixCore.Computers.Computer
  alias FermixCore.Computers.Origin
  alias FermixCore.Computers.Outcome
  alias FermixCore.IMessage, as: Channel
  alias FermixCore.Setup.ConfigStore

  @poll_ms 5_000
  @retry_ms 5_000
  @name_bytes 128

  @type health :: %{status: :ready | :away | :degraded, detail: String.t() | nil}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  @doc "The channel's posture where this helper runs (registered as core's health provider)."
  @spec poll_health(atom()) :: health() | nil
  def poll_health(name \\ __MODULE__) when is_atom(name) do
    if Process.whereis(name), do: :persistent_term.get({__MODULE__, name}, nil)
  end

  @impl FermixChannels.Channels.IMessage.Helper
  def call(server, method, params, timeout, turn)
      when is_binary(method) and is_map(params) and is_integer(timeout) and timeout > 0 and
             is_map(turn) do
    with :ok <- forwardable(method),
         {:ok, route} <- route(server, :route) do
      invoke(server, route, method, params, timeout, turn)
    end
  end

  @impl FermixChannels.Channels.IMessage.Helper
  def attach(server, pid) when is_pid(pid) do
    GenServer.call(server, {:attach, pid})
  catch
    :exit, {:noproc, _call} -> {:error, not_running()}
  end

  @impl FermixChannels.Channels.IMessage.Helper
  def home(server) do
    GenServer.call(server, :home)
  catch
    :exit, {:noproc, _call} -> {:error, not_running()}
  end

  # -- requests, in the caller's process -------------------------------------------------

  # Who Fermix may write to is confirmed on the Mac's screen, never from here.
  defp forwardable("policy.set"),
    do: {:error, {:protocol_error, Capability.policy_sentence(), %{"method" => "policy.set"}}}

  defp forwardable(method) do
    if method in (Capability.methods("imessage.call") ++ Capability.methods("imessage.send")),
      do: :ok,
      else:
        {:error,
         {:protocol_error, "the server does not ask Messages on the Mac for #{method}",
          %{"method" => method}}}
  end

  defp route(server, ask) do
    GenServer.call(server, ask)
  catch
    :exit, {:noproc, _call} -> {:error, not_running()}
  end

  defp invoke(server, route, method, params, timeout, turn) do
    op =
      if method in Capability.methods("imessage.send"), do: "imessage.send", else: "imessage.call"

    args = %{"method" => method, "params" => params, "timeout_ms" => timeout}

    with {:ok, args, part} <- outgoing(method, args) do
      opts = Keyword.merge(route.opts, deadline_ms: Capability.deadline_ms(op, args), part: part)
      context = context(turn, route.computer)

      route.computer
      |> Computers.call(Capability, op, args, context, opts)
      |> answered(server, route, method, params)
    end
  end

  # A file the adapter staged here rides as the part, with its name; the Mac
  # fills the path in its own outbox.
  defp outgoing("send.file", %{"params" => %{"path" => path} = params} = args)
       when is_binary(path) do
    case File.read(path) do
      {:ok, bytes} when byte_size(bytes) <= 20 * 1_024 * 1_024 ->
        name = path |> Path.basename() |> String.slice(0, @name_bytes)
        mime = Map.get(params, "mime", "application/octet-stream")
        args = %{args | "params" => Map.delete(params, "path")} |> Map.put("file_name", name)
        {:ok, args, {bytes, mime}}

      {:ok, bytes} ->
        {:error,
         {:attachment_too_large,
          "the file is #{byte_size(bytes)} bytes; Messages through a Mac carries at most 20 MiB",
          %{"bytes" => byte_size(bytes)}}}

      {:error, reason} ->
        {:error, {:path_refused, "the staged file could not be read: #{reason}", %{}}}
    end
  end

  defp outgoing(_method, args), do: {:ok, args, nil}

  # Who asked, as the computer's admission reads it: the origin facts of the
  # turn that made the request (`Computers.Origin.facts/1`), so the Mac's own
  # rules and journal see that turn's origin; the channel's own reads carry
  # none, which is `background`.
  defp context(turn, %Computer{device_id: device_id}),
    do: Map.put(Origin.facts(turn), :session_id, "imessage-" <> String.slice(device_id, 0, 16))

  defp answered(
         {:ok, %Outcome{result: %{"result" => result}} = outcome},
         _server,
         route,
         method,
         params
       ),
       do: result(method, params, result, outcome.part_bytes, route.home)

  defp answered({:ok, %Outcome{}}, _server, _route, method, _params),
    do: {:error, {:protocol_error, "the Mac answered #{method} outside the contract", %{}}}

  defp answered({:error, %Outcome{} = outcome}, server, route, method, _params),
    do: refused(outcome, server, route, method)

  defp result("attachment.fetch", %{"message_guid" => guid}, result, bytes, home)
       when is_binary(bytes),
       do: write_inbox(home, guid, result, bytes)

  defp result("attachment.fetch", _params, _result, nil, _home),
    do: {:error, {:protocol_error, "the attachment did not come with the answer", %{}}}

  defp result(_method, _params, result, _bytes, _home), do: {:ok, result}

  # The helper's own typed error, as the Port would answer it.
  defp refused(
         %Outcome{status: :failed, result: %{"error" => %{"kind" => kind} = error}},
         _server,
         _route,
         _method
       ) do
    case Protocol.decode_error_kind(kind) do
      {:ok, atom} ->
        {:error, {atom, error["message"] || "", error["data"] || %{}}}

      {:error, _unknown} ->
        {:error, {:protocol_error, "unknown helper error kind", %{"kind" => kind}}}
    end
  end

  defp refused(%Outcome{status: :failed, message: message}, _server, _route, method),
    do: {:error, {:protocol_error, message || "the Mac could not run #{method}", %{}}}

  defp refused(%Outcome{status: :refused, refusal: :busy} = outcome, _server, route, _method),
    do: {:error, {:busy, Outcome.sentence(outcome, route.computer.name), %{}}}

  # A refusal before anything reached the Mac: away now, or the Mac's own.
  defp refused(%Outcome{status: :refused} = outcome, server, route, _method) do
    case route(server, :refresh) do
      {:error, {:helper_unavailable, _sentence, _data}} = away ->
        away

      _still_carried ->
        sentence = Outcome.sentence(outcome, route.computer.name)
        class = if outcome.refusal == :off, do: "computer_off", else: "computer_unavailable"
        {:error, {:helper_unavailable, sentence, %{"class" => class}}}
    end
  end

  # Timed out, cancelled, or not known: a send may have gone, and the same
  # idempotency key on a retry is answered from the helper's ledger.
  defp refused(%Outcome{} = outcome, _server, route, method) do
    {:error,
     {:request_timeout, Outcome.sentence(outcome, route.computer.name),
      %{"method" => method, "outcome" => Atom.to_string(outcome.status)}}}
  end

  # The fetched bytes in this home's inbox entry for the message, where the
  # adapter takes them and the gateway removes them after the turn.
  defp write_inbox(home, guid, result, bytes) do
    entry = Path.join([home, "imessage", "inbox", guid])
    path = Path.join(entry, file_name(result["name"]))

    with :ok <- private_dir(Path.join(home, "imessage")),
         :ok <- private_dir(Path.join([home, "imessage", "inbox"])),
         :ok <- private_dir(entry),
         :ok <- File.write(path, bytes),
         :ok <- File.chmod(path, 0o600) do
      {:ok, %{"path" => path, "mime" => result["mime"], "bytes" => byte_size(bytes)}}
    else
      {:error, reason} ->
        Logger.error("iMessage could not keep a fetched attachment: #{inspect(reason)}")
        {:error, {:path_refused, "the attachment could not be kept here", %{}}}
    end
  end

  defp file_name(name) when is_binary(name) and name not in ["", ".", ".."] do
    if Path.basename(name) == name, do: String.slice(name, 0, @name_bytes), else: "attachment"
  end

  defp file_name(_name), do: "attachment"

  defp private_dir(dir), do: with(:ok <- File.mkdir_p(dir), do: File.chmod(dir, 0o700))

  # -- GenServer ------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      name: Keyword.fetch!(opts, :name),
      home: Keyword.get_lazy(opts, :home, &ConfigStore.fermix_home/0),
      computers: Keyword.get(opts, :computers, fn -> Computers.list() end),
      call_opts: Keyword.get(opts, :call_opts, []),
      poll_ms: Keyword.get(opts, :poll_ms, @poll_ms),
      retry_ms: Keyword.get(opts, :retry_ms, @retry_ms),
      bridge: nil,
      refused: MapSet.new(),
      seconds: [],
      conflict: [],
      handshake: nil,
      listener: nil,
      listener_ref: nil,
      watch: nil,
      boot: nil,
      seq: nil,
      away?: false
    }

    {:ok, state |> refresh() |> record_health(), {:continue, :poll}}
  end

  @impl GenServer
  def handle_continue(:poll, state) do
    Process.send_after(self(), :poll, state.poll_ms)
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:route, _from, state), do: {:reply, route_of(state), state}

  def handle_call(:refresh, _from, state) do
    state = state |> refresh() |> record_health()
    {:reply, route_of(state), state}
  end

  def handle_call({:attach, pid}, _from, state) do
    if state.listener_ref, do: Process.demonitor(state.listener_ref, [:flush])
    state = %{state | listener: pid, listener_ref: Process.monitor(pid)}

    case {state.handshake, route_of(state)} do
      {%{} = handshake, {:ok, _route}} -> {:reply, {:ok, handshake}, state}
      {_none, {:error, error}} -> {:reply, {:error, error}, state}
      {nil, {:ok, _route}} -> {:reply, {:error, waiting()}, state}
    end
  end

  def handle_call(:home, _from, state), do: {:reply, {:ok, state.home}, state}

  @impl GenServer
  def handle_info(:poll, state) do
    Process.send_after(self(), :poll, state.poll_ms)
    {:noreply, state |> refresh() |> record_health()}
  end

  def handle_info(:rewatch, %{watch: nil} = state), do: {:noreply, rewatch(state)}
  def handle_info(:rewatch, state), do: {:noreply, state}

  def handle_info({:watched, pid, result}, %{watch: pid} = state),
    do: {:noreply, state |> watched(result) |> record_health()}

  def handle_info({:watched, _stale, _result}, state), do: {:noreply, state}

  def handle_info({:EXIT, pid, reason}, %{watch: pid} = state) do
    if reason != :normal, do: Logger.warning("the Messages watch stopped: #{inspect(reason)}")
    {:noreply, retry(%{state | watch: nil})}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{listener_ref: ref} = state),
    do: {:noreply, %{state | listener: nil, listener_ref: nil}}

  def handle_info(message, state) do
    Logger.debug("the iMessage computer helper ignored #{inspect(message)}")
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    _erased? = :persistent_term.erase({__MODULE__, state.name})
    :ok
  end

  # -- which Mac -----------------------------------------------------------------------

  defp refresh(state) do
    computers = state.computers.()
    carriers = Enum.filter(computers, &Channel.offers?/1)
    {bridge, state} = bridge(state, carriers)
    state |> seconds(bridge, carriers) |> connect(bridge)
  end

  # The bridge keeps its place while it offers Messages; a new one is chosen
  # only when exactly one Mac offers it.
  defp bridge(%{bridge: %Computer{device_id: id}} = state, carriers) do
    case Enum.find(carriers, &(&1.device_id == id)) do
      nil -> {choose(carriers), lost(state, "computer_off")}
      current -> {current, state}
    end
  end

  defp bridge(state, carriers), do: {choose(carriers), state}

  defp choose([one]), do: one
  defp choose(_none_or_many), do: nil

  defp seconds(state, nil, [_, _ | _] = carriers) do
    names = Enum.map(carriers, & &1.name)
    if names != state.conflict, do: Logger.error(Channel.conflict_sentence(names))
    %{state | conflict: names, seconds: []}
  end

  defp seconds(state, nil, _none), do: %{state | conflict: [], seconds: []}

  defp seconds(state, bridge, carriers) do
    others = Enum.reject(carriers, &(&1.device_id == bridge.device_id))

    for other <- others,
        not MapSet.member?(state.refused, other.device_id),
        do: Logger.error(Channel.second_bridge_sentence(other.name, bridge.name))

    refused = Enum.reduce(others, state.refused, &MapSet.put(&2, &1.device_id))
    %{state | conflict: [], seconds: Enum.map(others, & &1.name), refused: refused}
  end

  # The bridge's link: a watch while it is up, the listener told when it goes.
  defp connect(state, nil), do: %{state | bridge: nil}

  defp connect(%{bridge: previous} = state, %Computer{connected: true} = bridge) do
    state = %{state | bridge: bridge}

    cond do
      same_link?(previous, bridge) ->
        state

      state.away? ->
        Logger.info("#{bridge.name}, the Mac that carries Messages, is back")
        ChannelTelemetry.emit_transport(:imessage, :recovered, 1, :none)
        start_over(%{state | away?: false})

      true ->
        start_over(state)
    end
  end

  defp connect(state, %Computer{connected: false} = bridge) do
    state = %{state | bridge: bridge}
    if state.away?, do: state, else: went_away(state)
  end

  defp same_link?(%Computer{device_id: id, connected: true}, %Computer{device_id: id}), do: true
  defp same_link?(_previous, _bridge), do: false

  defp went_away(state) do
    Logger.warning(Channel.away_sentence(state.bridge.name))
    ChannelTelemetry.emit_transport(:imessage, :degraded, 1, :computer_away)

    %{stop_watch(state) | away?: true, handshake: nil}
    |> tell({:imessage_helper, :down, "computer_away"})
  end

  defp lost(state, class) do
    Logger.warning("Messages is no longer offered by #{state.bridge.name}")
    %{stop_watch(state) | bridge: nil, handshake: nil} |> tell({:imessage_helper, :down, class})
  end

  # A fresh watch: the Mac answers with its helper's state now.
  defp start_over(state),
    do: state |> stop_watch() |> Map.merge(%{boot: nil, seq: nil}) |> rewatch()

  # -- the watch ---------------------------------------------------------------------------

  defp rewatch(%{bridge: %Computer{connected: true} = bridge} = state) do
    parent = self()
    args = %{"after" => state.seq, "boot" => state.boot}
    opts = Keyword.put(state.call_opts, :deadline_ms, 0)
    context = %{session_id: "imessage-" <> String.slice(bridge.device_id, 0, 16)}

    pid =
      spawn_link(fn ->
        result = Computers.call(bridge, Capability, "imessage.watch", args, context, opts)
        send(parent, {:watched, self(), result})
      end)

    %{state | watch: pid}
  end

  defp rewatch(state), do: state

  defp stop_watch(%{watch: nil} = state), do: state

  defp stop_watch(%{watch: pid} = state) do
    Process.unlink(pid)
    Process.exit(pid, :kill)
    %{state | watch: nil}
  end

  defp watched(
         state,
         {:ok, %Outcome{result: %{"boot" => boot, "seq" => seq, "events" => events}}}
       )
       when is_list(events) do
    state = %{state | watch: nil, boot: boot, seq: seq}
    state |> events(events) |> rewatch()
  end

  defp watched(state, {_ok_or_error, %Outcome{} = outcome}) do
    Logger.warning("the Messages watch ended: #{Outcome.sentence(outcome, bridge_name(state))}")
    retry(%{state | watch: nil, boot: nil, seq: nil})
  end

  defp retry(state) do
    Process.send_after(self(), :rewatch, state.retry_ms)
    state
  end

  defp events(state, events), do: Enum.reduce(events, state, &event/2)

  defp event(%{"helper" => "up", "handshake" => %{} = handshake}, state) do
    handshake =
      Map.merge(handshake, %{
        "carrier" => state.bridge.device_id,
        "carrier_name" => state.bridge.name
      })

    tell(%{state | handshake: handshake}, {:imessage_helper, :up, handshake})
  end

  defp event(%{"helper" => "down", "class" => class}, state),
    do: tell(%{state | handshake: nil}, {:imessage_helper, :down, class})

  defp event(%{"event" => event, "params" => %{} = params}, state),
    do: tell(state, {:imessage_event, event, params})

  defp event(other, state) do
    Logger.error("the Messages watch sent an event outside the contract: #{inspect(other)}")
    state
  end

  defp tell(%{listener: nil} = state, _message), do: state

  defp tell(%{listener: pid} = state, message) do
    send(pid, message)
    state
  end

  # -- answers -----------------------------------------------------------------------------

  defp route_of(%{bridge: %Computer{connected: true} = bridge} = state),
    do: {:ok, %{computer: bridge, home: state.home, opts: state.call_opts}}

  defp route_of(%{bridge: %Computer{} = bridge}),
    do: {:error, unavailable(Channel.away_sentence(bridge.name), "computer_away")}

  defp route_of(%{conflict: [_ | _] = names}),
    do: {:error, unavailable(Channel.conflict_sentence(names), "two_carriers")}

  defp route_of(_state), do: {:error, unavailable(Channel.none_sentence(), "no_carrier")}

  defp record_health(state) do
    :persistent_term.put({__MODULE__, state.name}, health(state))
    state
  end

  defp health(%{bridge: %Computer{connected: false} = bridge}),
    do: %{status: :away, detail: Channel.away_sentence(bridge.name)}

  defp health(%{bridge: %Computer{} = bridge, seconds: [second | _]}),
    do: %{status: :ready, detail: Channel.second_bridge_sentence(second, bridge.name)}

  defp health(%{bridge: %Computer{}}), do: %{status: :ready, detail: nil}

  defp health(%{conflict: [_ | _] = names}),
    do: %{status: :degraded, detail: Channel.conflict_sentence(names)}

  defp health(_state), do: %{status: :degraded, detail: Channel.none_sentence()}

  defp bridge_name(%{bridge: %Computer{name: name}}), do: name
  defp bridge_name(_state), do: "the Mac"

  defp unavailable(sentence, class), do: {:helper_unavailable, sentence, %{"class" => class}}

  defp waiting,
    do: unavailable("The Mac that carries Messages has not answered yet.", "computer_waiting")

  defp not_running, do: {:helper_unavailable, "the iMessage channel is not running", %{}}
end
