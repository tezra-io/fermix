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

  It reads `device/desktop.json` (`FermixCore.Home.DesktopLink`) when it
  starts, and this computer's key from the secret store the link records
  (`FermixCore.Home.ComputerKey`, M97 §7.5), after moving a key an older
  Fermix kept in `device/desktop_key` into that store
  (`ComputerKey.migrate/2`: the device tree's one migration, run here before
  anything else in the tree reads the key). A link or key it cannot use leaves
  it refused by name: it never dials, never reads the old file instead, says
  why in `status/1`, and answers every caller with that sentence. A locked
  keyring alone is asked again, on the backoff below and at most 10 times in
  all (a keyring often unlocks just after the session that starts this
  engine), then left refused until the engine starts again. Otherwise it
  dials the primary at once,
  runs `IK` with the desktop's key against the primary's gateway key, and
  sends `hello` with the desktop's `device_id`, this engine's version, the
  highest primary epoch it has seen and the revision of the relay list it
  holds.

  The `hello_ack` decides the rest. One with a lower primary epoch, or none,
  comes from a stale primary (a retired copy that kept the identity): the
  relay closes the session, says so, and keeps the epoch it holds. A higher
  one is recorded in `device/desktop.json` before anything relies on it, the
  one place it lives (the invocations' Admission reads it there); one this
  computer cannot write leaves the session unused, said, and tried again
  with the backoff. A route with another relay revision is recorded too, so
  the next `hello` acknowledges it and the primary may use it, and so are
  the route's address hints, an Always On server's tailnet addresses at its
  fixed port (`FermixChannels.Mobile.Iroh.Hints`), none when it gives none.
  Every dial names the hints the link holds.

  ## The path

  `status/1` names the session's path (`path`): `:direct` or `:relay`, as
  the helper reported it when the dial opened (`dialed`) and at each change
  after (`dial_path`); nil while no session is up, or while the helper has
  said nothing of it. A change while the session is up tells the Always On
  watch, like the session's own comings and goings.

  The dial-only helper starts beside the relay, so each dial first waits up
  to 10 s for it to be ready (`Iroh.Helper.await_ready/2`): a session opened
  while this engine starts is no outage, and a helper that did not start in
  that time is the dial's own refusal, an outage like any other.

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

  A session that comes up and every ending tell this engine's Always On watch
  (`FermixCore.Home.StatusWatch`, `:link`): the summary an app draws reads
  the link (companion protocol 6).

  `status/1` also says how long the link has had no session (`down_ms`, on
  the monotonic clock, which stops while this computer sleeps): from the
  engine's start until the first session, nil while one is up, and from the
  moment one ends until the next is up. `home.status.summary` says Fermix
  cannot reach the server after ten minutes of it (M75 lean v1 §7). When
  that stretch began on the wall clock is `down_at`, nil while a session is
  up, which names the outage in the summary's notice.

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

  `@inbound` is the one map of which family serves each event the primary
  sends a desktop: the session itself (`hello_ack`, `pong`, `error`), the
  companion channels, the forwarded calls, the media fetches, the sign-in
  loopbacks or the snapshot copies. Chunked payloads (`companion_line`,
  `manage_result`, …) are put back together first (`Mobile.Chunks`); a gap, a
  repeat or a payload past its bound ends the session as a protocol error. An
  event no line names is logged and dropped.

  The relay keeps the session, decodes and dispatches, and never waits on a
  family (M97 §5.1): each family's work runs in a process of its own, which
  takes the family's events in the order they came, so a backup being
  written to disk delays no chat line and no settings answer. A channel's
  lines go to its `Desktop.Tunnel`; a forwarded call's answer to its caller,
  which decodes it in its own process; the media frames to
  `Desktop.MediaFetches`; the loopback's to `Desktop.Loopback`; the snapshot
  copies' to `Desktop.SnapshotStore`; the invocations' (`invoke_*`, M97
  §6.2) to `Desktop.Invoke` (`:families` names the last four).
  Each hand-off is bounded by what waits in the process taking it, and what
  happens at the bound is the family's:

  | Family | Waiting at most | Past it |
  |---|---|---|
  | companion | 256 lines in the channel's tunnel | the chat ends, as too busy, and its close goes to the primary |
  | forwarded calls | the 8 in flight | never dropped: each answer goes to its caller |
  | media | 256 frames | the fetch fails `busy`, its blob's later frames are dropped |
  | loopback | 64 events | the event is dropped |
  | snapshots | 256 frames | the copy is refused (`write_failed`), its later frames dropped |
  | invocations | 512 events in `Desktop.Invoke`'s Admission | the event is dropped, unanswered: the server waits out its deadline, or asks at the next session |

  A family whose process is not running has its events dropped until it
  runs again; a media fetch's waiters are told so. Each run of drops is
  logged when it starts and when it ends, with the count, never per frame;
  none ends the session.

  ## What this desktop sends

  Every frame this desktop sends rides a lane (`Mobile.Lanes`), queued in
  `Relay.Outbox` with its bounds: live first, then interactive, then bulk,
  one frame at a time, each lane in the order its frames came and a chunked
  payload's frames in order. A writer process of the session's own writes
  them to the rail one at a time and says when each is written, so the rail
  gives each the next `seq` in the order written and the relay keeps
  answering meanwhile. A lane past its bound refuses: a forwarded call is
  answered `busy`, a chat line ends its chat as too busy, a channel or a
  media fetch is refused `busy`, an `@inbound` family's event (`send_event/3`,
  answered once its last frame is written) `{:error, :busy}`; a lane's
  refusals are logged when they start and once it has drained, with the
  count. When the session ends, every frame not yet written goes with it and
  its waiter is told the session ended.

  A computer's own record (M97 §3.2, §5.3): its `hello` names its system
  (`platform`); once a session is up the relay tells this computer's offers
  reporter (`Desktop.Offers`, `:offers` names it) the `hello_ack`'s caps, and
  it sends the path the session runs (`link_path`), at the start once the
  helper has named it and at each change. Both `offers` and `link_path`, and
  the invocation's events (`caps.computer.invoke`), go only to a server
  whose `hello_ack` takes them (`caps.computer`): any other send of one is
  refused `{:error, {:not_taken, type}}`, since an older server closes the
  session on an event it does not know.

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
  `:rail_opts`, `:schedule`
  and `:cancel_timer` (this process's timers, delivered by hand in a test),
  `:clock`, `:monotonic` (a 0-arity count of milliseconds), `:emit` and
  `:status_changed` (a 0-arity call in place of telling the Always On
  watch), `:families` (the `media`, `loopback` and `snapshots` processes,
  by name or pid), `:write` (in place of `Rail.send_event/4`, run in the
  writer), `:key_opts` (handed to `ComputerKey`: its secret writer) and
  `:record_epoch` (3-arity, in place of `DesktopLink.record_epoch/3`).
  """

  use GenServer

  require Logger

  alias FermixChannels.Desktop.Invoke
  alias FermixChannels.Desktop.Loopback
  alias FermixChannels.Desktop.MediaFetches
  alias FermixChannels.Desktop.Offers, as: DesktopOffers
  alias FermixChannels.Desktop.Relay.Outbox
  alias FermixChannels.Desktop.SnapshotStore
  alias FermixChannels.Mobile.Chunks
  alias FermixChannels.Mobile.Iroh.Helper
  alias FermixChannels.Mobile.Lanes
  alias FermixChannels.Mobile.Peers
  alias FermixChannels.Mobile.Protocol
  alias FermixChannels.Mobile.Rail
  alias FermixChannels.Telemetry, as: ChannelTelemetry
  alias FermixCore.BuildInfo
  alias FermixCore.Computers.Switches, as: ComputerSwitches
  alias FermixCore.Home.ComputerKey
  alias FermixCore.Home.DesktopLink
  alias FermixCore.Home.StatusWatch
  alias FermixCore.Management.Placement
  alias FermixCore.Management.Protocol, as: ManagementProtocol
  alias FermixCore.Setup.ConfigStore

  @first_backoff_ms 1_000
  # How long a dial waits for the dial-only helper to start: it starts in
  # well under a second beside this process.
  @helper_wait_ms 10_000
  @max_backoff_ms 60_000
  # How many times in all a locked keyring is asked for this computer's key.
  @max_key_tries 10
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
  # A computer's own events (M97 §5.3), each sent only where the server's
  # hello_ack takes it, by the flag of `caps.computer` that says so: the
  # invocation's five (M97 §6.1), and the computer's word that its request
  # handler started (`invoke_restarted`), go under one.
  @computer_events %{
    "offers" => "offers",
    "link_path" => "link_path",
    "invoke_open" => "invoke",
    "invoke_part" => "invoke",
    "invoke_cancel" => "invoke",
    "invoke_result" => "invoke",
    "invoke_status" => "invoke",
    "invoke_restarted" => "invoke"
  }

  # Every event the primary sends a desktop, and the family that serves it
  # here: the session itself, the companion channels, the forwarded calls, the
  # media fetches, the sign-in loopbacks or the snapshot copies. One line per
  # event.
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
    "loopback_open" => :loopback,
    "loopback_response" => :loopback,
    "loopback_close" => :loopback,
    "snapshot_begin" => :snapshots,
    "snapshot_chunk" => :snapshots,
    "snapshot_end" => :snapshots,
    "invoke_open" => :invoke,
    "invoke_part" => :invoke,
    "invoke_cancel" => :invoke,
    "invoke_result" => :invoke,
    "invoke_status" => :invoke
  }

  # The families served by a process of their own, by its registered name.
  @family_servers %{
    media: MediaFetches,
    loopback: Loopback,
    snapshots: SnapshotStore,
    invoke: ComputerSwitches.invoke_listener()
  }
  # What may wait in each family's process before the family's rule applies
  # (moduledoc); a channel's tunnel holds at most @max_tunnel_lines.
  @family_bounds %{media: 256, loopback: 64, snapshots: 256, invoke: 512}
  @max_tunnel_lines 256

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
          down_ms: non_neg_integer() | nil,
          down_at: DateTime.t() | nil,
          path: :direct | :relay | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Every event the primary sends a desktop, by the family that serves it here."
  @spec inbound() :: %{String.t() => atom()}
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
        down_ms: nil,
        down_at: nil,
        path: nil
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

    server
    |> GenServer.call({:forward, request, deadline_ms}, deadline_ms + @forward_wait_margin_ms)
    |> answered()
  catch
    :exit, {reason, _call} when reason in [:noproc, :normal, :shutdown] ->
      not_running()

    :exit, {:timeout, _call} ->
      lost_answer(method, Placement.unreachable(nil, Placement.unreachable_sentence(nil)), nil)
  end

  # The primary's answer is decoded here, in the caller, so a large one never
  # holds the relay (M97 §5.1); every other answer is the relay's own.
  defp answered({:relay_answer, payload}), do: management_answer(payload)
  defp answered(result), do: result

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
  told `{:relay_media, ref, result}` once it is staged (`Desktop.MediaFetches`) or
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
  Sends the primary one event a desktop may send, for a family of `@inbound`
  that answers what it was sent: `event` is the header (`"t"` and its
  fields), `payload` the raw bytes, cut into chunks when the event is
  chunked. Answers once its last frame is written, in its lane's turn;
  `{:error, :busy}` when its lane is full, and the session's ending when it
  ends first.
  """
  @spec send_event(GenServer.server(), map(), binary()) ::
          :ok
          | {:error, {:unreachable, String.t()} | {:not_for_desktop, String.t()} | :busy | term()}
  def send_event(server \\ __MODULE__, %{"t" => type} = event, payload \\ <<>>)
      when is_binary(type) and is_binary(payload) do
    if Peers.client_event?(:desktop, type),
      do: GenServer.call(server, {:send, type, Map.delete(event, "t"), payload}, @send_wait_ms),
      else: {:error, {:not_for_desktop, type}}
  catch
    :exit, {reason, _call} when reason in [:noproc, :normal, :shutdown] ->
      {:error, {:unreachable, Placement.unreachable_sentence(nil)}}

    :exit, {:timeout, _call} ->
      {:error, :timeout}
  end

  # -- the process -----------------------------------------------------------

  @impl true
  def init(opts) do
    # The connector is linked; its exit is the session's ending, and a
    # supervisor's shutdown still runs `terminate/2`.
    Process.flag(:trap_exit, true)
    root = Keyword.get_lazy(opts, :root, &ConfigStore.fermix_home/0)
    state = base_state(root, opts)

    case load(root, state.key_opts) do
      {:ok, link, keypair} ->
        {:ok, %{state | link: link, keypair: keypair}, {:continue, :connect}}

      {:error, reason, link} ->
        {:ok, refused(reason, link, state)}
    end
  end

  defp base_state(root, opts) do
    monotonic = Keyword.get(opts, :monotonic, fn -> System.monotonic_time(:millisecond) end)
    clock = Keyword.get(opts, :clock, &DateTime.utc_now/0)

    %{
      root: root,
      families: Map.merge(@family_servers, Keyword.get(opts, :families, %{})),
      write: Keyword.get(opts, :write, &Rail.send_event/4),
      helper: Keyword.get(opts, :helper),
      connect: Keyword.get(opts, :connect),
      rail_opts: Keyword.get(opts, :rail_opts, []),
      schedule: Keyword.get(opts, :schedule, &Process.send_after(self(), &1, &2)),
      cancel_timer: Keyword.get(opts, :cancel_timer, &Process.cancel_timer/1),
      clock: clock,
      monotonic: monotonic,
      down_since_ms: monotonic.(),
      down_at: clock.(),
      emit:
        Keyword.get(opts, :emit, &ChannelTelemetry.emit_transport(:desktop_relay, &1, &2, &3)),
      status_changed: Keyword.get(opts, :status_changed, fn -> StatusWatch.changed(:link) end),
      key_opts: Keyword.get(opts, :key_opts, []),
      record_epoch: Keyword.get(opts, :record_epoch, &DesktopLink.record_epoch/3),
      offers: Keyword.get(opts, :offers, ComputerSwitches.listener()),
      computer_caps: %{},
      link: nil,
      keypair: nil,
      phase: :connecting,
      word: :renewing,
      sentence: "Fermix is connecting to its server.",
      since: nil,
      connector: nil,
      rail: nil,
      writer: nil,
      writing: nil,
      outbox: Outbox.new(),
      drops: %{},
      path: nil,
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
      fetches: %{}
    }
  end

  # The key moves out of an older Fermix's file first, then is read from the
  # store the link records. A key it cannot use still lets the relay name the
  # primary it refuses to reach.
  defp load(root, key_opts) do
    moved = ComputerKey.migrate(root, key_opts)

    with {:link, {:ok, link}} <- {:link, DesktopLink.read(root)},
         {:key, _link, done} when done in [:migrated, :nothing] <- {:key, link, moved},
         {:key, _link, {:ok, keypair}} <- {:key, link, ComputerKey.read(root, key_opts)} do
      {:ok, link, keypair}
    else
      {:link, {:error, reason}} -> {:error, {:link, reason}, nil}
      {:key, link, {:error, reason}} -> {:error, reason, link}
    end
  end

  # A link or key this relay cannot use: it says why and never dials. A
  # locked keyring alone is asked again, on the backoff, `@max_key_tries`
  # times in all.
  defp refused(reason, link, state) do
    tries = state.failures + 1
    sentence = refusal_sentence(reason, tries)
    Logger.error("desktop relay: not connecting to the primary: #{sentence}")
    again? = locked?(reason) and tries < @max_key_tries

    %{
      state
      | link: link,
        phase: :refused,
        word: :unreachable,
        failures: tries,
        sentence: sentence,
        reconnect: if(again?, do: arm(state, :reload, backoff(tries)))
    }
  end

  defp refusal_sentence(reason, tries) do
    sentence = ComputerKey.error_sentence(reason)

    cond do
      not locked?(reason) ->
        sentence

      tries < @max_key_tries ->
        "#{sentence} Fermix tries again in #{div(backoff(tries), 1_000)} s."

      true ->
        "#{sentence} Start Fermix again once it is unlocked."
    end
  end

  defp locked?({:unusable, %{state: :locked}}), do: true
  defp locked?(_reason), do: false

  defp reload(state) do
    case load(state.root, state.key_opts) do
      {:ok, link, keypair} ->
        Logger.info("desktop relay: this computer's key is readable now; connecting")
        :ok = state.status_changed.()

        connect(%{
          state
          | link: link,
            keypair: keypair,
            failures: 0,
            word: :renewing,
            sentence: "Fermix is connecting to its server."
        })

      {:error, reason, link} ->
        refused(reason, link, state)
    end
  end

  @impl true
  def handle_continue(:connect, state), do: {:noreply, connect(state)}

  @impl true
  def handle_call(:status, _from, state), do: {:reply, status_view(state), state}

  def handle_call({:forward, request, deadline_ms}, from, state),
    do: forward_call(request, deadline_ms, from, state)

  def handle_call(:open_channel, {tunnel, _tag}, state), do: open(tunnel, state)
  def handle_call({:fetch_media, ref}, {tunnel, _tag}, state), do: fetch(ref, tunnel, state)

  # Answered once its last frame is written (`written/3`). A computer's own
  # event goes only to a server whose hello_ack takes it (M97 §5.3).
  def handle_call({:send, type, _fields, _payload}, _from, %{phase: :connected} = state)
      when is_map_key(@computer_events, type) and not is_map_key(state.computer_caps, type),
      do: {:reply, {:error, {:not_taken, type}}, state}

  def handle_call({:send, type, fields, payload}, from, %{phase: :connected} = state) do
    case enqueue(state, type, fields, payload, {:reply, from}) do
      {:ok, state} -> {:noreply, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

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

  def handle_info(
        {:relay_written, writer, ref, result},
        %{writer: writer, writing: {ref, tag}} = state
      ),
      do: {:noreply, written(result, tag, state)}

  # The word of a writer let go with its session.
  def handle_info({:relay_written, _writer, _ref, _result}, state), do: {:noreply, state}

  def handle_info({:relay_media_done, ref, result}, state),
    do: {:noreply, media_done(ref, result, state)}

  def handle_info({:DOWN, _monitor, :process, pid, _reason}, state),
    do: {:noreply, tunnel_down(pid, state)}

  def handle_info({:EXIT, connector, reason}, %{connector: connector} = state),
    do: {:noreply, link_down({:connector_exit, reason}, %{state | connector: nil, rail: nil})}

  def handle_info({:EXIT, writer, reason}, %{writer: writer} = state),
    do: {:noreply, drop_session({:writer_exit, reason}, %{state | writer: nil})}

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(message, state) do
    Logger.debug("desktop relay ignored #{inspect(message)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    _state = stop_writer(state)
    :ok = stop_connector(state)
  end

  # -- connecting ------------------------------------------------------------

  defp connect(state) do
    relay = self()
    route = route(state)
    opts = rail_opts(state)
    {:ok, connector} = Task.start_link(fn -> run_connector(relay, route, opts) end)
    %{state | connector: connector, rail: nil, path: nil, phase: :connecting, computer_caps: %{}}
  end

  defp route(%{link: %{primary: primary}}),
    do: Map.take(primary, [:node_id, :relays, :relays_rev, :addrs])

  defp rail_opts(state) do
    base = [
      static_keypair: state.keypair,
      remote_static: state.link.primary.gateway_pk,
      paths: true
    ]

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
    :ok = helper_started(Keyword.get(opts, :helper))

    case Rail.open(route, :ik, opts) do
      {:ok, rail} ->
        send(relay, {:relay_connector, self(), {:opened, rail}})
        carry(relay, rail)

      {:error, reason} ->
        send(relay, {:relay_connector, self(), {:failed, reason}})
        :ok
    end
  end

  # The helper's start is waited for; how it settled is the dial's to say.
  defp helper_started(nil), do: :ok

  defp helper_started(helper) do
    _settled = Helper.await_ready(helper, @helper_wait_ms)
    :ok
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

      {:rail, ^rail, {:path, path}} ->
        send(relay, {:relay_connector, self(), {:path, path}})
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

  # The session's writer: it writes each frame the relay hands it to the rail,
  # one at a time, and says how that went, so the relay never waits on a
  # write and the rail gives each frame the next `seq` in the order written.
  # It serves no calls; it ends with its session (`stop_writer/1`) or the
  # relay.
  defp start_writer(state) do
    relay = self()
    {rail, write} = {state.rail, state.write}
    %{state | writer: spawn_link(fn -> run_writer(relay, rail, write) end), writing: nil}
  end

  @doc false
  @spec run_writer(pid(), pid(), (pid(), String.t(), map(), binary() -> :ok | {:error, term()})) ::
          no_return()
  def run_writer(relay, rail, write) do
    receive do
      {:relay_write, ref, {type, fields, bytes}} ->
        send(relay, {:relay_written, self(), ref, rail_write(write, rail, type, fields, bytes)})
        run_writer(relay, rail, write)
    end
  end

  # A session that ended under the write answers its own ending.
  defp rail_write(write, rail, type, fields, bytes) do
    write.(rail, type, fields, bytes)
  catch
    :exit, reason -> {:error, {:rail_down, reason}}
  end

  defp stop_writer(%{writer: nil} = state), do: state

  defp stop_writer(%{writer: writer} = state) do
    Process.unlink(writer)
    Process.exit(writer, :kill)
    %{state | writer: nil}
  end

  # The session's lanes start empty, so its first frame is the hello.
  defp connector_message({:opened, rail}, state) do
    state = start_writer(%{state | rail: rail})

    case enqueue(state, "hello", hello(state), <<>>, nil) do
      {:ok, state} -> {:noreply, state}
      {:error, reason, state} -> {:noreply, drop_session({:hello, reason}, state)}
    end
  end

  defp connector_message({:failed, reason}, state),
    do: {:noreply, link_down(reason, %{state | connector: nil, rail: nil})}

  defp connector_message({:closed, reason}, state),
    do: {:noreply, link_down(ending(reason, state), %{state | connector: nil, rail: nil})}

  defp connector_message({:path, %{kind: kind}}, %{path: kind} = state), do: {:noreply, state}

  defp connector_message({:path, %{kind: kind}}, state) do
    state = %{state | path: kind}

    if state.phase == :connected do
      Logger.info("desktop relay: the session to #{name(state)} runs #{path_words(kind)}")
      :ok = state.status_changed.()
      {:noreply, send_link_path(state)}
    else
      {:noreply, state}
    end
  end

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
      "primary_epoch" => state.link.epoch,
      "platform" => platform()
    }
  end

  # The system this computer runs (M97 §3.2), which its hello names.
  defp platform do
    case :os.type() do
      {:unix, :darwin} -> "macos"
      {:unix, :linux} -> "linux"
    end
  end

  defp unserved(type, state) do
    Logger.warning("desktop relay: the primary sent #{type}, which this desktop does not serve")
    state
  end

  # -- the session's own events --------------------------------------------------

  defp take(:session, "hello_ack", fields, _tail, state), do: hello_ack(fields, state)
  defp take(:session, "pong", _fields, _tail, state), do: state
  defp take(:session, "error", fields, _tail, state), do: primary_error(fields, state)

  defp take(family, type, fields, tail, state)
       when family in [:channels, :calls, :loopback, :invoke] do
    if Chunks.chunked?(type),
      do: take_chunk(family, type, fields, tail, state),
      else: complete(family, type, fields, tail, state)
  end

  defp take(:media, type, fields, tail, state), do: media(type, fields, tail, state)
  defp take(:snapshots, type, fields, tail, state), do: snapshot(type, fields, tail, state)

  defp hello_ack(fields, %{link: link} = state) do
    case fields["primary_epoch"] do
      epoch when is_integer(epoch) and epoch >= link.epoch -> connected(epoch, fields, state)
      epoch -> drop_session({:stale_primary, link.epoch, epoch}, state)
    end
  end

  defp connected(epoch, fields, state) do
    case keep_epoch(state.link, epoch, state) do
      {:ok, link} -> session_up(keep_route(link, fields, state.root), fields, state)
      {:error, reason} -> drop_session({:epoch_not_kept, epoch, reason}, state)
    end
  end

  defp session_up(link, fields, state) do
    max_media = media_bound(get_in(fields, ["caps", "max_media_bytes"]))
    caps = Map.get(fields, "caps", %{})
    :ok = state.status_changed.()
    :ok = DesktopOffers.connected(state.offers, caps)

    if state.degraded?, do: state.emit.(:recovered, state.failures, :none)

    %{
      state
      | link: link,
        computer_caps: computer_caps(caps),
        phase: :connected,
        word: :connected,
        since: state.clock.(),
        down_since_ms: nil,
        down_at: nil,
        failures: 0,
        degraded?: false,
        max_media_bytes: max_media,
        sentence: "Fermix is connected to the server #{link.primary.name}."
    }
    |> send_link_path()
  end

  # The computer's own events the server's hello_ack takes (M97 §5.3), by
  # event: none from a server older than the computer record.
  defp computer_caps(%{"computer" => %{} = computer}) do
    for {type, flag} <- @computer_events,
        Map.get(computer, flag) == true,
        into: %{},
        do: {type, true}
  end

  defp computer_caps(_caps), do: %{}

  # Only the dialing side learns whether the path is direct or relayed (M97
  # §17), so it tells the server: at the session's start once the helper has
  # named it, and at each change, where the server takes it.
  defp send_link_path(%{path: path, computer_caps: %{"link_path" => true}} = state)
       when path in [:direct, :relay] do
    case enqueue(state, "link_path", %{"path" => Atom.to_string(path)}, <<>>, nil) do
      {:ok, state} -> state
      {:error, reason, state} -> unsent_link_path(reason, state)
    end
  end

  defp send_link_path(state), do: state

  defp unsent_link_path(reason, state) do
    Logger.warning("desktop relay: the session's path was not sent: #{inspect(reason)}")
    state
  end

  # The primary names its blob bound; this desktop takes no more than its own
  # ceiling, whatever that says.
  defp media_bound(bytes) when is_integer(bytes) and bytes > 0,
    do: min(bytes, @desktop_max_media_bytes)

  defp media_bound(_unsaid), do: @default_max_media_bytes

  # The epoch the file holds is raised before anything relies on it, and the
  # file is the one place it lives: `Desktop.Invoke`'s Admission reads it
  # there for every request. A newer epoch this computer cannot write is
  # never held in memory alone: the session is not used, said once here and
  # in the status, and tried again with the backoff.
  defp keep_epoch(link, epoch, state) do
    case state.record_epoch.(state.root, link, epoch) do
      {:ok, link} ->
        {:ok, link}

      {:error, reason} = error ->
        Logger.error(
          "desktop relay: the primary epoch #{epoch} was not kept, so the session is not used: " <>
            inspect(reason)
        )

        error
    end
  end

  # The primary's route for its own node, when it names another relay list:
  # kept, so the next hello acknowledges it. One the link cannot hold is
  # refused and the link keeps the route it has: relays that are not a list,
  # or a revision that is not text, here; any other relays or revision the
  # link refuses when it writes them (`record_route/3`).
  defp keep_route(link, fields, root) do
    node_id = link.primary.node_id

    case Enum.find(
           fields["candidates"] || [],
           &match?(%{"kind" => "iroh", "node_id" => ^node_id}, &1)
         ) do
      %{"relays" => relays, "relays_rev" => rev} = route
      when is_list(relays) and is_binary(rev) ->
        record_route(link, {relays, rev, route_hints(route)}, root)

      nil ->
        link

      _unusable ->
        Logger.warning(
          "desktop relay: the primary's route was not kept: " <>
            "it names no list of relays and relay revision"
        )

        link
    end
  end

  # The codec checks only that `candidates` is a list: hints that are not a
  # list of at most 8 `ip:port` hints are dropped here, so a server of
  # another build costs this link its hints, never the relay.
  defp route_hints(%{"addrs" => addrs}) do
    if DesktopLink.hints?(addrs) do
      addrs
    else
      Logger.warning(
        "desktop relay: the primary's address hints were dropped: " <>
          "not a list of at most 8 ip:port hints"
      )

      []
    end
  end

  defp route_hints(_route), do: []

  defp record_route(link, route, root) do
    case DesktopLink.record_route(root, link, route) do
      {:ok, link} ->
        link

      {:error, reason} ->
        Logger.error("desktop relay: the primary's route was not kept: #{inspect(reason)}")
        link
    end
  end

  defp path_words(:direct), do: "directly"
  defp path_words(:relay), do: "through the relay"

  # An error that names a ref ends that fetch; any other the primary's own
  # refusal of something this desktop sent, which leaves the session open.
  defp primary_error(%{"ref" => ref} = fields, state) do
    :ok = to_family(state, :media, &MediaFetches.drop(&1, ref))
    media_done(ref, {:error, media_code(fields["code"])}, state)
  end

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

  defp complete(:loopback, type, fields, payload, state),
    do: loopback(type, fields, payload, state)

  defp complete(:invoke, type, fields, payload, state),
    do: invocation(type, fields, payload, state)

  # -- sending (M97 §5.1: lanes) ---------------------------------------------------

  # Queues one event's frames in its lane and writes the next frame if the
  # writer is free; `tag` comes back once its last frame is written. Each
  # frame is checked by the codec first, so none the rail would refuse is
  # queued, and an event its lane cannot take is refused whole.
  defp enqueue(state, type, fields, payload, tag) do
    with {:ok, lane} <- Lanes.lane(type, fields),
         {:ok, frames} <- frames(type, fields, payload) do
      case Outbox.put(state.outbox, lane, frames, tag) do
        {:ok, outbox} -> {:ok, pump(%{state | outbox: outbox})}
        {:error, :busy, outbox} -> {:error, :busy, lane_refused(lane, %{state | outbox: outbox})}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp frames(type, fields, payload) do
    pieces =
      if Chunks.chunked?(type),
        do:
          for(
            {index, last, bytes} <- Chunks.split(payload),
            do: {Map.merge(fields, %{"index" => index, "last" => last}), bytes}
          ),
        else: [{fields, payload}]

    Enum.reduce_while(pieces, {:ok, []}, fn {fields, bytes}, {:ok, frames} ->
      case Protocol.encode_client_frame(type, fields, 1, bytes, []) do
        {:ok, _plaintext} -> {:cont, {:ok, [{type, fields, bytes} | frames]}}
        {:error, reason} -> {:halt, {:error, {:invalid_event, type, reason}}}
      end
    end)
    |> then(fn
      {:ok, frames} -> {:ok, Enum.reverse(frames)}
      {:error, _reason} = error -> error
    end)
  end

  # One frame at a time: the next, by lane, once the writer said the last
  # one went.
  defp pump(%{writer: writer, writing: nil} = state) when is_pid(writer) do
    case Outbox.take(state.outbox) do
      {:ok, frame, tag, _lane, outbox} ->
        ref = make_ref()
        send(writer, {:relay_write, ref, frame})
        lanes_drained(%{state | outbox: outbox, writing: {ref, tag}})

      :empty ->
        state
    end
  end

  defp pump(state), do: state

  defp written(:ok, tag, state), do: %{state | writing: nil} |> answer_written(tag) |> pump()

  # The rail refused or ended under the write: the session ends, and the
  # frame's waiter hears so with every other (`fail_everyone/3`).
  defp written({:error, reason}, _tag, state), do: drop_session({:send, reason}, state)

  defp answer_written(state, {:reply, from}) do
    GenServer.reply(from, :ok)
    state
  end

  defp answer_written(state, nil), do: state

  # A lane's refusals are said when they start, and once it drained, with the
  # count (`Outbox.drained/1`), never per frame.
  defp lane_refused(lane, state) do
    if Outbox.refused(state.outbox, lane) == 1 do
      {bytes, frames} = Map.fetch!(Outbox.bounds(), lane)

      Logger.warning(
        "desktop relay: the #{lane} lane is full (#{bytes} bytes or #{frames} frames " <>
          "waiting): its frames are refused until it drains"
      )
    end

    state
  end

  defp lanes_drained(state) do
    {drained, outbox} = Outbox.drained(state.outbox)

    for {lane, refused} <- drained,
        do:
          Logger.warning("desktop relay: the #{lane} lane takes frames again; #{refused} refused")

    %{state | outbox: outbox}
  end

  # -- the families' processes (M97 §5.1) -------------------------------------------

  # Hands one event to `family`'s process, which takes it in its own time:
  # the relay never waits on it. Past the family's bound, or with no process
  # running, it is not handed, and the family's own rule applies.
  defp hand_off(state, family, cast) do
    bound = Map.fetch!(@family_bounds, family)

    case backlog(Map.fetch!(state.families, family)) do
      {:ok, pid, waiting} when waiting < bound ->
        :ok = cast.(pid)
        :handed

      {:ok, _pid, _waiting} ->
        :full

      :down ->
        :down
    end
  end

  # A word the family's process must have whatever waits there: one per
  # stream it ends, never per frame.
  defp to_family(state, family, cast) do
    case GenServer.whereis(Map.fetch!(state.families, family)) do
      pid when is_pid(pid) -> cast.(pid)
      nil -> :ok
    end
  end

  defp backlog(server) do
    with pid when is_pid(pid) <- GenServer.whereis(server),
         {:message_queue_len, waiting} <- Process.info(pid, :message_queue_len) do
      {:ok, pid, waiting}
    else
      _gone -> :down
    end
  end

  # A family's events the relay could not hand over are dropped: a run of
  # them is said when it starts and when it ends, with the count. A run with
  # a key is one stream's (a refused copy, a busy blob), which ends with that
  # stream; one keyed `:all` (no process running, a full loopback) ends with
  # the next event handed.
  defp drop(state, family, key, sentence) do
    case state.drops do
      %{^family => %{key: ^key} = run} ->
        put_in(state.drops[family], %{run | dropped: run.dropped + 1})

      _other ->
        state = end_drops(state, family)
        Logger.warning("desktop relay: #{sentence}")
        put_in(state.drops[family], %{key: key, dropped: 1})
    end
  end

  defp end_drops(state, family) do
    case Map.pop(state.drops, family) do
      {nil, _drops} ->
        state

      {run, drops} ->
        Logger.warning(
          "desktop relay: #{family_words(family)} taken again; #{run.dropped} dropped"
        )

        %{state | drops: drops}
    end
  end

  defp handed(state, family) do
    case state.drops do
      %{^family => %{key: :all}} -> end_drops(state, family)
      _other -> state
    end
  end

  defp dropping?(state, family, key), do: match?(%{^family => %{key: ^key}}, state.drops)

  defp family_words(:snapshots), do: "snapshots are"
  defp family_words(:media), do: "media frames are"
  defp family_words(:loopback), do: "sign-in forwards are"
  defp family_words(:invoke), do: "the server's requests are"

  defp not_running(family),
    do:
      "#{family_words(family)} not taken here (their process is not running): " <>
        "their frames are dropped until it runs again"

  # -- the snapshot copies -----------------------------------------------------------

  # A new copy ends the run before it. A copy whose frames outran this disk
  # past the store's bound is refused (`write_failed`), the store told by
  # name, and its later frames dropped until its end.
  defp snapshot(type, %{"snapshot_id" => id} = fields, tail, state) do
    state = if type == "snapshot_begin", do: end_drops(state, :snapshots), else: state

    if dropping?(state, :snapshots, id),
      do: drop_snapshot(type, id, state),
      else: hand_snapshot(type, fields, tail, state)
  end

  defp hand_snapshot(type, %{"snapshot_id" => id} = fields, tail, state) do
    case hand_off(state, :snapshots, &SnapshotStore.handle(&1, type, fields, tail)) do
      :handed -> handed(state, :snapshots)
      :full -> refuse_copy(type, id, state)
      :down -> drop(state, :snapshots, :all, not_running(:snapshots))
    end
  end

  defp refuse_copy(type, id, state) do
    bound = Map.fetch!(@family_bounds, :snapshots)
    :ok = to_family(state, :snapshots, &SnapshotStore.refuse(&1, id, "write_failed"))

    sentence =
      "the snapshot copy #{id} outran this computer's disk (#{bound} frames waiting): " <>
        "it is refused, and its later frames dropped"

    state |> drop(:snapshots, id, sentence) |> copy_ended(type)
  end

  # Only a run of this copy's own is under way here.
  defp drop_snapshot(type, id, state),
    do: state |> drop(:snapshots, id, "") |> copy_ended(type)

  defp copy_ended(state, "snapshot_end"), do: end_drops(state, :snapshots)
  defp copy_ended(state, _type), do: state

  # -- the sign-in loopbacks ---------------------------------------------------------

  defp loopback(type, fields, payload, state) do
    case hand_off(state, :loopback, &Loopback.handle(&1, type, fields, payload)) do
      :handed ->
        handed(state, :loopback)

      :full ->
        bound = Map.fetch!(@family_bounds, :loopback)

        drop(
          state,
          :loopback,
          :all,
          "the sign-in forward is behind (#{bound} events waiting): its events are dropped"
        )

      :down ->
        drop(state, :loopback, :all, not_running(:loopback))
    end
  end

  # -- the invocations (M97 §6.2) --------------------------------------------------------

  # A request, its part's frames, a cancel or a status ask, each as it came.
  # One that cannot be handed is dropped and answered by nothing: while the
  # session stays up the server waits out its deadline (an effect ends not
  # known, a read timed out); only a session that ends first has the server
  # ask for its state at the next one, and hear that there is no record.
  defp invocation(type, fields, payload, state) do
    case hand_off(state, :invoke, &Invoke.handle(&1, type, fields, payload)) do
      :handed ->
        handed(state, :invoke)

      :full ->
        bound = Map.fetch!(@family_bounds, :invoke)
        sentence = "the server's requests are behind (#{bound} waiting): its events are dropped"
        drop(state, :invoke, :all, sentence)

      :down ->
        drop(state, :invoke, :all, not_running(:invoke))
    end
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

    case enqueue(state, "companion_open", %{"channel" => channel}, <<>>, nil) do
      {:ok, state} ->
        entry = %{pid: tunnel, monitor: Process.monitor(tunnel)}
        next = rem(channel, @channel_numbers) + 1

        {:reply, {:ok, channel, self()},
         %{state | channels: Map.put(state.channels, channel, entry), next_channel: next}}

      {:error, :busy, state} ->
        {:reply, {:error, :busy}, state}

      {:error, _reason, state} ->
        {:reply, {:error, {:unreachable, unreachable_sentence(state)}}, state}
    end
  end

  # At most 4 of 64 numbers are taken, so a free one is found within 5 steps.
  defp free_channel(channel, channels) do
    if Map.has_key?(channels, channel),
      do: free_channel(rem(channel, @channel_numbers) + 1, channels),
      else: channel
  end

  # A line the interactive lane cannot take ends its chat as too busy: the
  # app keeps its outbox and reconnects.
  defp send_line_frames(channel, line, state) do
    case enqueue(state, "companion_line", %{"channel" => channel}, line, nil) do
      {:ok, state} -> state
      {:error, :busy, state} -> too_busy(channel, state)
      {:error, reason, state} -> drop_session({:send, reason}, state)
    end
  end

  defp too_busy(channel, state) do
    %{pid: tunnel} = Map.fetch!(state.channels, channel)

    sentence =
      "The link to the server #{name(state)} is too busy to carry this chat. Try again."

    send(tunnel, {:relay_down, channel, sentence})
    end_channel(channel, tunnel, state)
  end

  # Its close is a frame with no bytes, which a full interactive lane still
  # takes unless it holds 4,096 frames; one it refuses is logged.
  defp end_channel(channel, tunnel, state) do
    case Map.fetch(state.channels, channel) do
      {:ok, %{pid: ^tunnel, monitor: monitor}} ->
        Process.demonitor(monitor, [:flush])
        state = %{state | channels: Map.delete(state.channels, channel)}
        send_close(channel, state)

      _other ->
        state
    end
  end

  defp send_close(channel, state) do
    case enqueue(state, "companion_close", %{"channel" => channel}, <<>>, nil) do
      {:ok, state} ->
        state

      {:error, reason, state} ->
        Logger.warning(
          "desktop relay: channel #{channel}'s close was not sent: #{inspect(reason)}"
        )

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

  # The channel's tunnel writes each line to the app in its own time; one
  # whose app left @max_tunnel_lines unread ends that chat, once.
  defp channel_event("companion_line", %{"channel" => channel}, line, state) do
    case Map.fetch(state.channels, channel) do
      {:ok, %{pid: tunnel}} ->
        hand_line(tunnel, channel, line, state)

      :error ->
        Logger.debug("desktop relay: a line for channel #{channel}, which is closed")
        state
    end
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

  defp hand_line(tunnel, channel, line, state) do
    case Process.info(tunnel, :message_queue_len) do
      {:message_queue_len, waiting} when waiting < @max_tunnel_lines ->
        send(tunnel, {:relay_line, channel, line})
        state

      # Gone: its `:DOWN` ends the channel.
      nil ->
        state

      {:message_queue_len, _behind} ->
        Logger.warning(
          "desktop relay: channel #{channel}'s app left #{@max_tunnel_lines} lines unread: " <>
            "its chat ends"
        )

        sentence = "This chat fell too far behind the server #{name(state)}. Try again."
        send(tunnel, {:relay_down, channel, sentence})
        end_channel(channel, tunnel, state)
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
      {:ok, state} ->
        put_in(state.calls[call_id], %{from: from, deadline: deadline, method: request.method})

      {:error, {:too_large, bound}, state} ->
        cancel(state, deadline)
        too_large = %{"field" => "params", "maximum_bytes" => bound}
        GenServer.reply(from, {:error, :invalid_params, too_large})
        state

      # The interactive lane is full: busy, as past the waiting calls.
      {:error, :busy, state} ->
        cancel(state, deadline)
        GenServer.reply(from, {:error, :busy, %{"operation" => "forwarded management"}})
        state

      {:error, reason, state} ->
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
      do: {:error, {:too_large, bound}, state},
      else: enqueue(state, "manage", fields, params, nil)
  end

  # Never dropped, and never decoded here: the caller decodes it (`answered/1`).
  defp call_answered(%{"call_id" => call_id}, payload, state) do
    case Map.pop(state.calls, call_id) do
      {%{from: from, deadline: deadline}, calls} ->
        cancel(state, deadline)
        GenServer.reply(from, {:relay_answer, payload})
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
         {:ok, state} <- enqueue(state, "media_fetch", %{"ref" => ref}, <<>>, nil) do
      {:reply, :ok, put_in(state.fetches[ref], [tunnel])}
    else
      false -> {:reply, {:error, :busy}, state}
      {:error, :busy, state} -> {:reply, {:error, :busy}, state}
      {:error, _reason, state} -> {:reply, unreachable_media(state), state}
    end
  end

  defp unreachable_media(state), do: {:error, {:unreachable, unreachable_sentence(state)}}

  defp forget_fetcher(pid, state) do
    fetches = Map.new(state.fetches, fn {ref, waiters} -> {ref, List.delete(waiters, pid)} end)
    %{state | fetches: fetches}
  end

  # Blobs come one at a time, written in `Desktop.MediaFetches`, which says
  # how each ended (`{:relay_media_done, ref, result}`); a begin for a ref
  # nobody here asked for is left unstaged there, and its chunks with it. A new
  # blob ends the run before it, and a blob's end its own.
  defp media("media_begin" = type, %{"ref" => ref} = fields, _tail, state) do
    state = end_drops(state, :media)
    {wanted?, max} = {Map.has_key?(state.fetches, ref), state.max_media_bytes}
    hand_media(type, ref, &MediaFetches.begin(&1, self(), fields, wanted?, max), state)
  end

  defp media(type, %{"ref" => ref} = fields, tail, state) do
    if dropping?(state, :media, ref),
      do: state |> drop(:media, ref, "") |> blob_ended(type),
      else: hand_media(type, ref, media_cast(type, ref, fields, tail), state)
  end

  defp media_cast("media_chunk", ref, fields, tail),
    do: &MediaFetches.chunk(&1, ref, fields["index"], tail)

  defp media_cast("media_end", ref, _fields, _tail), do: &MediaFetches.finish(&1, ref)

  defp blob_ended(state, "media_end"), do: end_drops(state, :media)
  defp blob_ended(state, _type), do: state

  # A blob that outran this disk past the bound fails busy, and its later
  # frames are dropped; with no process to write it, its waiters hear so.
  defp hand_media(type, ref, cast, state) do
    case hand_off(state, :media, cast) do
      :handed ->
        handed(state, :media)

      :full ->
        bound = Map.fetch!(@family_bounds, :media)
        :ok = to_family(state, :media, &MediaFetches.drop(&1, ref))

        sentence =
          "the blob #{ref} outran this computer's disk (#{bound} frames waiting): " <>
            "its fetch fails busy, and its later frames are dropped"

        state
        |> drop(:media, ref, sentence)
        |> blob_ended(type)
        |> then(&media_done(ref, {:error, :busy}, &1))

      :down ->
        state
        |> drop(:media, :all, not_running(:media))
        |> then(&media_done(ref, {:error, :not_running}, &1))
    end
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

    if waiters == [] and match?({:ok, _media}, result),
      do: :ok = to_family(state, :media, &MediaFetches.discard(&1, ref))

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
    state = stop_writer(state)

    state =
      case ending_kind(reason, state) do
        :renewal -> renewal(reason, state)
        :revoked -> revoked(reason, state)
        :outage -> outage(reason, state)
      end

    state = %{state | path: nil}

    :ok = state.status_changed.()
    state
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
        down_at: down_at(state),
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
        down_at: down_at(state),
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
        down_at: down_at(state),
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

  defp down_at(%{down_at: nil} = state), do: state.clock.()
  defp down_at(%{down_at: at}), do: at

  defp outage_word({:stale_primary, _mine, _theirs}), do: :stale
  defp outage_word(_reason), do: :unreachable

  defp backoff(failures),
    do: min(@first_backoff_ms * Integer.pow(2, min(failures - 1, 6)), @max_backoff_ms)

  # Every open channel's tunnel hears `{tunnel_word, channel, sentence}`:
  # `:relay_down` for an ending tried again, `:relay_revoked` for a primary
  # that no longer knows this computer.
  defp fail_everyone(state, sentence, tunnel_word \\ :relay_down)
       when tunnel_word in [:relay_down, :relay_revoked] do
    :ok = to_family(state, :media, &MediaFetches.abort/1)
    state = fail_unwritten(state, sentence)
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
        open: %{}
    }
  end

  # The frames not yet written go with their session; whoever waits on one
  # (`send_event/3`) is told it ended. The lanes start empty, and a lane that
  # was refusing says it takes frames again.
  defp fail_unwritten(state, sentence) do
    {tags, outbox} = Outbox.clear(state.outbox)

    writing =
      case state.writing do
        {_ref, tag} -> [tag]
        nil -> []
      end

    for {:reply, from} <- writing ++ tags,
        do: GenServer.reply(from, {:error, {:unreachable, sentence}})

    lanes_drained(%{state | outbox: outbox, writing: nil})
  end

  defp down_sentence({:stale_primary, mine, theirs}, state) do
    "The server #{state.link.primary.name} answered as an older copy of Fermix " <>
      "(#{stale_epochs(mine, theirs)}), so Fermix does not use it."
  end

  defp down_sentence({:epoch_not_kept, _epoch, reason}, state) do
    "Fermix could not record that the server #{state.link.primary.name} is a newer copy of " <>
      "this computer's home, so it does not use it: #{unkept(reason)}."
  end

  defp down_sentence({:renewed_again, _renewals}, state),
    do: "The server #{state.link.primary.name} ends this computer's session each time it opens."

  defp down_sentence(reason, state),
    do: "The server #{state.link.primary.name} is unreachable: #{why(reason)}."

  defp unkept({:file, _path, posix}),
    do: "the link file could not be written (#{:file.format_error(posix)})"

  defp unkept({:invalid_link, _path, field}), do: "the link file's #{field} is not valid"

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
  defp error_class({:epoch_not_kept, _epoch, _reason}), do: :epoch_not_kept
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

  defp timer(:reload, token, %{reconnect: {_ref, token, :reload}} = state),
    do: {:noreply, reload(%{state | reconnect: nil})}

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
      down_ms: down_ms(state),
      down_at: state.down_at,
      path: nil
    }
  end

  defp status_view(state) do
    connected? = state.phase == :connected

    %{
      name: state.link.primary.name,
      connected: connected?,
      status: state.word,
      since: state.since,
      epoch: state.link.epoch,
      sentence: state.sentence,
      down_ms: down_ms(state),
      down_at: state.down_at,
      path: if(connected?, do: state.path)
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
