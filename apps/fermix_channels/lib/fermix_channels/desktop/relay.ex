defmodule FermixChannels.Desktop.Relay do
  @moduledoc """
  A desktop's one session to its primary (M75 §6, B1, B12), in the engine
  that runs in the device role after its home moved.

  The desktop's Mac or Linux app keeps speaking only this engine's local
  sockets. The relay carries what they ask of the primary over one Noise `IK`
  session on the rail (`Mobile.Rail`, dialed through the dial-only
  `Iroh.Helper`): the app's chat, one `channel` per `companion.sock`
  connection (`Desktop.Tunnel`), and every Fermix-wide management call the
  daemon forwards (`forward/2`, through `FermixCore.Home.Link`).

  ## The link

  It reads `device/desktop.json` and `device/desktop_key`
  (`FermixCore.Home.DesktopLink`) when it starts. A file it cannot use leaves
  it refused by name: it never dials, says why in `status/1`, and answers
  every caller with that sentence. Otherwise it dials the primary at once,
  runs `IK` with the desktop's key against the primary's gateway key, and
  sends `hello` with the desktop's `device_id`, this engine's version, the
  highest primary epoch it has seen and the revision of the relay list it
  holds.

  The `hello_ack` decides the rest. One with a lower primary epoch, or none,
  comes from a stale primary (a retired copy that kept the identity): the
  relay closes the session, says so, and keeps the epoch it holds. A higher
  one is recorded. A route with another relay revision is recorded too, so
  the next `hello` acknowledges it and the primary may use it. Every session
  that opens tells the Always On provisioner the epoch it reached
  (`FermixCore.Management.Provision.primary_reached/2`, in a task of its own,
  so the session never waits on it): one above the epoch the old server of a
  replace held is how this desktop sees the move to the new server done, and
  the old server is deleted then (M75 lean v1 §4.3).

  Every ending it did not ask for is retried after 1 s, doubling to 60 s, and
  the backoff starts over once a session is up. While the session is down,
  every caller hears that the primary is unreachable, by its name
  (`FermixCore.Management.Placement.unreachable_sentence/1`), every open
  channel ends with that sentence, and every forwarded call waiting for its
  answer is answered with it. Its posture crossing into and out of that state
  is the channel transport telemetry the other transports emit
  (`emit_transport(:desktop_relay, …)`), on transitions only.

  Two endings are not outages. A session the primary closes normally (`1000`)
  is renewed at once, quietly: no telemetry, and what was in flight is told
  the link was renewed, never that the server is unreachable (a desktop
  session has no lifetime on either side; the 2^20-frame rekey bounds its
  keys). Only once in a row: a renewed session the primary ends normally again
  within a minute of opening is an outage (`renewed_again`), redialed with the
  backoff, one step further each time, until a session stays up a minute, so
  a primary that ends every session is never redialed every second unseen.
  A primary that no longer knows this computer (`4003`: revoked, or an
  unknown key at the handshake) is not retried: the relay says so and stays
  down until the engine restarts.

  `status/1` also says how long the link has had no session (`down_ms`, on
  the monotonic clock, which stops while this computer sleeps): from the
  engine's start until the first session, nil while one is up, and from the
  moment one ends until the next is up. `home.status.summary` says Fermix
  cannot reach the server after ten minutes of it (M75 lean v1 §7).

  `status/1` names the link's state in one word from a closed set, so an app
  draws a quiet renewal apart from an outage: `connected` (a session is up);
  `renewing` (a session is being opened with nothing known to be wrong: the
  first since this engine started, or the quiet renewal above); `unreachable`
  (an outage, retried with the backoff, the renewal loop included, and a link
  this engine refused to use); `revoked` (the primary no longer knows this
  computer); `stale` (it answered as an older copy, retried with the
  backoff). A redial during an outage keeps the outage's word until a
  session is up.

  ## What the primary sends

  `@inbound` is the one map of who serves each event the primary sends a
  desktop: the session itself (`hello_ack`, `pong`, `error`), the companion
  channels, the forwarded calls, the media fetches, or a module's
  `handle/3`. Chunked payloads (`companion_line`, `manage_result`, …) are put
  back together first (`Mobile.Chunks`); a gap, a repeat or a payload past
  its bound ends the session as a protocol error. An event no line names is
  logged and dropped.

  ## Bounds

  At most 4 channels at once, numbered round the 64 the wire allows so a
  number comes back only long after its last line. At most 8 forwarded calls
  in flight and 32 more waiting; each is answered within its method's
  deadline (`Placement.forward_deadline_ms/1`: 8 s, under the Mac and Linux
  apps' 10 s management call timeout, and 60 s for `home.move.readiness` and
  `home.move.start`, which walk the whole home on the primary first; a caller
  may ask for less, `forward/3`), past which it is answered
  `primary_unreachable` with the sentence that the primary did not answer in
  time; work longer than that is a job on the primary, answered at once. A
  move's start the primary had and never answered (its deadline passed, or
  the session ended under it) is `unconfirmed` instead
  (`Placement.unconfirmed/2`): the primary restarts into the move right after
  it answers, so a lost answer is no failure. At most 8 media fetches at
  once, each blob at most the primary's `caps.max_media_bytes`, which this
  desktop clamps to 64 MiB whatever the primary says. At most 32 chunked
  payloads open at once, as the primary holds its own side; a 33rd ends the
  session as a protocol error.

  Test seams: `:connect` (handed to `Rail.open/3` in place of dialing),
  `:addrs` (a route's direct addresses, a test's), `:rail_opts`, `:schedule`
  and `:cancel_timer` (this process's timers, delivered by hand in a test),
  `:clock`, `:monotonic` (a 0-arity count of milliseconds), `:emit` and
  `:primary_reached` (a 1-arity function of the epoch, in place of the
  provisioner's).
  """

  use GenServer

  require Logger

  alias FermixChannels.Desktop.Relay.Media
  alias FermixChannels.Mobile.Chunks
  alias FermixChannels.Mobile.Peers
  alias FermixChannels.Mobile.Protocol
  alias FermixChannels.Mobile.Rail
  alias FermixChannels.Telemetry, as: ChannelTelemetry
  alias FermixCore.BuildInfo
  alias FermixCore.Home.DesktopLink
  alias FermixCore.Management.Placement
  alias FermixCore.Management.Protocol, as: ManagementProtocol
  alias FermixCore.Management.Provision
  alias FermixCore.Setup.ConfigStore

  @first_backoff_ms 1_000
  @max_backoff_ms 60_000
  # A session that stayed up this long before the primary ended it normally
  # is renewed quietly, however many renewals came before it.
  @steady_session_ms 60_000
  @max_channels 4
  @channel_numbers 64
  @max_calls 8
  @max_waiting_calls 32
  # A caller waits for the relay's own answer, which comes within its call's
  # deadline, plus a second for the relay to be busy writing a frame.
  @forward_wait_margin_ms 1_000
  # An event an `@inbound` module sends may be a large payload's frames.
  @send_wait_ms 75_000
  @max_media_fetches 8
  @default_max_media_bytes 20 * 1_024 * 1_024
  # The most a desktop takes in one blob, whatever the primary's caps say.
  @desktop_max_media_bytes 64 * 1_024 * 1_024
  @max_open_payloads 32
  @status_wait_ms 5_000

  # Every event the primary sends a desktop, and who serves it here: the
  # session itself, the companion channels, the forwarded calls, the media
  # fetches, or a module's `handle/3`. One line per event.
  @inbound %{
    "hello_ack" => :session,
    "pong" => :session,
    "error" => :session,
    "companion_line" => :channels,
    "companion_close" => :channels,
    "manage_result" => :calls,
    "media_begin" => :media,
    "media_chunk" => :media,
    "media_end" => :media,
    "loopback_open" => FermixChannels.Desktop.Loopback,
    "loopback_response" => FermixChannels.Desktop.Loopback,
    "loopback_close" => FermixChannels.Desktop.Loopback,
    "snapshot_begin" => FermixChannels.Desktop.SnapshotStore,
    "snapshot_chunk" => FermixChannels.Desktop.SnapshotStore,
    "snapshot_end" => FermixChannels.Desktop.SnapshotStore
  }

  @typedoc "The link's state in one word (the moduledoc says what each means)."
  @type word :: :connected | :renewing | :unreachable | :revoked | :stale

  @typedoc "What `status/1` says of the link, for `home.status`."
  @type status :: %{
          name: String.t() | nil,
          connected: boolean(),
          status: word(),
          since: DateTime.t() | nil,
          epoch: pos_integer() | nil,
          sentence: String.t(),
          down_ms: non_neg_integer() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Every event the primary sends a desktop, by who serves it here."
  @spec inbound() :: %{String.t() => atom() | module()}
  def inbound, do: @inbound

  @doc "The link's facts for `home.status`, or `nil` when no relay runs."
  @spec status(GenServer.server()) :: status() | nil
  def status(server \\ __MODULE__) do
    if GenServer.whereis(server), do: GenServer.call(server, :status, @status_wait_ms)
  catch
    :exit, {reason, _call} when reason in [:noproc, :normal, :shutdown] ->
      nil

    :exit, {:timeout, _call} ->
      %{
        name: nil,
        connected: false,
        status: :unreachable,
        since: nil,
        epoch: nil,
        sentence: "The link to the server did not answer in time.",
        down_ms: nil
      }
  end

  @doc """
  Sends one management request to the primary and answers what it answered,
  as `daemon.sock` would (`FermixCore.Home.Link.forward/2`). While the link is
  down, or past the call's deadline, `primary_unreachable` with the primary's
  name; a move's start the primary had and never answered is `unconfirmed`
  (`Placement.unconfirmed/2`). `opts`: `:deadline_ms`, by default and at most
  the method's own (`Placement.forward_deadline_ms/1`).
  """
  @spec forward(GenServer.server(), ManagementProtocol.request(), keyword()) ::
          ManagementProtocol.route_result()
  def forward(server \\ __MODULE__, %{method: method, params: params} = request, opts \\ [])
      when is_binary(method) and is_map(params) and is_list(opts) do
    deadline_ms = call_deadline(method, opts)

    GenServer.call(
      server,
      {:forward, request, deadline_ms},
      deadline_ms + @forward_wait_margin_ms
    )
  catch
    :exit, {reason, _call} when reason in [:noproc, :normal, :shutdown] ->
      not_running()

    :exit, {:timeout, _call} ->
      lost_answer(method, Placement.unreachable(nil, Placement.unreachable_sentence(nil)), nil)
  end

  defp not_running do
    Logger.error("desktop relay: a management call found no relay running")
    Placement.unreachable(nil, Placement.unreachable_sentence(nil))
  end

  defp call_deadline(method, opts) do
    most = Placement.forward_deadline_ms(method)

    case Keyword.get(opts, :deadline_ms, most) do
      ms when is_integer(ms) and ms > 0 and ms <= most -> ms
    end
  end

  # A call the primary had and never answered: a move's start may have begun
  # all the same, so it is unconfirmed, never a failure; any other gets
  # `otherwise`. `name` is the primary's, when known.
  defp lost_answer(method, otherwise, name) do
    if Placement.unconfirmed_on_loss?(method),
      do: Placement.unconfirmed(name, method),
      else: otherwise
  end

  @doc """
  Opens a companion channel for the calling `Desktop.Tunnel`: the channel's
  number and the relay's process (to monitor), or why not: `{:revoked,
  sentence}` once the primary no longer knows this computer, which no retry
  mends, `{:unreachable, sentence}` while any other ending keeps the session
  down.
  """
  @spec open_channel(GenServer.server()) ::
          {:ok, pos_integer(), pid()}
          | {:error, {:unreachable, String.t()} | {:revoked, String.t()} | :busy}
  def open_channel(server \\ __MODULE__) do
    GenServer.call(server, :open_channel, @status_wait_ms)
  catch
    :exit, {reason, _call} when reason in [:noproc, :normal, :shutdown, :timeout] ->
      {:error, {:unreachable, Placement.unreachable_sentence(nil)}}
  end

  @doc "One line from the calling tunnel's client, without its newline, for its channel."
  @spec send_line(GenServer.server(), pos_integer(), binary()) :: :ok
  def send_line(server, channel, line) when is_integer(channel) and is_binary(line),
    do: GenServer.cast(server, {:line, channel, self(), line})

  @doc "The calling tunnel's client went: its channel ends."
  @spec close_channel(GenServer.server(), pos_integer()) :: :ok
  def close_channel(server, channel) when is_integer(channel),
    do: GenServer.cast(server, {:close_channel, channel, self()})

  @doc """
  Fetches the blob `ref` from the primary for the calling tunnel, which is
  told `{:relay_media, ref, result}` once it is staged (`Relay.Media`) or
  failed.
  """
  @spec fetch_media(GenServer.server(), String.t()) ::
          :ok | {:error, {:unreachable, String.t()} | :busy}
  def fetch_media(server, ref) when is_binary(ref) do
    GenServer.call(server, {:fetch_media, ref}, @status_wait_ms)
  catch
    :exit, {reason, _call} when reason in [:noproc, :normal, :shutdown, :timeout] ->
      {:error, {:unreachable, Placement.unreachable_sentence(nil)}}
  end

  @doc """
  Sends the primary one event a desktop may send, for a module of `@inbound`
  that answers what it was sent: `event` is the header (`"t"` and its
  fields), `payload` the raw bytes, cut into chunks when the event is
  chunked.
  """
  @spec send_event(GenServer.server(), map(), binary()) ::
          :ok | {:error, {:unreachable, String.t()} | {:not_for_desktop, String.t()} | term()}
  def send_event(server \\ __MODULE__, %{"t" => type} = event, payload \\ <<>>)
      when is_binary(type) and is_binary(payload) do
    if Peers.client_event?(:desktop, type),
      do: GenServer.call(server, {:send, type, Map.delete(event, "t"), payload}, @send_wait_ms),
      else: {:error, {:not_for_desktop, type}}
  end

  # -- the process -----------------------------------------------------------

  @impl true
  def init(opts) do
    # The connector is linked; its exit is the session's ending, and a
    # supervisor's shutdown still runs `terminate/2`.
    Process.flag(:trap_exit, true)
    root = Keyword.get_lazy(opts, :root, &ConfigStore.fermix_home/0)
    state = base_state(root, opts)

    case load(root, state.staging) do
      {:ok, link, keypair} ->
        {:ok, %{state | link: link, keypair: keypair}, {:continue, :connect}}

      {:error, reason, link} ->
        sentence = DesktopLink.error_sentence(reason)
        Logger.error("desktop relay: not connecting to the primary: #{sentence}")
        {:ok, %{state | link: link, phase: :refused, word: :unreachable, sentence: sentence}}
    end
  end

  defp base_state(root, opts) do
    monotonic = Keyword.get(opts, :monotonic, fn -> System.monotonic_time(:millisecond) end)

    %{
      root: root,
      staging: Keyword.get_lazy(opts, :staging, fn -> Media.staging_dir(root) end),
      helper: Keyword.get(opts, :helper),
      connect: Keyword.get(opts, :connect),
      addrs: Keyword.get(opts, :addrs, []),
      rail_opts: Keyword.get(opts, :rail_opts, []),
      schedule: Keyword.get(opts, :schedule, &Process.send_after(self(), &1, &2)),
      cancel_timer: Keyword.get(opts, :cancel_timer, &Process.cancel_timer/1),
      clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
      monotonic: monotonic,
      down_since_ms: monotonic.(),
      emit:
        Keyword.get(opts, :emit, &ChannelTelemetry.emit_transport(:desktop_relay, &1, &2, &3)),
      primary_reached: Keyword.get_lazy(opts, :primary_reached, fn -> provisioner(root) end),
      link: nil,
      keypair: nil,
      phase: :connecting,
      word: :renewing,
      sentence: "Fermix is connecting to its server.",
      since: nil,
      connector: nil,
      rail: nil,
      failures: 0,
      degraded?: false,
      renewals: 0,
      reconnect: nil,
      max_media_bytes: @default_max_media_bytes,
      open: %{},
      channels: %{},
      next_channel: 1,
      calls: %{},
      waiting: :queue.new(),
      call_seq: 0,
      fetches: %{},
      transfer: nil
    }
  end

  # A key it cannot use still lets the relay name the primary it refuses to
  # reach.
  defp load(root, staging) do
    with {:link, {:ok, link}} <- {:link, DesktopLink.read(root)},
         {:key, _link, {:ok, keypair}} <- {:key, link, DesktopLink.read_key(root)} do
      :ok = prepare_staging(staging)
      {:ok, link, keypair}
    else
      {:link, {:error, reason}} -> {:error, reason, nil}
      {:key, link, {:error, reason}} -> {:error, reason, link}
    end
  end

  # A staging directory that cannot be prepared costs the app's media, never
  # the link; it is logged, and each fetch then fails by name.
  defp prepare_staging(staging) do
    case Media.prepare(staging) do
      :ok -> :ok
      {:error, reason} -> Logger.error("desktop relay: media staging: #{inspect(reason)}")
    end

    :ok
  end

  @impl true
  def handle_continue(:connect, state), do: {:noreply, connect(state)}

  @impl true
  def handle_call(:status, _from, state), do: {:reply, status_view(state), state}

  def handle_call({:forward, request, deadline_ms}, from, state),
    do: forward_call(request, deadline_ms, from, state)

  def handle_call(:open_channel, {tunnel, _tag}, state), do: open(tunnel, state)
  def handle_call({:fetch_media, ref}, {tunnel, _tag}, state), do: fetch(ref, tunnel, state)

  def handle_call({:send, type, fields, payload}, _from, %{phase: :connected} = state),
    do: {:reply, send_frames(state.rail, type, fields, payload), state}

  def handle_call({:send, _type, _fields, _payload}, _from, state),
    do: {:reply, {:error, {:unreachable, unreachable_sentence(state)}}, state}

  @impl true
  def handle_cast({:line, channel, tunnel, line}, state) do
    case Map.fetch(state.channels, channel) do
      {:ok, %{pid: ^tunnel}} -> {:noreply, send_line_frames(channel, line, state)}
      _other -> {:noreply, state}
    end
  end

  def handle_cast({:close_channel, channel, tunnel}, state),
    do: {:noreply, end_channel(channel, tunnel, state)}

  @impl true
  def handle_info({:relay_connector, connector, message}, %{connector: connector} = state),
    do: connector_message(message, state)

  # An old connector's word arrives after its session was let go.
  def handle_info({:relay_connector, _old, _message}, state), do: {:noreply, state}

  def handle_info({:relay_timer, kind, token}, state), do: timer(kind, token, state)

  def handle_info({:DOWN, _monitor, :process, pid, _reason}, state),
    do: {:noreply, tunnel_down(pid, state)}

  def handle_info({:EXIT, connector, reason}, %{connector: connector} = state),
    do: {:noreply, link_down({:connector_exit, reason}, %{state | connector: nil, rail: nil})}

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(message, state) do
    Logger.debug("desktop relay ignored #{inspect(message)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    :ok = Media.abort(state.transfer)
    :ok = stop_connector(state)
  end

  # -- connecting ------------------------------------------------------------

  defp connect(state) do
    relay = self()
    route = route(state)
    opts = rail_opts(state)
    {:ok, connector} = Task.start_link(fn -> run_connector(relay, route, opts) end)
    %{state | connector: connector, rail: nil, phase: :connecting}
  end

  defp route(%{link: %{primary: primary}, addrs: addrs}) do
    route = %{node_id: primary.node_id, relays: primary.relays, relays_rev: primary.relays_rev}
    if addrs == [], do: route, else: Map.put(route, :addrs, addrs)
  end

  defp rail_opts(state) do
    base = [static_keypair: state.keypair, remote_static: state.link.primary.gateway_pk]

    reach =
      if is_function(state.connect, 0),
        do: [connect: state.connect],
        else: [helper: state.helper]

    base ++ reach ++ state.rail_opts
  end

  # The rail's owner is the process that opened it, so the open (up to 40 s)
  # runs here and not in the relay, which keeps answering meanwhile; this
  # process then carries the session's events to the relay until it ends.
  @doc false
  @spec run_connector(pid(), Rail.route(), keyword()) :: :ok
  def run_connector(relay, route, opts) do
    case Rail.open(route, :ik, opts) do
      {:ok, rail} ->
        send(relay, {:relay_connector, self(), {:opened, rail}})
        carry(relay, rail)

      {:error, reason} ->
        send(relay, {:relay_connector, self(), {:failed, reason}})
        :ok
    end
  end

  # Ends with the session: its close, or the relay letting it go.
  defp carry(relay, rail) do
    receive do
      {:rail, ^rail, {:closed, reason}} ->
        send(relay, {:relay_connector, self(), {:closed, reason}})
        :ok

      {:rail, ^rail, {:event, header, tail}} ->
        send(relay, {:relay_connector, self(), {:event, header, tail}})
        carry(relay, rail)

      :close ->
        close_rail(rail)
    end
  end

  # The session may have ended on its own meanwhile; there is nothing left to
  # close then.
  defp close_rail(rail) do
    Rail.close(rail)
  catch
    :exit, _reason -> :ok
  end

  defp stop_connector(%{connector: nil}), do: :ok

  defp stop_connector(%{connector: connector}) do
    Process.unlink(connector)
    send(connector, :close)
    :ok
  end

  defp connector_message({:opened, rail}, state) do
    state = %{state | rail: rail}

    case send_frames(rail, "hello", hello(state), <<>>) do
      :ok -> {:noreply, state}
      {:error, reason} -> {:noreply, drop_session({:hello, reason}, state)}
    end
  end

  defp connector_message({:failed, reason}, state),
    do: {:noreply, link_down(reason, %{state | connector: nil, rail: nil})}

  defp connector_message({:closed, reason}, state),
    do: {:noreply, link_down(ending(reason, state), %{state | connector: nil, rail: nil})}

  defp connector_message({:event, %{"t" => type} = header, tail}, state) do
    fields = Map.drop(header, ["v", "t", "seq"])

    case Map.fetch(@inbound, type) do
      {:ok, family} -> {:noreply, take(family, type, fields, tail, state)}
      :error -> {:noreply, unserved(type, state)}
    end
  end

  # The rail's codec refuses a `hello_ack` that names no primary epoch (a
  # daemon older than the epoch, or a copy that lost it) before it reaches
  # here: that is a stale primary too.
  defp ending({:protocol_error, {:missing_field, "primary_epoch"}}, state),
    do: {:stale_primary, state.link.epoch, nil}

  defp ending(reason, _state), do: reason

  defp hello(state) do
    %{
      "device_id" => state.link.device_id,
      "app_version" => BuildInfo.product_version(),
      "last_server_seq" => 0,
      "protocol_v" => Protocol.protocol_version(),
      "relay_list_rev" => state.link.primary.relays_rev,
      "primary_epoch" => state.link.epoch
    }
  end

  defp unserved(type, state) do
    Logger.warning("desktop relay: the primary sent #{type}, which this desktop does not serve")
    state
  end

  # -- the session's own events --------------------------------------------------

  defp take(:session, "hello_ack", fields, _tail, state), do: hello_ack(fields, state)
  defp take(:session, "pong", _fields, _tail, state), do: state
  defp take(:session, "error", fields, _tail, state), do: primary_error(fields, state)

  defp take(family, type, fields, tail, state) when family in [:channels, :calls] do
    if Chunks.chunked?(type),
      do: take_chunk(family, type, fields, tail, state),
      else: complete(family, type, fields, tail, state)
  end

  defp take(:media, type, fields, tail, state), do: media(type, fields, tail, state)

  defp take(module, type, fields, tail, state) when is_atom(module) do
    if Chunks.chunked?(type),
      do: take_chunk(module, type, fields, tail, state),
      else: handed(module, type, fields, tail, state)
  end

  defp hello_ack(fields, %{link: link} = state) do
    case fields["primary_epoch"] do
      epoch when is_integer(epoch) and epoch >= link.epoch -> connected(epoch, fields, state)
      epoch -> drop_session({:stale_primary, link.epoch, epoch}, state)
    end
  end

  defp connected(epoch, fields, state) do
    link = state.link |> keep_epoch(epoch, state.root) |> keep_route(fields, state.root)
    max_media = media_bound(get_in(fields, ["caps", "max_media_bytes"]))
    :ok = state.primary_reached.(epoch)

    if state.degraded?, do: state.emit.(:recovered, state.failures, :none)

    %{
      state
      | link: link,
        phase: :connected,
        word: :connected,
        since: state.clock.(),
        down_since_ms: nil,
        failures: 0,
        degraded?: false,
        max_media_bytes: max_media,
        sentence: "Fermix is connected to the server #{link.primary.name}."
    }
  end

  # What the primary's epoch means for a replace of the server is read in a
  # task: the provisioner reads its ledger and may start deleting the old
  # server, none of which this session waits for.
  defp provisioner(root) do
    fn epoch ->
      {:ok, _pid} =
        Task.Supervisor.start_child(FermixCore.TaskSupervisor, fn ->
          Provision.primary_reached(epoch, home: root)
        end)

      :ok
    end
  end

  # The primary names its blob bound; this desktop takes no more than its own
  # ceiling, whatever that says.
  defp media_bound(bytes) when is_integer(bytes) and bytes > 0,
    do: min(bytes, @desktop_max_media_bytes)

  defp media_bound(_unsaid), do: @default_max_media_bytes

  # The epoch the file holds is raised before anything relies on it; a write
  # that fails keeps the higher value for this run and says so.
  defp keep_epoch(link, epoch, root) do
    case DesktopLink.record_epoch(root, link, epoch) do
      {:ok, link} ->
        link

      {:error, reason} ->
        Logger.error("desktop relay: the primary epoch #{epoch} was not kept: #{inspect(reason)}")
        %{link | epoch: max(link.epoch, epoch)}
    end
  end

  # The primary's route for its own node, when it names another relay list:
  # kept, so the next hello acknowledges it.
  defp keep_route(link, fields, root) do
    node_id = link.primary.node_id

    case Enum.find(
           fields["candidates"] || [],
           &match?(%{"kind" => "iroh", "node_id" => ^node_id}, &1)
         ) do
      %{"relays" => relays, "relays_rev" => rev} -> record_route(link, {relays, rev}, root)
      nil -> link
    end
  end

  defp record_route(link, route, root) do
    case DesktopLink.record_route(root, link, route) do
      {:ok, link} ->
        link

      {:error, reason} ->
        Logger.error("desktop relay: the primary's relay list was not kept: #{inspect(reason)}")
        link
    end
  end

  # An error that names a ref ends that fetch; any other the primary's own
  # refusal of something this desktop sent, which leaves the session open.
  defp primary_error(%{"ref" => ref} = fields, state),
    do: media_failed(ref, fields["code"], state)

  # The primary refused this desktop's hello for having seen a later primary:
  # it is itself a retired copy.
  defp primary_error(%{"code" => "stale_primary"}, state),
    do: drop_session({:stale_primary, state.link.epoch, :refused}, state)

  defp primary_error(fields, state) do
    Logger.warning(
      "desktop relay: the primary refused an event: #{fields["code"]}: #{fields["message"]}"
    )

    state
  end

  # -- chunks ------------------------------------------------------------------

  defp take_chunk(family, type, fields, tail, state) do
    {:ok, key_field} = Chunks.key_field(type)
    key = {type, Map.fetch!(fields, key_field)}

    with {:ok, acc} <- open_acc(key, type, state),
         {:more, acc} <- Chunks.add(acc, fields["index"], fields["last"], tail) do
      put_in(state.open[key], acc)
    else
      {:done, payload} -> complete(family, type, header(fields), payload, drop_open(state, key))
      {:error, reason} -> drop_session({:protocol_error, reason}, drop_open(state, key))
    end
  end

  # As many payloads open at once as the primary allows a desktop, and no more.
  defp open_acc(key, type, state) do
    case Map.fetch(state.open, key) do
      {:ok, acc} ->
        {:ok, acc}

      :error when map_size(state.open) >= @max_open_payloads ->
        {:error, {:too_many_open_payloads, @max_open_payloads}}

      :error ->
        {:ok, new_acc(type)}
    end
  end

  defp new_acc(type) do
    {:ok, bound} = Chunks.bound(type)
    Chunks.new(bound)
  end

  defp header(fields), do: Map.drop(fields, ["index", "last"])
  defp drop_open(state, key), do: %{state | open: Map.delete(state.open, key)}

  defp complete(:channels, type, fields, payload, state),
    do: channel_event(type, fields, payload, state)

  defp complete(:calls, "manage_result", fields, payload, state),
    do: call_answered(fields, payload, state)

  defp complete(module, type, fields, payload, state),
    do: handed(module, type, fields, payload, state)

  defp handed(module, type, fields, payload, state) do
    case module.handle(type, fields, payload) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("desktop relay: #{type} was not served: #{inspect(reason)}")
    end

    state
  end

  # -- sending -------------------------------------------------------------------

  @doc false
  @spec send_frames(pid() | nil, String.t(), map(), binary()) :: :ok | {:error, term()}
  def send_frames(nil, _type, _fields, _payload), do: {:error, :not_connected}

  def send_frames(rail, type, fields, payload) do
    pieces =
      if Chunks.chunked?(type),
        do:
          for(
            {index, last, bytes} <- Chunks.split(payload),
            do: {Map.merge(fields, %{"index" => index, "last" => last}), bytes}
          ),
        else: [{fields, payload}]

    Enum.reduce_while(pieces, :ok, fn {fields, bytes}, :ok ->
      case rail_send(rail, type, fields, bytes) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # A session that ended under the send answers its own ending to the owner.
  defp rail_send(rail, type, fields, bytes) do
    Rail.send_event(rail, type, fields, bytes)
  catch
    :exit, reason -> {:error, {:rail_down, reason}}
  end

  # -- the companion channels ------------------------------------------------------

  defp open(tunnel, %{phase: :connected} = state) do
    if map_size(state.channels) >= @max_channels,
      do: {:reply, {:error, :busy}, state},
      else: open_channel(tunnel, state)
  end

  defp open(_tunnel, %{phase: :revoked} = state),
    do: {:reply, {:error, {:revoked, state.sentence}}, state}

  defp open(_tunnel, state),
    do: {:reply, {:error, {:unreachable, unreachable_sentence(state)}}, state}

  defp open_channel(tunnel, state) do
    channel = free_channel(state.next_channel, state.channels)

    case send_frames(state.rail, "companion_open", %{"channel" => channel}, <<>>) do
      :ok ->
        entry = %{pid: tunnel, monitor: Process.monitor(tunnel)}
        next = rem(channel, @channel_numbers) + 1

        {:reply, {:ok, channel, self()},
         %{state | channels: Map.put(state.channels, channel, entry), next_channel: next}}

      {:error, _reason} ->
        {:reply, {:error, {:unreachable, unreachable_sentence(state)}}, state}
    end
  end

  # At most 4 of 64 numbers are taken, so a free one is found within 5 steps.
  defp free_channel(channel, channels) do
    if Map.has_key?(channels, channel),
      do: free_channel(rem(channel, @channel_numbers) + 1, channels),
      else: channel
  end

  defp send_line_frames(channel, line, state) do
    case send_frames(state.rail, "companion_line", %{"channel" => channel}, line) do
      :ok -> state
      {:error, reason} -> drop_session({:send, reason}, state)
    end
  end

  defp end_channel(channel, tunnel, state) do
    case Map.fetch(state.channels, channel) do
      {:ok, %{pid: ^tunnel, monitor: monitor}} ->
        Process.demonitor(monitor, [:flush])
        _ = send_frames(state.rail, "companion_close", %{"channel" => channel}, <<>>)
        %{state | channels: Map.delete(state.channels, channel)}

      _other ->
        state
    end
  end

  defp tunnel_down(pid, state) do
    state =
      case Enum.find(state.channels, fn {_channel, entry} -> entry.pid == pid end) do
        {channel, _entry} -> end_channel(channel, pid, state)
        nil -> state
      end

    forget_fetcher(pid, state)
  end

  defp channel_event("companion_line", %{"channel" => channel}, line, state) do
    case Map.fetch(state.channels, channel) do
      {:ok, %{pid: tunnel}} -> send(tunnel, {:relay_line, channel, line})
      :error -> Logger.debug("desktop relay: a line for channel #{channel}, which is closed")
    end

    state
  end

  defp channel_event("companion_close", %{"channel" => channel} = fields, _payload, state) do
    case Map.pop(state.channels, channel) do
      {%{pid: tunnel, monitor: monitor}, channels} ->
        Process.demonitor(monitor, [:flush])
        send(tunnel, {:relay_closed, channel, fields["reason"]})
        %{state | channels: channels}

      {nil, _channels} ->
        state
    end
  end

  # -- forwarded management calls ----------------------------------------------------

  defp forward_call(_request, _deadline_ms, _from, %{phase: phase} = state)
       when phase != :connected,
       do: {:reply, unreachable(state), state}

  # Each call gets its id and its deadline as it arrives: the deadline covers
  # its wait and its flight, so the caller is answered within it whatever the
  # primary does.
  defp forward_call(request, deadline_ms, from, state) do
    call_id = "m#{state.call_seq + 1}"
    state = %{state | call_seq: state.call_seq + 1}

    cond do
      map_size(state.calls) < @max_calls ->
        {:noreply,
         start_call(call_id, request, from, arm(state, {:call, call_id}, deadline_ms), state)}

      :queue.len(state.waiting) < @max_waiting_calls ->
        deadline = arm(state, {:call, call_id}, deadline_ms)

        {:noreply,
         %{state | waiting: :queue.in({call_id, request, from, deadline}, state.waiting)}}

      true ->
        {:reply, {:error, :busy, %{"operation" => "forwarded management"}}, state}
    end
  end

  defp start_call(call_id, request, from, deadline, state) do
    case manage_frames(call_id, request, state) do
      :ok ->
        put_in(state.calls[call_id], %{from: from, deadline: deadline, method: request.method})

      {:error, {:too_large, bound}} ->
        cancel(state, deadline)
        too_large = %{"field" => "params", "maximum_bytes" => bound}
        GenServer.reply(from, {:error, :invalid_params, too_large})
        state

      {:error, reason} ->
        cancel(state, deadline)
        GenServer.reply(from, unreachable(state))
        drop_session({:send, reason}, state)
    end
  end

  defp manage_frames(call_id, request, state) do
    params = Jason.encode!(request.params)
    {:ok, bound} = Chunks.bound("manage")

    fields = %{
      "call_id" => call_id,
      "method" => request.method,
      "protocol_version" => request.protocol_version
    }

    if byte_size(params) > bound,
      do: {:error, {:too_large, bound}},
      else: send_frames(state.rail, "manage", fields, params)
  end

  defp call_answered(%{"call_id" => call_id}, payload, state) do
    case Map.pop(state.calls, call_id) do
      {%{from: from, deadline: deadline}, calls} ->
        cancel(state, deadline)
        GenServer.reply(from, management_answer(payload))
        next_call(%{state | calls: calls})

      {nil, _calls} ->
        Logger.warning("desktop relay: an answer for call #{call_id}, which no caller waits for")
        state
    end
  end

  defp next_call(state) do
    case :queue.out(state.waiting) do
      {{:value, {call_id, request, from, deadline}}, waiting} ->
        start_call(call_id, request, from, deadline, %{state | waiting: waiting})

      {:empty, _waiting} ->
        state
    end
  end

  defp call_timed_out(call_id, state) do
    case Map.pop(state.calls, call_id) do
      {%{from: from, method: method}, calls} ->
        GenServer.reply(from, lost_answer(method, timed_out(state), name(state)))
        next_call(%{state | calls: calls})

      {nil, _calls} ->
        drop_waiting(call_id, state)
    end
  end

  defp drop_waiting(call_id, state) do
    {gone, kept} =
      state.waiting |> :queue.to_list() |> Enum.split_with(&(elem(&1, 0) == call_id))

    Enum.each(gone, fn {_id, _request, from, _deadline} ->
      GenServer.reply(from, timed_out(state))
    end)

    %{state | waiting: :queue.from_list(kept)}
  end

  # The primary's answer as `daemon.sock` writes it, back into the router's
  # result. A code this engine does not know is a newer primary's: refused
  # loudly rather than passed on as something it is not.
  defp management_answer(payload) do
    case Jason.decode(payload) do
      {:ok, %{"result" => %{} = result}} ->
        {:ok, result}

      {:ok, %{"error" => %{"code" => code, "details" => %{} = details}}} ->
        known_error(code, details)

      _other ->
        malformed_answer(payload)
    end
  end

  defp known_error(code, details) do
    if code in ManagementProtocol.error_codes(),
      do: {:error, String.to_existing_atom(code), details},
      else: malformed_answer(code)
  end

  defp malformed_answer(what) do
    Logger.error("desktop relay: the primary answered a call with #{inspect(what, limit: 20)}")
    {:error, :internal_error, %{}}
  end

  defp timed_out(state) do
    name = state.link.primary.name
    Placement.unreachable(name, "The server #{name} did not answer in time. Try again.")
  end

  # -- media -----------------------------------------------------------------------

  defp fetch(_ref, _tunnel, %{phase: phase} = state) when phase != :connected,
    do: {:reply, {:error, {:unreachable, unreachable_sentence(state)}}, state}

  defp fetch(ref, tunnel, state) do
    case Map.fetch(state.fetches, ref) do
      {:ok, waiters} -> {:reply, :ok, put_in(state.fetches[ref], Enum.uniq([tunnel | waiters]))}
      :error -> new_fetch(ref, tunnel, state)
    end
  end

  defp new_fetch(ref, tunnel, state) do
    with true <- map_size(state.fetches) < @max_media_fetches,
         :ok <- send_frames(state.rail, "media_fetch", %{"ref" => ref}, <<>>) do
      {:reply, :ok, put_in(state.fetches[ref], [tunnel])}
    else
      false -> {:reply, {:error, :busy}, state}
      {:error, _reason} -> {:reply, {:error, {:unreachable, unreachable_sentence(state)}}, state}
    end
  end

  defp forget_fetcher(pid, state) do
    fetches = Map.new(state.fetches, fn {ref, waiters} -> {ref, List.delete(waiters, pid)} end)
    %{state | fetches: fetches}
  end

  # Blobs come one at a time; a begin for a ref nobody here asked for is
  # left unstaged, and its chunks with it.
  defp media("media_begin", %{"ref" => ref} = fields, _tail, state) do
    :ok = Media.abort(state.transfer)
    state = %{state | transfer: nil}

    with true <- Map.has_key?(state.fetches, ref),
         {:ok, transfer} <- Media.begin(state.staging, fields, state.max_media_bytes) do
      %{state | transfer: transfer}
    else
      false -> state
      {:error, reason} -> media_done(ref, {:error, reason}, state)
    end
  end

  defp media(
         "media_chunk",
         %{"ref" => ref, "index" => index},
         tail,
         %{transfer: %{ref: ref}} = state
       ) do
    case Media.chunk(state.transfer, index, tail) do
      {:ok, transfer} -> %{state | transfer: transfer}
      {:error, reason} -> abort_transfer(ref, reason, state)
    end
  end

  defp media("media_end", %{"ref" => ref}, _tail, %{transfer: %{ref: ref} = transfer} = state),
    do: media_done(ref, Media.finish(transfer, state.staging), %{state | transfer: nil})

  # A chunk or an end of a blob whose start was refused here.
  defp media(_type, _fields, _tail, state), do: state

  defp abort_transfer(ref, reason, state) do
    :ok = Media.abort(state.transfer)
    media_done(ref, {:error, reason}, %{state | transfer: nil})
  end

  defp media_failed(ref, code, state) do
    state =
      case state.transfer do
        %{ref: ^ref} = transfer ->
          :ok = Media.abort(transfer)
          %{state | transfer: nil}

        _other ->
          state
      end

    media_done(ref, {:error, media_code(code)}, state)
  end

  defp media_code(code) when code in ["not_found", "media_gone", "media_descriptor_mismatch"],
    do: :media_missing

  defp media_code("media_fetch_backlog_full"), do: :busy
  defp media_code(code), do: {:primary_refused, code}

  # A blob staged for nobody left waiting goes at once.
  defp media_done(ref, result, state) do
    {waiters, fetches} = Map.pop(state.fetches, ref, [])
    result = media_result(result)
    Enum.each(waiters, &send(&1, {:relay_media, ref, result}))
    if waiters == [] and match?({:ok, _media}, result), do: Media.discard(state.staging, ref)
    %{state | fetches: fetches}
  end

  defp media_result({:ok, media}), do: {:ok, media}
  defp media_result({:error, :media_descriptor_mismatch}), do: {:error, :media_missing}
  defp media_result({:error, reason}), do: {:error, reason}

  # -- endings ---------------------------------------------------------------------

  # This desktop ends a session it will not use (a stale primary, a protocol
  # error, a frame it could not send), and comes back to it as to any other.
  defp drop_session(reason, state) do
    :ok = stop_connector(state)
    link_down(reason, %{state | connector: nil, rail: nil})
  end

  # Three kinds of ending: a normal close of a session that was up is renewed
  # quietly, a primary that no longer knows this computer is not tried again,
  # and anything else is an outage, retried with backoff.
  defp link_down(reason, state) do
    case ending_kind(reason, state) do
      :renewal -> renewal(reason, state)
      :revoked -> revoked(reason, state)
      :outage -> outage(reason, state)
    end
  end

  # One normal ending in a row is renewed quietly. A renewed session the
  # primary ends normally again before it stayed up a minute means it ends
  # every session it takes: an outage, its wait one backoff step further for
  # each such ending in a row, and the posture says so.
  defp renewal(reason, state) do
    renewals = if steady?(state), do: 1, else: state.renewals + 1
    state = %{state | renewals: renewals}

    if renewals == 1,
      do: renew(reason, state),
      else: outage({:renewed_again, renewals}, state, backoff(renewals))
  end

  defp steady?(%{since: %DateTime{} = since} = state),
    do: DateTime.diff(state.clock.(), since, :millisecond) >= @steady_session_ms

  defp steady?(_state), do: false

  defp ending_kind(:lifetime, %{phase: :connected}), do: :renewal
  defp ending_kind({:remote, 1000, _text}, %{phase: :connected}), do: :renewal
  defp ending_kind({:remote, 4003, _text}, _state), do: :revoked
  defp ending_kind(_reason, _state), do: :outage

  defp outage(reason, state), do: outage(reason, state, backoff(state.failures + 1))

  defp outage(reason, state, delay) do
    sentence = down_sentence(reason, state)
    Logger.warning("desktop relay: #{sentence} (#{inspect(reason, limit: 20)})")
    failures = state.failures + 1
    unless state.degraded?, do: state.emit.(:degraded, failures, error_class(reason))

    %{
      fail_everyone(state, Placement.unreachable_sentence(state.link.primary.name))
      | phase: :waiting,
        word: outage_word(reason),
        since: nil,
        down_since_ms: down_since(state),
        failures: failures,
        degraded?: true,
        sentence: "#{sentence} Fermix tries again in #{div(delay, 1_000)} s.",
        reconnect: arm(state, :reconnect, delay)
    }
  end

  # The primary ended a session that was up as a session ends normally: not an
  # outage, so no telemetry and no "unreachable"; what was in flight is told
  # the link was renewed, and the next session opens after the first backoff
  # step (`renewal/2` keeps this to once in a row).
  defp renew(reason, state) do
    name = state.link.primary.name
    Logger.info("desktop relay: the session to #{name} ended (#{inspect(reason)}); renewing it")

    %{
      fail_everyone(state, "The link to the server #{name} was renewed. Try again.")
      | phase: :connecting,
        word: :renewing,
        since: nil,
        down_since_ms: down_since(state),
        sentence: "Fermix is reconnecting to the server #{name}.",
        reconnect: arm(state, :reconnect, @first_backoff_ms)
    }
  end

  # Revoked on the primary (`4003`, live or at the handshake): trying again
  # reaches nothing, so the relay stays down and says why until the engine
  # restarts and reads its link again.
  defp revoked(reason, state) do
    name = state.link.primary.name

    sentence =
      "The server #{name} does not know this computer: it was removed from the server's " <>
        "devices, or the server was restored from a snapshot taken before this computer " <>
        "joined it. Fermix stopped reaching it."

    Logger.error("desktop relay: #{sentence} (#{inspect(reason, limit: 20)})")
    unless state.degraded?, do: state.emit.(:degraded, state.failures + 1, :revoked)

    %{
      fail_everyone(state, sentence, :relay_revoked)
      | phase: :revoked,
        word: :revoked,
        since: nil,
        down_since_ms: down_since(state),
        failures: state.failures + 1,
        degraded?: true,
        sentence: sentence,
        reconnect: nil
    }
  end

  # A session that just ended starts the count; a redial during an outage
  # keeps it.
  defp down_since(%{down_since_ms: nil} = state), do: state.monotonic.()
  defp down_since(%{down_since_ms: since}), do: since

  defp outage_word({:stale_primary, _mine, _theirs}), do: :stale
  defp outage_word(_reason), do: :unreachable

  defp backoff(failures),
    do: min(@first_backoff_ms * Integer.pow(2, min(failures - 1, 6)), @max_backoff_ms)

  # Every open channel's tunnel hears `{tunnel_word, channel, sentence}`:
  # `:relay_down` for an ending tried again, `:relay_revoked` for a primary
  # that no longer knows this computer.
  defp fail_everyone(state, sentence, tunnel_word \\ :relay_down)
       when tunnel_word in [:relay_down, :relay_revoked] do
    :ok = Media.abort(state.transfer)
    answer = Placement.unreachable(name(state), sentence)

    for {channel, %{pid: tunnel, monitor: monitor}} <- state.channels do
      Process.demonitor(monitor, [:flush])
      send(tunnel, {tunnel_word, channel, sentence})
    end

    for {_id, %{from: from, deadline: deadline, method: method}} <- state.calls do
      cancel(state, deadline)
      GenServer.reply(from, lost_answer(method, answer, name(state)))
    end

    for {_id, _request, from, deadline} <- :queue.to_list(state.waiting) do
      cancel(state, deadline)
      GenServer.reply(from, answer)
    end

    for {ref, waiters} <- state.fetches,
        tunnel <- waiters,
        do: send(tunnel, {:relay_media, ref, {:error, {:unreachable, sentence}}})

    %{
      state
      | channels: %{},
        calls: %{},
        waiting: :queue.new(),
        fetches: %{},
        transfer: nil,
        open: %{}
    }
  end

  defp down_sentence({:stale_primary, mine, theirs}, state) do
    "The server #{state.link.primary.name} answered as an older copy of Fermix " <>
      "(#{stale_epochs(mine, theirs)}), so Fermix does not use it."
  end

  defp down_sentence({:renewed_again, _renewals}, state),
    do: "The server #{state.link.primary.name} ends this computer's session each time it opens."

  defp down_sentence(reason, state),
    do: "The server #{state.link.primary.name} is unreachable: #{why(reason)}."

  defp stale_epochs(mine, :refused),
    do: "it is behind epoch #{mine}, which this computer has seen"

  defp stale_epochs(mine, nil), do: "it names no epoch; this computer has seen #{mine}"
  defp stale_epochs(mine, theirs), do: "epoch #{theirs}; this computer has seen #{mine}"

  defp why({:dial, reason}) when reason in [:timeout, :no_answer], do: "it did not answer"
  defp why({:dial, :unreachable}), do: "no route reached it"
  defp why({:dial, :refused}), do: "it refused the connection"
  defp why({:dial, :busy}), do: "too many connections were opening"

  defp why({:dial, reason}) when reason in [:not_ready, :helper_failed],
    do: "the connection helper is not running"

  defp why({:remote, _code, _text}), do: "it closed the session"
  defp why(:remote_ended), do: "the connection ended"
  defp why(:idle), do: "it stopped answering"
  defp why({:handshake, _reason}), do: "it did not accept this computer's key"
  defp why({:protocol_error, _reason}), do: "it sent a message this computer could not read"
  defp why(_reason), do: "the connection failed"

  defp error_class({:dial, reason}) when reason in [:timeout, :no_answer], do: :timeout
  defp error_class({:dial, reason}) when reason in [:unreachable, :refused, :busy], do: reason
  defp error_class({:dial, _reason}), do: :helper
  defp error_class({:remote, _code, _text}), do: :remote_closed
  defp error_class({:stale_primary, _mine, _theirs}), do: :stale_primary
  defp error_class({:renewed_again, _renewals}), do: :renewed_again
  defp error_class({:handshake, _reason}), do: :handshake
  defp error_class({:protocol_error, _reason}), do: :protocol
  defp error_class(reason) when reason in [:remote_ended, :idle, :lifetime], do: reason
  defp error_class(_reason), do: :socket

  # -- timers ------------------------------------------------------------------------

  defp arm(state, kind, delay_ms) do
    token = make_ref()
    {state.schedule.({:relay_timer, kind, token}, delay_ms), token, kind}
  end

  defp cancel(_state, nil), do: :ok

  defp cancel(state, {ref, _token, _kind}) do
    _ = state.cancel_timer.(ref)
    :ok
  end

  defp timer(:reconnect, token, %{reconnect: {_ref, token, :reconnect}} = state),
    do: {:noreply, connect(%{state | reconnect: nil})}

  # A call's id is used once, so its timer firing is never stale.
  defp timer({:call, call_id}, _token, state), do: {:noreply, call_timed_out(call_id, state)}
  defp timer(_kind, _token, state), do: {:noreply, state}

  # -- answers -----------------------------------------------------------------------

  defp status_view(%{link: nil} = state) do
    %{
      name: nil,
      connected: false,
      status: state.word,
      since: nil,
      epoch: nil,
      sentence: state.sentence,
      down_ms: down_ms(state)
    }
  end

  defp status_view(state) do
    %{
      name: state.link.primary.name,
      connected: state.phase == :connected,
      status: state.word,
      since: state.since,
      epoch: state.link.epoch,
      sentence: state.sentence,
      down_ms: down_ms(state)
    }
  end

  defp down_ms(%{down_since_ms: nil}), do: nil
  defp down_ms(state), do: state.monotonic.() - state.down_since_ms

  defp unreachable(state), do: Placement.unreachable(name(state), unreachable_sentence(state))

  # A link this engine refused to use, or a primary that no longer knows this
  # computer, says why; any other names the primary.
  defp unreachable_sentence(%{phase: phase, sentence: sentence})
       when phase in [:refused, :revoked],
       do: sentence

  defp unreachable_sentence(state), do: Placement.unreachable_sentence(name(state))

  defp name(%{link: nil}), do: nil
  defp name(%{link: link}), do: link.primary.name
end
