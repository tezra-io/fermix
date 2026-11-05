defmodule FermixChannels.Home.Enrollment do
  @moduledoc """
  The primary's enrollment window (M75 §7.1): the one place a candidate
  primary is admitted, and the one writer of `<home>/mobile/candidates.json`
  (`FermixCore.Home.Candidates`).

  `open/2` (through `FermixChannels.Home.Link`) opens one window, replacing
  an open one, and answers its code (`FermixCore.Home.EnrollmentCode`): a
  fresh 32-byte secret, this primary's gateway key, its iroh endpoint id, the
  relays its endpoint listens on (the ones every paired device acknowledged),
  the host's name and the expiry. The window lives thirty minutes: the code
  a person copies onto a server of their own (Always On's `own_server`,
  `home.act`). `withdraw/1` releases it when the owner cancels its code (one
  that recorded no candidate yet ends now: an open one, or one a server used
  but did not finish enrolling through). `forget/2` drops a held candidate
  the owner forgot (Always On's Forget this server). A window a linked
  desktop opens to take the home back
  (Always On's move back) names that desktop (`returning`, its device id),
  and the candidate that enrolls through it carries it
  (`FermixCore.Home.Candidates`): the server knows a move goes back by that
  fact. The code is answered once and never logged; the window (its secret,
  expiry, the desktop it was opened for, and who used it) is kept in
  `<home>/mobile/enrollment.json` (`0600`, device-local), so an engine
  restart between opening a code and the server's check-in loses nothing.
  The window records which candidate used it: the code is single use.

  A stream with the enrollment prelude (`FXM1 0x03`) reaches the window
  through `FermixChannels.Home.EnrollmentResponder` while a window is held
  (`window?/1`). The first session that proves the secret burns it
  (`take/2`): the window is then `used`, and a later session with the same
  secret is answered `enrollment_used`, except the candidate that used it
  (the same Noise key), whose `enroll_accepted` was lost: while the window
  lasts it is answered again with the candidate id it was given, and after
  that `enrollment_expired` like anyone. One after the thirty minutes is
  answered `enrollment_expired`, and a window used by a server that was never
  recorded through it reads `expired` once they are over, as an unused one
  does. The window is remembered until another
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

  Every change it keeps (a window opened, used, given its candidate or
  withdrawn, a candidate forgotten) and its expiry tell the Always On watch
  (`FermixCore.Home.StatusWatch`, `:enrollment`): the summary an app draws
  reads the window (companion protocol 6).

  Primary only: `FermixCore.Home.Role` leaves it out of a device and a
  candidate. Test seams: `:home`, `:helper`, `:device_store`, `:clock` (a
  0-arity `DateTime`), `:schedule` (a 2-arity `Process.send_after/3`
  stand-in for the expiry),
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

  # How long a window stays open, in seconds.
  @window_s 1_800
  @file_name "enrollment.json"
  @file_mode 0o600

  @type window_view :: %{
          state: :open | :used | :expired,
          expires_at: DateTime.t(),
          candidate_id: String.t() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc """
  Opens a window, replacing any, and answers its code and expiry; or
  `{:error, {:unavailable, sentence}}` when this primary cannot be reached
  over the rail. `returning` names the linked desktop the window is opened
  for, to take the home back (nil for any other).
  """
  @spec open(GenServer.server(), String.t() | nil) ::
          {:ok, %{code: String.t(), expires_at: DateTime.t()}}
          | {:error, {:unavailable, String.t()}}
  def open(server \\ __MODULE__, returning \\ nil)
      when is_nil(returning) or is_binary(returning),
      do: GenServer.call(server, {:open, returning}, 15_000)

  @doc """
  Releases the window when the owner cancels its code: one that recorded no
  candidate yet (open, or used by a server that did not finish enrolling)
  ends now (its secret leaves the disk), one whose candidate is recorded
  stays as the record of who used it; one already released, or none, is left
  as it is. Answers `:ok`, or `{:error, {:unavailable, sentence}}` when the
  window could not be kept.
  """
  @spec withdraw(GenServer.server()) :: :ok | {:error, {:unavailable, String.t()}}
  def withdraw(server \\ __MODULE__), do: GenServer.call(server, :withdraw)

  @doc """
  Drops the held candidate `candidate_id` the owner forgot, in the one
  writer of the list, and tells the Always On watch; the window keeps who
  used it. One no longer held is forgotten already. Answers `:ok`, or
  `{:error, {:unavailable, sentence}}` when the list could not be written.
  """
  @spec forget(GenServer.server(), String.t()) :: :ok | {:error, {:unavailable, String.t()}}
  def forget(server \\ __MODULE__, candidate_id) when is_binary(candidate_id),
    do: GenServer.call(server, {:forget, candidate_id})

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

    state = %{
      home: home,
      helper: Keyword.get(opts, :helper, Helper),
      device_store: Keyword.get(opts, :device_store, DeviceStore),
      clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
      schedule: Keyword.get(opts, :schedule, &Process.send_after(self(), &1, &2)),
      host_name: Keyword.get(opts, :host_name, &host_name/0),
      identity: Keyword.get(opts, :identity, &gateway_public_key/1),
      status_changed:
        Keyword.get(opts, :status_changed, fn -> StatusWatch.changed(:enrollment) end),
      window: load(home)
    }

    {:ok, expire_or_arm(state)}
  end

  @impl true
  def handle_call({:open, returning}, _from, state) do
    case code_facts(state) do
      {:ok, facts} -> open_window(returning, facts, state)
      {:error, sentence} -> {:reply, {:error, {:unavailable, sentence}}, state}
    end
  end

  def handle_call(:withdraw, _from, %{window: %{withdrawn?: false}} = state),
    do: withdraw_window(state)

  def handle_call(:withdraw, _from, state), do: {:reply, :ok, state}

  def handle_call({:forget, candidate_id}, _from, state) do
    case Candidates.remove(state.home, candidate_id, state.clock.()) do
      :ok ->
        Logger.info("enrollment: candidate #{candidate_id} forgotten")
        :ok = state.status_changed.()
        {:reply, :ok, state}

      {:error, reason} ->
        Logger.error("enrollment: the candidate could not be forgotten: #{inspect(reason)}")
        {:reply, {:error, {:unavailable, "Fermix could not forget the server."}}, state}
    end
  end

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
    attrs = Map.put(attrs(request, noise_pk), :returning, state.window.returning)

    case Candidates.add(state.home, attrs, state.clock.()) do
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
      candidate_id: window.candidate_id
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

  defp open_window(returning, facts, state) do
    now = state.clock.()
    expires_at = now |> DateTime.add(@window_s, :second) |> DateTime.truncate(:second)
    secret = :crypto.strong_rand_bytes(32)

    case EnrollmentCode.encode(Map.merge(facts, %{secret: secret, expires_at: expires_at})) do
      {:ok, code} ->
        window = %{
          withdrawn?: false,
          secret: secret,
          expires_at: expires_at,
          used?: false,
          name: facts.name,
          used_by: nil,
          candidate_id: nil,
          returning: returning
        }

        Logger.info("enrollment: a window is open until #{DateTime.to_iso8601(expires_at)}")
        arm(state, window, now)
        keep(state, window, {:ok, %{code: code, expires_at: expires_at}})

      {:error, reason} ->
        Logger.error("enrollment: no code could be made: #{inspect(reason)}")
        {:reply, {:error, {:unavailable, "Fermix could not make an enrollment code."}}, state}
    end
  end

  # Released: a window that recorded no candidate ends now (open, or used by
  # a server that never finished enrolling) and the write takes its secret off
  # the disk; one whose candidate is recorded keeps its expiry and who used it.
  defp withdraw_window(%{window: window} = state) do
    now = DateTime.truncate(state.clock.(), :second)
    Logger.info("enrollment: the window was withdrawn")

    expires_at =
      if window.candidate_id == nil and window_state(window, now) != :expired,
        do: now,
        else: window.expires_at

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

  # Version 2: a window with no kind. A version 1 file, which named one, is
  # no window this version reads (`load/1`).
  defp write(home, window, now) do
    file = path(home)
    tmp = file <> ".tmp"

    json =
      Jason.encode!(%{
        "v" => 2,
        "withdrawn" => window.withdrawn?,
        "secret" => kept_secret(window, now),
        "expires_at" => DateTime.to_iso8601(window.expires_at),
        "used" => window.used?,
        "name" => window.name,
        "used_by" => window.used_by && Base.encode64(window.used_by),
        "candidate_id" => window.candidate_id,
        "returning" => window.returning
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

  # A window file that is absent is no window; one that cannot be read, or
  # one of an earlier version (a version 1 file names the window's kind), is
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
           "v" => 2,
           "withdrawn" => withdrawn?,
           "secret" => secret,
           "expires_at" => at,
           "used" => used?
         } = map
       )
       when is_boolean(withdrawn?) and is_boolean(used?) do
    with {:ok, secret} <- optional_key(secret),
         {:ok, expires_at, 0} <- DateTime.from_iso8601(at),
         {:ok, used_by} <- optional_key(map["used_by"]),
         true <- is_nil(map["returning"]) or is_binary(map["returning"]) do
      {:ok,
       %{
         withdrawn?: withdrawn?,
         secret: secret,
         expires_at: expires_at,
         used?: used?,
         name: map["name"],
         used_by: used_by,
         candidate_id: map["candidate_id"],
         returning: map["returning"]
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

  # A used window stands as the record of its candidate; one whose server was
  # never recorded through it ends with its half hour, like an unused one.
  defp window_state(%{used?: true, candidate_id: id}, _now) when is_binary(id), do: :used

  defp window_state(%{used?: used?, expires_at: at}, now) do
    cond do
      DateTime.compare(now, at) != :lt -> :expired
      used? -> :used
      true -> :open
    end
  end

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
      addrs: Map.get(candidate, "addrs", []),
      noise_pk: noise_pk,
      recipient: Base.decode64!(candidate["recipient"]),
      snapshots: request["snapshots"]
    }
  end
end
