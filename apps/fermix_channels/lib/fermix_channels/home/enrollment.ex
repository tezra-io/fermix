defmodule FermixChannels.Home.Enrollment do
  @moduledoc """
  The primary's enrollment window (M75 §7.1): the one place a candidate
  primary is admitted, and the one writer of `<home>/mobile/candidates.json`
  (`FermixCore.Home.Candidates`).

  `open/2` (through `FermixChannels.Home.Link`) opens one window, replacing
  an open one, and answers its code (`FermixCore.Home.EnrollmentCode`): a
  fresh 32-byte secret, this primary's gateway key, its iroh endpoint id, the
  relays its endpoint listens on (the ones every paired device acknowledged),
  the host's name and the expiry. A window has a kind (M75 lean v1 L15):
  `:manual`, the code a person copies onto a server of their own
  (Always On's `own_server`, `home.act`), lives thirty minutes; `:provisioned`, the code Fermix
  puts inside a server it creates (`FermixCore.Home.Provision`), lives 24
  hours, so a slow install or a sleeping computer does not fail it. Only one
  window is open at a time, so a manual one is refused, in one sentence,
  while a provisioned window is open and unexpired (a new code would strand
  the server that waits for its own), and, in another, while a used
  provisioned window's candidate is still held, or still enrolling within
  the window: replacing that window would lose which candidate the created
  server is. `withdraw/2` releases the window of the kind it names: the
  provisioned one when its server was never created or is being deleted,
  the manual one when the owner cancels its code (an open one ends now); a
  window of the other kind is left alone. The
  code is answered once and never logged; the window (its kind, secret,
  expiry, and who used it) is kept in `<home>/mobile/enrollment.json`
  (`0600`, device-local), so an engine restart between opening a code and the
  server's check-in loses nothing. The window records which candidate used
  it, which is how a created server is known when it enrolls: the code is
  single use.

  A stream with the enrollment prelude (`FXM1 0x03`) reaches the window
  through `FermixChannels.Home.EnrollmentResponder` while a window is held
  (`window?/1`). The first session that proves the secret burns it
  (`take/2`): the window is then `used`, and a later session with the same
  secret is answered `enrollment_used`, except the candidate that used it
  (the same Noise key), whose `enroll_accepted` was lost: while the window
  lasts it is answered again with the candidate id it was given, and after
  that `enrollment_expired` like anyone. One after the thirty minutes is
  answered `enrollment_expired`. The window is remembered until another
  replaces it, so a late candidate hears why. `enroll/3` records the
  candidate, at most #{4} held (`enrollment_limit` past them).

  The file keeps the secret only while it can still admit a new candidate:
  once the window is used and its candidate recorded, or once it expired (a
  timer at its expiry, or the next start of the engine), the secret leaves
  `enrollment.json`, and the state, the expiry, who used it and the candidate
  id stay, for the status. The running window keeps what it holds, so the
  candidate whose answer was lost is admitted again and a late one hears why;
  an engine that starts from a file without the secret holds none, and no
  handshake completes against its window.

  The status also says how long this engine has held the window while the
  computer was awake (`awake_ms`, on the monotonic clock, which stops while it
  sleeps), counted from when it was opened or, after a restart, read back:
  `home.status.summary` calls a created server that never checked in within
  30 minutes of it a server that did not finish setting up (M75 lean v1 §7),
  and a sleeping computer is never the server's fault.

  Every change it keeps (a window opened, used, given its candidate or
  withdrawn) and its expiry tell the Always On watch
  (`FermixCore.Home.StatusWatch`, `:enrollment`): the summary an app draws
  reads the window (companion protocol 6).

  Primary only: `FermixCore.Home.Role` leaves it out of a device and a
  candidate. Test seams: `:home`, `:helper`, `:device_store`, `:clock` (a
  0-arity `DateTime`), `:monotonic` (a 0-arity count of milliseconds),
  `:schedule` (a 2-arity `Process.send_after/3` stand-in for the expiry),
  `:host_name`, `:identity` (a 1-arity loader answering the gateway's public
  key for a home), `:status_changed` (a 0-arity call in place of telling the
  Always On watch).
  """

  use GenServer

  require Logger

  alias FermixChannels.Mobile.DeviceStore
  alias FermixChannels.Mobile.Identity
  alias FermixChannels.Mobile.Iroh.Helper
  alias FermixChannels.Mobile.Iroh.Relays
  alias FermixCore.Home.Candidates
  alias FermixCore.Home.EnrollmentCode
  alias FermixCore.Home.StatusWatch
  alias FermixCore.Setup.ConfigStore

  # How long a window of each kind stays open, in seconds (L15).
  @window_s %{manual: 1_800, provisioned: 86_400}
  @kinds Map.keys(@window_s)
  @file_name "enrollment.json"
  @file_mode 0o600
  @server_waits_sentence "Your new server is still setting up with a code of its own, so " <>
                           "Fermix opens no other code until that server connects or is deleted."
  @server_held_sentence "Your new server waits for its move with the code Fermix gave it, so " <>
                          "Fermix opens no other code until you move to it or delete it."

  @type kind :: :manual | :provisioned
  @type window_view :: %{
          state: :open | :used | :expired,
          expires_at: DateTime.t(),
          kind: kind(),
          candidate_id: String.t() | nil,
          awake_ms: non_neg_integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "How long a window of `kind` stays open, in seconds."
  @spec window_s(kind()) :: pos_integer()
  def window_s(kind) when kind in @kinds, do: Map.fetch!(@window_s, kind)

  @doc """
  Opens a window of `kind`, replacing any, and answers its code and expiry;
  or `{:error, {:unavailable, sentence}}` when this primary cannot be reached
  over the rail, or when a manual one is asked for while a provisioned window
  is open.
  """
  @spec open(GenServer.server(), kind()) ::
          {:ok, %{code: String.t(), expires_at: DateTime.t()}}
          | {:error, {:unavailable, String.t()}}
  def open(server \\ __MODULE__, kind \\ :manual) when kind in @kinds,
    do: GenServer.call(server, {:open, kind}, 15_000)

  @doc """
  Releases the window when it is of `kind`, so it holds no copied code back:
  one still open ends now (its secret leaves the disk), a used one stays as
  the record of who used it. A provisioned window is released when its
  server was never created or is being deleted, a manual one when the owner
  cancels its code; a window of the other kind, or none, is left as it is.
  Answers `:ok`, or `{:error, {:unavailable, sentence}}` when the window
  could not be kept.
  """
  @spec withdraw(GenServer.server(), kind()) :: :ok | {:error, {:unavailable, String.t()}}
  def withdraw(server \\ __MODULE__, kind) when kind in @kinds,
    do: GenServer.call(server, {:withdraw, kind})

  @doc "Whether a window is held (open, used or expired); false when no window process runs."
  @spec window?(GenServer.server()) :: boolean()
  def window?(server \\ __MODULE__) do
    if GenServer.whereis(server), do: GenServer.call(server, :window?), else: false
  catch
    :exit, {reason, _call} when reason in [:noproc, :normal, :shutdown] -> false
  end

  @doc "The held window's secret, for the responder's handshake."
  @spec secret(GenServer.server()) :: {:ok, <<_::256>>} | :none
  def secret(server \\ __MODULE__), do: GenServer.call(server, :secret)

  @doc """
  Burns the window once a session proved its secret with the Noise key
  `remote`: `:ok` the first time while it is open, and again for the
  candidate that used it (`remote` the same); `{:error, :used}` or
  `{:error, :expired}` otherwise.
  """
  @spec take(GenServer.server(), <<_::256>>) :: :ok | {:error, :used | :expired | :none}
  def take(server \\ __MODULE__, <<_::256>> = remote), do: GenServer.call(server, {:take, remote})

  @doc """
  Records the candidate an `enroll_request` described, with the Noise key
  its handshake proved. Answers the candidate's id and this primary's name.
  """
  @spec enroll(GenServer.server(), map(), <<_::256>>) ::
          {:ok, %{candidate_id: String.t(), primary_name: String.t()}}
          | {:error, :limit | term()}
  def enroll(server \\ __MODULE__, request, <<_::256>> = noise_pk) when is_map(request),
    do: GenServer.call(server, {:enroll, request, noise_pk})

  @doc "The window as `home.status` shows it, or nil; nil too when no window process runs."
  @spec status(GenServer.server()) :: window_view() | nil
  def status(server \\ __MODULE__) do
    if GenServer.whereis(server), do: GenServer.call(server, :status), else: nil
  catch
    :exit, {reason, _call} when reason in [:noproc, :normal, :shutdown] -> nil
  end

  @doc "Where the window is kept under `home`."
  @spec path(Path.t()) :: Path.t()
  def path(home) when is_binary(home), do: Path.join([home, "mobile", @file_name])

  @impl true
  def init(opts) do
    home = Keyword.get_lazy(opts, :home, &ConfigStore.fermix_home/0)
    monotonic = Keyword.get(opts, :monotonic, fn -> System.monotonic_time(:millisecond) end)

    state = %{
      home: home,
      helper: Keyword.get(opts, :helper, Helper),
      device_store: Keyword.get(opts, :device_store, DeviceStore),
      clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
      monotonic: monotonic,
      schedule: Keyword.get(opts, :schedule, &Process.send_after(self(), &1, &2)),
      host_name: Keyword.get(opts, :host_name, &host_name/0),
      identity: Keyword.get(opts, :identity, &gateway_public_key/1),
      status_changed:
        Keyword.get(opts, :status_changed, fn -> StatusWatch.changed(:enrollment) end),
      window: load(home),
      held_since_ms: monotonic.()
    }

    {:ok, expire_or_arm(state)}
  end

  @impl true
  def handle_call({:open, kind}, _from, state) do
    with :ok <- room_for(kind, state),
         {:ok, facts} <- code_facts(state) do
      open_window(kind, facts, state)
    else
      {:error, sentence} -> {:reply, {:error, {:unavailable, sentence}}, state}
    end
  end

  def handle_call({:withdraw, kind}, _from, %{window: %{kind: kind, withdrawn?: false}} = state),
    do: withdraw_window(state)

  def handle_call({:withdraw, _kind}, _from, state), do: {:reply, :ok, state}

  def handle_call(:window?, _from, state), do: {:reply, state.window != nil, state}
  def handle_call(:secret, _from, %{window: nil} = state), do: {:reply, :none, state}
  def handle_call(:secret, _from, %{window: %{secret: nil}} = state), do: {:reply, :none, state}
  def handle_call(:secret, _from, state), do: {:reply, {:ok, state.window.secret}, state}

  def handle_call({:take, _remote}, _from, %{window: nil} = state),
    do: {:reply, {:error, :none}, state}

  # The candidate that used the window, back because its answer was lost,
  # while the window lasts.
  def handle_call({:take, remote}, _from, %{window: %{used_by: remote} = window} = state) do
    if DateTime.compare(state.clock.(), window.expires_at) == :lt,
      do: {:reply, :ok, state},
      else: {:reply, {:error, :expired}, state}
  end

  def handle_call({:take, remote}, _from, state) do
    case window_state(state.window, state.clock.()) do
      :open -> keep(state, %{state.window | used?: true, used_by: remote}, :ok)
      other -> {:reply, {:error, other}, state}
    end
  end

  # The candidate already recorded through this window is answered as it was.
  def handle_call(
        {:enroll, _request, noise_pk},
        _from,
        %{window: %{used_by: noise_pk, candidate_id: id}} = state
      )
      when is_binary(id) do
    Logger.info("enrollment: candidate #{id} enrolled again; answered as before")
    {:reply, {:ok, %{candidate_id: id, primary_name: state.window.name}}, state}
  end

  def handle_call({:enroll, request, noise_pk}, _from, state) do
    case Candidates.add(state.home, attrs(request, noise_pk), state.clock.()) do
      {:ok, record} ->
        Logger.info("enrollment: candidate #{record.candidate_id} (#{record.name}) enrolled")
        reply = {:ok, %{candidate_id: record.candidate_id, primary_name: state.window.name}}
        keep(state, %{state.window | candidate_id: record.candidate_id}, reply)

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(:status, _from, %{window: nil} = state), do: {:reply, nil, state}

  def handle_call(:status, _from, %{window: window} = state) do
    view = %{
      state: window_state(window, state.clock.()),
      expires_at: window.expires_at,
      kind: window.kind,
      candidate_id: window.candidate_id,
      awake_ms: state.monotonic.() - state.held_since_ms
    }

    {:reply, view, state}
  end

  @impl true
  def handle_info({:expire, expires_at}, %{window: %{expires_at: expires_at}} = state) do
    state = expire_or_arm(state)
    :ok = state.status_changed.()
    {:noreply, state}
  end

  # A timer of a window another replaced.
  def handle_info({:expire, _expires_at}, state), do: {:noreply, state}

  # -- opening ----------------------------------------------------------------

  # A manual code waits while a created server waits on its own window (L15):
  # while it is open, and once used while its candidate is held (or still
  # enrolling within the window). A provisioned window replaces any.
  defp room_for(:manual, state) do
    case server_waits(state) do
      :open -> {:error, @server_waits_sentence}
      :held -> {:error, @server_held_sentence}
      :none -> :ok
    end
  end

  defp room_for(:provisioned, _state), do: :ok

  defp server_waits(%{window: %{kind: :provisioned, withdrawn?: false} = window} = state) do
    now = state.clock.()

    case {window_state(window, now), window.candidate_id} do
      {:open, _id} -> :open
      {:used, nil} -> if DateTime.compare(now, window.expires_at) == :lt, do: :held, else: :none
      {:used, id} -> held(state.home, id, now)
      {:expired, _id} -> :none
    end
  end

  defp server_waits(_state), do: :none

  # A candidates file that cannot be read holds the code back and says why.
  defp held(home, candidate_id, now) do
    case Candidates.fetch(home, candidate_id, now) do
      {:ok, _record} ->
        :held

      {:error, {:unknown_candidate, _id}} ->
        :none

      {:error, reason} ->
        Logger.error("enrollment: the candidates could not be read: #{inspect(reason)}")
        :held
    end
  end

  defp open_window(kind, facts, state) do
    now = state.clock.()
    expires_at = now |> DateTime.add(window_s(kind), :second) |> DateTime.truncate(:second)
    secret = :crypto.strong_rand_bytes(32)

    case EnrollmentCode.encode(Map.merge(facts, %{secret: secret, expires_at: expires_at})) do
      {:ok, code} ->
        window = %{
          kind: kind,
          withdrawn?: false,
          secret: secret,
          expires_at: expires_at,
          used?: false,
          name: facts.name,
          used_by: nil,
          candidate_id: nil
        }

        Logger.info(
          "enrollment: a #{kind} window is open until #{DateTime.to_iso8601(expires_at)}"
        )

        arm(state, window, now)

        keep(
          %{state | held_since_ms: state.monotonic.()},
          window,
          {:ok, %{code: code, expires_at: expires_at}}
        )

      {:error, reason} ->
        Logger.error("enrollment: no code could be made: #{inspect(reason)}")
        {:reply, {:error, {:unavailable, "Fermix could not make an enrollment code."}}, state}
    end
  end

  # Released: an open window ends now and the write takes its secret off the
  # disk; a used one keeps its expiry and who used it.
  defp withdraw_window(%{window: window} = state) do
    now = DateTime.truncate(state.clock.(), :second)
    Logger.info("enrollment: the #{window.kind} window was withdrawn")

    expires_at =
      if window_state(window, now) == :open, do: now, else: window.expires_at

    case keep(state, %{window | expires_at: expires_at, withdrawn?: true}, :ok) do
      {:reply, :ok, kept} -> {:reply, :ok, %{kept | window: %{kept.window | secret: nil}}}
      refused -> refused
    end
  end

  defp code_facts(state) do
    with {:ok, node_id} <- endpoint(state.helper),
         {:ok, relays} <- listening_relays(state.device_store),
         {:ok, gateway_pk} <- state.identity.(state.home),
         {:ok, name} <- state.host_name.() do
      {:ok,
       %{
         gateway_pk: gateway_pk,
         node_id: node_id,
         relays: relays,
         relays_rev: Relays.current().id,
         name: name
       }}
    end
  end

  # The rail must be ready: a candidate reaches the primary only through it.
  defp endpoint(helper) do
    case Helper.status(helper) do
      %{state: :ready, endpoint_id: id} ->
        {:ok, id}

      %{state: state} when state in [:dormant, :starting] ->
        :ok = Helper.activate(helper)

        {:error, "Remote reach is starting. Open the enrollment code again in a few seconds."}

      %{state: :off} ->
        {:error,
         "Remote reach is off. Turn on Fermix for phones and Reach from anywhere, then open " <>
           "the enrollment code again."}

      %{state: :helper_missing} ->
        {:error, "This build has no remote-reach helper, so a server cannot enroll with it."}

      # The rail's own words (its relays, versions, keys) go to the log and
      # Doctor; an owner reads this refusal, in Always On too.
      %{state: :failed} = status ->
        Logger.warning("enrollment: no code: remote reach failed: #{status[:failure]}")
        {:error, "Remote reach failed, so Fermix opened no code; Doctor says why."}
    end
  end

  # The relays this primary's endpoint listens on: those every paired device
  # acknowledged, as the helper itself computes them.
  defp listening_relays(device_store) do
    case DeviceStore.list(device_store) do
      {:ok, devices} ->
        {:ok,
         devices |> Enum.map(& &1.relay_list_rev) |> Relays.acknowledged() |> Relays.to_wire()}

      {:error, reason} ->
        Logger.error("enrollment: the device list could not be read: #{inspect(reason)}")
        {:error, "Fermix could not read its paired devices, so it opened no code."}
    end
  end

  defp gateway_public_key(home) do
    case Identity.ensure(root: home) do
      {:ok, identity} ->
        {:ok, identity.gateway_public_key}

      {:error, reason} ->
        Logger.error("enrollment: the gateway identity could not be loaded: #{inspect(reason)}")
        {:error, "Fermix could not load its gateway identity, so it opened no code."}
    end
  end

  defp host_name do
    case :inet.gethostname() do
      {:ok, name} ->
        {:ok, String.slice(to_string(name), 0, 64)}

      {:error, reason} ->
        Logger.error("enrollment: this host's name could not be read: #{inspect(reason)}")
        {:error, "Fermix could not read this computer's name, so it opened no code."}
    end
  end

  # -- the window on disk -----------------------------------------------------

  # A window past its expiry has its secret taken off the disk; one not yet
  # past it is looked at again when it expires.
  defp expire_or_arm(%{window: nil} = state), do: state

  defp expire_or_arm(%{window: window} = state) do
    now = state.clock.()

    if DateTime.compare(now, window.expires_at) == :lt,
      do: arm(state, window, now),
      else: forget_secret(state, now)
  end

  defp arm(state, window, now) do
    _timer =
      state.schedule.(
        {:expire, window.expires_at},
        DateTime.diff(window.expires_at, now, :millisecond)
      )

    state
  end

  # The next start of the engine tries again; the log says why it is still
  # there meanwhile.
  defp forget_secret(state, now) do
    case write(state.home, state.window, now) do
      :ok ->
        state

      {:error, reason} ->
        Logger.error(
          "enrollment: the expired window's secret is still in #{path(state.home)}: " <>
            inspect(reason)
        )

        state
    end
  end

  # Written before it is answered, so the answer always describes what a
  # restart will find. A write that fails is refused by name rather than
  # answered as if it held.
  defp keep(state, window, reply) do
    case write(state.home, window, state.clock.()) do
      :ok ->
        :ok = state.status_changed.()
        {:reply, reply, %{state | window: window}}

      {:error, reason} ->
        Logger.error("enrollment: the window could not be kept: #{inspect(reason)}")
        {:reply, {:error, {:unavailable, "Fermix could not keep the enrollment window."}}, state}
    end
  end

  defp write(home, window, now) do
    file = path(home)
    tmp = file <> ".tmp"

    json =
      Jason.encode!(%{
        "v" => 1,
        "kind" => Atom.to_string(window.kind),
        "withdrawn" => window.withdrawn?,
        "secret" => kept_secret(window, now),
        "expires_at" => DateTime.to_iso8601(window.expires_at),
        "used" => window.used?,
        "name" => window.name,
        "used_by" => window.used_by && Base.encode64(window.used_by),
        "candidate_id" => window.candidate_id
      })

    with :ok <- File.mkdir_p(Path.dirname(file)),
         :ok <- File.write(tmp, json),
         :ok <- File.chmod(tmp, @file_mode),
         :ok <- File.rename(tmp, file) do
      :ok
    else
      {:error, _reason} = error ->
        _ = File.rm(tmp)
        error
    end
  end

  # The secret stays on disk only while the window can still admit a new
  # candidate: not once its candidate is recorded, nor once it expired.
  defp kept_secret(%{secret: nil}, _now), do: nil
  defp kept_secret(%{candidate_id: id}, _now) when is_binary(id), do: nil

  defp kept_secret(%{secret: secret, expires_at: at}, now) do
    if DateTime.compare(now, at) == :lt, do: Base.encode64(secret), else: nil
  end

  # A window file that is absent is no window; one that cannot be read is
  # logged and treated as none: a code it named can no longer enroll, and the
  # owner opens another.
  defp load(home) do
    with {:ok, json} <- File.read(path(home)),
         {:ok, map} <- Jason.decode(json),
         {:ok, window} <- decode(map) do
      window
    else
      {:error, :enoent} ->
        nil

      other ->
        Logger.error("enrollment: #{path(home)} could not be read: #{inspect(other)}")
        nil
    end
  end

  defp decode(
         %{
           "v" => 1,
           "kind" => kind,
           "withdrawn" => withdrawn?,
           "secret" => secret,
           "expires_at" => at,
           "used" => used?
         } = map
       )
       when kind in ["manual", "provisioned"] and is_boolean(withdrawn?) and is_boolean(used?) do
    with {:ok, secret} <- optional_key(secret),
         {:ok, expires_at, 0} <- DateTime.from_iso8601(at),
         {:ok, used_by} <- optional_key(map["used_by"]) do
      {:ok,
       %{
         kind: String.to_existing_atom(kind),
         withdrawn?: withdrawn?,
         secret: secret,
         expires_at: expires_at,
         used?: used?,
         name: map["name"],
         used_by: used_by,
         candidate_id: map["candidate_id"]
       }}
    else
      _invalid -> {:error, :invalid_window}
    end
  end

  defp decode(_other), do: {:error, :invalid_window}

  defp optional_key(nil), do: {:ok, nil}

  defp optional_key(text) when is_binary(text) do
    case Base.decode64(text) do
      {:ok, <<_::256>> = key} -> {:ok, key}
      _invalid -> :error
    end
  end

  defp optional_key(_other), do: :error

  defp window_state(%{used?: true}, _now), do: :used

  defp window_state(%{expires_at: at}, now),
    do: if(DateTime.compare(now, at) == :lt, do: :open, else: :expired)

  defp attrs(request, noise_pk) do
    host = request["host"]
    candidate = request["candidate"]

    %{
      name: host["name"],
      os: host["os"],
      arch: host["arch"],
      version: host["version"],
      node_id: candidate["node_id"],
      relays: candidate["relays"],
      noise_pk: noise_pk,
      recipient: Base.decode64!(candidate["recipient"]),
      snapshots: request["snapshots"]
    }
  end
end
