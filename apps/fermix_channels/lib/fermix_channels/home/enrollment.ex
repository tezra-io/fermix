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

  **A computer's join** (M97 §3.1, §7.5). A window opened with the purpose
  `:computer` (`open/3`) takes a computer that joins the home instead of a
  candidate: its code is version 2 (`EnrollmentCode`), and only one window
  is held, so opening a code of the other purpose while one is open (open,
  or a computer waiting for the owner) is refused by name and the open
  window stays; one of the same purpose replaces it, as before, and a
  computer waiting on the one replaced is told `cancelled`. The joining
  computer's `join_request` burns the window as an enrollment does and
  waits (`join/5`): the responder holds the session with the six digits it
  derived from the handshake under the computer label (`Mobile.Noise.sas/2`)
  until the owner approves with those digits (`approve/2`), denies
  (`deny/1`), cancels the code, the session ends (`device_disconnected`) or
  the window's half hour runs out (`timeout`). Approval writes the
  computer's row (`kind: :desktop`, its `platform`, `backups: false`, a name
  no other row holds, compared without case, suffixed " 2" and on where it
  must) and answers the responder `{:join_approved, payload}`; anything else
  answers `{:join_denied, reason}` and writes nothing. Digits that are not
  the computer's deny it too. The code is spent either way, and the window
  keeps how it ended (`approved` with the computer's device id, or
  `denied`): an answer that was lost reaches the same computer again (its
  Noise key) while the window lasts.

  A code needs the rail ready: one asleep (no phone paired yet) or starting
  is woken and waited for, up to 10 s (`Iroh.Helper.await_ready/2`), so the
  first code after a start is no refusal; a rail still starting then is
  refused in its own sentence.

  Primary only: `FermixCore.Home.Role` leaves it out of a device and a
  candidate. Test seams: `:home`, `:helper`, `:rail_wait_ms` (that bound),
  `:device_store`, `:clock` (a
  0-arity `DateTime`), `:schedule` (a 2-arity `Process.send_after/3`
  stand-in for the expiry),
  `:host_name`, `:identity` (a 1-arity loader answering the gateway's public
  key for a home), `:status_changed` (a 0-arity call in place of telling the
  Always On watch), `:hints` (0-arity, this endpoint's direct address hints,
  as `Iroh.Helper.hints/1`).
  """

  use GenServer

  require Logger

  alias FermixChannels.Mobile.DeviceStore
  alias FermixChannels.Mobile.Identity
  alias FermixChannels.Mobile.Iroh.Helper
  alias FermixChannels.Mobile.Iroh.Relays
  alias FermixCore.Home.Candidates
  alias FermixCore.Home.ComputerName
  alias FermixCore.Home.DesktopLink
  alias FermixCore.Home.EnrollmentCode
  alias FermixCore.Home.Epoch
  alias FermixCore.Home.StatusWatch
  alias FermixCore.Setup.ConfigStore

  # How long a window stays open, in seconds.
  @window_s 1_800
  # How long opening a code waits for the rail to start; it starts in a
  # second or two, and gives up on its own after its hello and ready bounds.
  @rail_wait_ms 10_000
  @rail_slow_sentence "Remote reach did not start within #{div(@rail_wait_ms, 1_000)} seconds, " <>
                        "so Fermix opened no code. Open it again in a minute; Doctor says why " <>
                        "if remote reach still does not start."
  @file_name "enrollment.json"
  @file_mode 0o600
  @purposes [:candidate, :computer]
  # How a computer's join ends without approval (`join_denied`'s `reason`).
  @denials ~w(denied timeout cancelled device_disconnected)
  # The rows a computer's name is kept apart from: every one the store holds.
  @max_name_suffix 99
  @other_open_sentences %{
    candidate:
      "A code for a new computer is open. Use it, or let it close in half an hour, " <>
        "before you open the one for your own server.",
    computer: "A code for your own server is open. Use it or cancel it before you add a computer."
  }

  @type purpose :: :candidate | :computer
  @type window_view :: %{
          state: :open | :used | :expired | :awaiting_approval | :approved | :denied,
          purpose: purpose(),
          expires_at: DateTime.t(),
          candidate_id: String.t() | nil,
          joiner: %{name: String.t(), platform: String.t(), sas: String.t()} | nil,
          joined: %{device_id: String.t(), name: String.t()} | nil
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
      do: open(server, returning, :candidate)

  @doc """
  `open/2` for `purpose`: `:candidate` (a server of the owner's own, or a
  move back), or `:computer` (a computer that joins the home, which no move
  back names). Refused by name while a window of the other purpose is open.
  """
  @spec open(GenServer.server(), String.t() | nil, purpose()) ::
          {:ok, %{code: String.t(), expires_at: DateTime.t()}}
          | {:error, {:unavailable, String.t()}}
  def open(server, returning, purpose)
      when (is_nil(returning) or is_binary(returning)) and purpose in @purposes and
             (purpose == :candidate or is_nil(returning)),
      do: GenServer.call(server, {:open, returning, purpose}, 15_000)

  @doc "The held window's purpose, or `:none`; `:none` too when no window process runs."
  @spec purpose(GenServer.server()) :: purpose() | :none
  def purpose(server \\ __MODULE__) do
    if GenServer.whereis(server), do: GenServer.call(server, :purpose), else: :none
  catch
    :exit, {reason, _call} when reason in [:noproc, :normal, :shutdown] -> :none
  end

  @doc """
  A computer that proved the secret with the Noise key `noise_pk` asks to
  join (`join_request`), showing `sas`; `responder` is told how it ends
  (`{:join_approved, payload}` or `{:join_denied, reason}`) and watched, so
  a session that ends while it waits denies it. Answers `{:ok,
  :awaiting_approval}`, `{:ok, {:approved, payload}}` to the computer an
  approval was already given (its answer was lost), or why not: `:purpose`
  (a candidate's window), `:used`, `:expired`, `{:denied, reason}`.
  """
  @spec join(GenServer.server(), map(), <<_::256>>, String.t(), pid()) ::
          {:ok, :awaiting_approval | {:approved, map()}}
          | {:error, :purpose | :used | :expired | :none | {:denied, String.t()}}
  def join(server \\ __MODULE__, request, <<_::256>> = noise_pk, sas, responder)
      when is_map(request) and is_binary(sas) and is_pid(responder),
      do: GenServer.call(server, {:join, request, noise_pk, sas, responder})

  @doc """
  The owner approves the waiting computer with the six digits `sas` it shows:
  its row is written and it is told. Digits that are not the computer's deny
  it (`:sas_mismatch`), and the code is spent. `{:error, :none}` when no
  computer waits.
  """
  @spec approve(GenServer.server(), String.t()) ::
          {:ok, %{device_id: String.t(), name: String.t()}}
          | {:error, :none | :sas_mismatch | {:unavailable, String.t()}}
  def approve(server \\ __MODULE__, sas) when is_binary(sas),
    do: GenServer.call(server, {:approve, sas})

  @doc "The owner denies the waiting computer; none waiting is nothing to deny."
  @spec deny(GenServer.server()) :: :ok | {:error, {:unavailable, String.t()}}
  def deny(server \\ __MODULE__), do: GenServer.call(server, :deny)

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
      rail_wait_ms: Keyword.get(opts, :rail_wait_ms, @rail_wait_ms),
      device_store: Keyword.get(opts, :device_store, DeviceStore),
      clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
      schedule: Keyword.get(opts, :schedule, &Process.send_after(self(), &1, &2)),
      host_name: Keyword.get(opts, :host_name, &host_name/0),
      identity: Keyword.get(opts, :identity, &gateway_public_key/1),
      status_changed:
        Keyword.get(opts, :status_changed, fn -> StatusWatch.changed(:enrollment) end),
      window: load(home)
    }

    helper = state.helper
    state = Map.put(state, :hints, Keyword.get(opts, :hints, fn -> Helper.hints(helper) end))

    {:ok, expire_or_arm(state)}
  end

  @impl true
  def handle_call({:open, returning, purpose}, _from, state) do
    with :ok <- none_other_open(state, purpose),
         {:ok, facts} <- code_facts(state) do
      open_window(returning, purpose, facts, cancel_joiner(state))
    else
      {:error, sentence} -> {:reply, {:error, {:unavailable, sentence}}, state}
    end
  end

  def handle_call(:purpose, _from, %{window: nil} = state), do: {:reply, :none, state}
  def handle_call(:purpose, _from, state), do: {:reply, state.window.purpose, state}

  def handle_call({:join, request, noise_pk, sas, responder}, _from, state),
    do: join_window(request, noise_pk, sas, responder, state)

  def handle_call({:approve, sas}, _from, state), do: approve_joiner(sas, state)
  def handle_call(:deny, _from, state), do: deny_joiner("denied", :ok, state)

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
      other -> {:reply, {:error, spent(other)}, state}
    end
  end

  def handle_call(
        {:enroll, _request, _noise_pk},
        _from,
        %{window: %{purpose: :computer}} = state
      ),
      do: {:reply, {:error, :purpose}, state}

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
      purpose: window.purpose,
      expires_at: window.expires_at,
      candidate_id: window.candidate_id,
      joiner: joiner_view(window.joiner),
      joined: window.joined
    }

    {:reply, view, state}
  end

  @impl true
  def handle_info({:expire, expires_at}, %{window: %{expires_at: expires_at}} = state) do
    {_reply, state} = deny_or_none("timeout", state)
    state = expire_or_arm(state)
    :ok = state.status_changed.()
    {:noreply, state}
  end

  # The session of the computer that waits ended: it is denied, and the
  # code is spent.
  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{window: %{joiner: %{monitor: ref}}} = state
      ) do
    {_reply, state} = deny_or_none("device_disconnected", state)
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  # A timer of a window another replaced.
  def handle_info({:expire, _expires_at}, state), do: {:noreply, state}

  # -- opening ----------------------------------------------------------------

  defp open_window(returning, purpose, facts, state) do
    now = state.clock.()
    expires_at = now |> DateTime.add(@window_s, :second) |> DateTime.truncate(:second)
    secret = :crypto.strong_rand_bytes(32)
    code_facts = Map.merge(facts, %{secret: secret, expires_at: expires_at, purpose: purpose})

    case EnrollmentCode.encode(code_facts) do
      {:ok, code} ->
        window = %{
          withdrawn?: false,
          purpose: purpose,
          secret: secret,
          expires_at: expires_at,
          used?: false,
          name: facts.name,
          used_by: nil,
          candidate_id: nil,
          returning: returning,
          joiner: nil,
          joined: nil,
          denied: nil
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
  # A computer waiting on it is told `cancelled`.
  defp withdraw_window(state) do
    %{window: window} = state = cancel_joiner(state)
    now = DateTime.truncate(state.clock.(), :second)
    Logger.info("enrollment: the window was withdrawn")

    expires_at =
      if window.candidate_id == nil and window.joined == nil and
           window_state(window, now) not in [:expired, :denied],
         do: now,
         else: window.expires_at

    case keep(state, %{window | expires_at: expires_at, withdrawn?: true}, :ok) do
      {:reply, :ok, kept} -> {:reply, :ok, %{kept | window: %{kept.window | secret: nil}}}
      refused -> refused
    end
  end

  # One window at a time: a code of the other purpose waits until the open
  # one is used, closes or is cancelled, and is refused by name meanwhile.
  defp none_other_open(%{window: %{purpose: held, withdrawn?: false} = window} = state, purpose)
       when held != purpose do
    if window_state(window, state.clock.()) in [:open, :awaiting_approval],
      do: {:error, Map.fetch!(@other_open_sentences, purpose)},
      else: :ok
  end

  defp none_other_open(_state, _purpose), do: :ok

  # -- a computer's join ------------------------------------------------------

  defp join_window(_request, _noise_pk, _sas, _responder, %{window: nil} = state),
    do: {:reply, {:error, :none}, state}

  defp join_window(
         _request,
         _noise_pk,
         _sas,
         _responder,
         %{window: %{purpose: :candidate}} = state
       ),
       do: {:reply, {:error, :purpose}, state}

  defp join_window(request, noise_pk, sas, responder, %{window: window} = state) do
    cond do
      window.used_by != noise_pk -> {:reply, {:error, :used}, state}
      window.joined != nil -> {:reply, approved_again(window.joined, state), state}
      is_binary(window.denied) -> {:reply, {:error, {:denied, window.denied}}, state}
      expired?(window, state) -> {:reply, {:error, :expired}, state}
      true -> await_owner(request, noise_pk, sas, responder, state)
    end
  end

  # The computer waits, in memory alone: a session that ends while it waits
  # (an engine restart among them) denies it.
  defp await_owner(request, noise_pk, sas, responder, %{window: window} = state) do
    host = request["host"]
    _forgot = forget_joiner(window.joiner)

    joiner = %{
      name: host["name"],
      os: host["os"],
      arch: host["arch"],
      version: host["version"],
      platform: request["platform"],
      sas: sas,
      noise_pk: noise_pk,
      responder: responder,
      monitor: Process.monitor(responder)
    }

    Logger.info("enrollment: a computer named #{joiner.name} waits for the owner")
    :ok = state.status_changed.()
    {:reply, {:ok, :awaiting_approval}, %{state | window: %{window | joiner: joiner}}}
  end

  defp approve_joiner(
         sas,
         %{window: %{purpose: :computer, joiner: %{sas: sas} = joiner}} = state
       ),
       do: add_computer(joiner, state)

  defp approve_joiner(_sas, %{window: %{purpose: :computer, joiner: %{}}} = state) do
    Logger.warning("enrollment: the owner's digits are not the computer's; it is denied")
    {_denied, state} = deny_or_none("denied", state)
    {:reply, {:error, :sas_mismatch}, state}
  end

  defp approve_joiner(_sas, state), do: {:reply, {:error, :none}, state}

  # The payload first, so a row is written only for a computer that can be
  # told where its server is.
  defp add_computer(joiner, state) do
    device_id = uuid()

    with {:ok, rows} <- DeviceStore.list(state.device_store),
         name = unique_name(joiner.name, rows),
         {:ok, payload} <- approved_payload(device_id, name, state),
         {:ok, _row} <-
           DeviceStore.add(state.device_store, computer_row(joiner, device_id, name, state)) do
      send(joiner.responder, {:join_approved, payload})
      _forgot = forget_joiner(joiner)
      Logger.info("enrollment: the computer #{device_id} (#{name}) joined")
      joined = %{device_id: device_id, name: name}
      keep(state, %{state.window | joiner: nil, joined: joined}, {:ok, joined})
    else
      {:error, reason} ->
        Logger.error("enrollment: the computer could not be added: #{inspect(reason)}")

        {:reply, {:error, {:unavailable, "Fermix could not add the computer; its log says why."}},
         state}
    end
  end

  # A computer that joins keeps no backup copies until its owner chooses it
  # (M97 D7), and says its system.
  defp computer_row(joiner, device_id, name, state) do
    %{
      device_id: device_id,
      name: name,
      model: "#{system(joiner.platform)} computer",
      noise_pk: joiner.noise_pk,
      created_at: DateTime.truncate(state.clock.(), :second),
      kind: :desktop,
      platform: joiner.platform,
      backups: false
    }
  end

  defp system("macos"), do: "macOS"
  defp system("linux"), do: "Linux"

  # The name the computer gave, unless another row holds it, compared without
  # case: then the first of " 2", " 3" and on that none holds.
  defp unique_name(name, rows) do
    taken = MapSet.new(rows, &String.downcase(&1.name))

    [name | Enum.map(2..@max_name_suffix, &"#{name} #{&1}")]
    |> Enum.find(name, &(not MapSet.member?(taken, String.downcase(&1))))
  end

  # Where the computer reaches its server: this primary's route now, its
  # epoch, and the direct address hints its endpoint listens on.
  defp approved_payload(device_id, name, state) do
    with {:ok, facts} <- code_facts(state),
         {:ok, epoch} <- primary_epoch(state.home) do
      {:ok,
       %{
         "device_id" => device_id,
         "name" => name,
         "primary_epoch" => epoch,
         "primary" => %{
           "name" => facts.name,
           "node_id" => facts.node_id,
           "relays" => facts.relays,
           "relays_rev" => facts.relays_rev,
           "addrs" => state.hints.() |> Enum.filter(&DesktopLink.hint?/1) |> Enum.take(8)
         }
       }}
    end
  end

  defp approved_again(%{device_id: device_id, name: name}, state) do
    case approved_payload(device_id, name, state) do
      {:ok, payload} -> {:ok, {:approved, payload}}
      {:error, _reason} = error -> error
    end
  end

  defp primary_epoch(home) do
    case Epoch.read(home) do
      {:ok, epoch} -> {:ok, epoch}
      :absent -> {:error, :epoch_absent}
      {:error, _reason} = error -> error
    end
  end

  # The owner's denial (`deny/1`), and every other ending of a wait.
  defp deny_joiner(reason, reply, state) do
    {_denied, state} = deny_or_none(reason, state)
    {:reply, reply, state}
  end

  # The computer that waits is told `reason` and nothing of it is written; the
  # window keeps the ending, and the code is spent.
  defp deny_or_none(reason, %{window: %{joiner: %{} = joiner} = window} = state)
       when reason in @denials do
    send(joiner.responder, {:join_denied, reason})
    _forgot = forget_joiner(joiner)
    Logger.info("enrollment: the computer #{joiner.name} was not added (#{reason})")
    {:denied, kept(state, %{window | joiner: nil, denied: reason})}
  end

  defp deny_or_none(_reason, state), do: {:none, state}

  defp cancel_joiner(state), do: elem(deny_or_none("cancelled", state), 1)

  defp forget_joiner(%{monitor: monitor}), do: Process.demonitor(monitor, [:flush])
  defp forget_joiner(nil), do: true

  defp joiner_view(nil), do: nil
  defp joiner_view(joiner), do: Map.take(joiner, [:name, :platform, :sas])

  defp expired?(window, state), do: DateTime.compare(state.clock.(), window.expires_at) != :lt

  # A window spent any way is used to a session that is not the one it took.
  defp spent(:expired), do: :expired
  defp spent(_spent), do: :used

  defp uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    c = Bitwise.bor(Bitwise.band(c, 0x0FFF), 0x4000)
    d = Bitwise.bor(Bitwise.band(d, 0x3FFF), 0x8000)

    [<<a::32>>, <<b::16>>, <<c::16>>, <<d::16>>, <<e::48>>]
    |> Enum.map_join("-", &Base.encode16(&1, case: :lower))
  end

  defp code_facts(state) do
    with {:ok, node_id} <- endpoint(state.helper, state.rail_wait_ms),
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
  # One asleep or starting is woken and waited for.
  defp endpoint(helper, wait_ms) do
    case Helper.await_ready(helper, wait_ms) do
      %{state: :ready, endpoint_id: id} ->
        {:ok, id}

      :timeout ->
        Logger.warning("enrollment: no code: remote reach did not start within #{wait_ms} ms")

        {:error, @rail_slow_sentence}

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

  # On a Mac its computer name, elsewhere its hostname (`Home.ComputerName`).
  defp host_name do
    case ComputerName.read() do
      {:ok, name} ->
        {:ok, name}

      {:error, reason} ->
        Logger.error("enrollment: this host's name could not be read: #{reason}")
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

  # An ending already told is kept in memory whatever the disk says; a write
  # that fails is said in the log, and the next start reads the window as it
  # was written last.
  defp kept(state, window) do
    case write(state.home, window, state.clock.()) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("enrollment: the window could not be kept: #{inspect(reason)}")
    end

    :ok = state.status_changed.()
    %{state | window: window}
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
        "purpose" => Atom.to_string(window.purpose),
        "withdrawn" => window.withdrawn?,
        "secret" => kept_secret(window, now),
        "expires_at" => DateTime.to_iso8601(window.expires_at),
        "used" => window.used?,
        "name" => window.name,
        "used_by" => window.used_by && Base.encode64(window.used_by),
        "candidate_id" => window.candidate_id,
        "returning" => window.returning,
        "joined" => window.joined,
        "denied" => window.denied
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
  defp kept_secret(%{joined: %{}}, _now), do: nil
  defp kept_secret(%{denied: reason}, _now) when is_binary(reason), do: nil

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
         true <- is_nil(map["returning"]) or is_binary(map["returning"]),
         {:ok, purpose} <- stored_purpose(map["purpose"]),
         {:ok, joined} <- stored_joined(map["joined"]),
         true <- is_nil(map["denied"]) or map["denied"] in @denials do
      {:ok,
       %{
         withdrawn?: withdrawn?,
         purpose: purpose,
         secret: secret,
         expires_at: expires_at,
         used?: used?,
         name: map["name"],
         used_by: used_by,
         candidate_id: map["candidate_id"],
         returning: map["returning"],
         joiner: nil,
         joined: joined,
         denied: map["denied"]
       }}
    else
      _invalid -> {:error, :invalid_window}
    end
  end

  defp decode(_other), do: {:error, :invalid_window}

  # A window written before a computer could join is a candidate's.
  defp stored_purpose(nil), do: {:ok, :candidate}
  defp stored_purpose("candidate"), do: {:ok, :candidate}
  defp stored_purpose("computer"), do: {:ok, :computer}
  defp stored_purpose(_other), do: :error

  defp stored_joined(nil), do: {:ok, nil}

  defp stored_joined(%{"device_id" => id, "name" => name}) when is_binary(id) and is_binary(name),
    do: {:ok, %{device_id: id, name: name}}

  defp stored_joined(_other), do: :error

  defp optional_key(nil), do: {:ok, nil}

  defp optional_key(text) when is_binary(text) do
    case Base.decode64(text) do
      {:ok, <<_::256>> = key} -> {:ok, key}
      _invalid -> :error
    end
  end

  defp optional_key(_other), do: :error

  # A used window stands as the record of its candidate, or of how a
  # computer's join ended; one whose server was never recorded through it
  # ends with its half hour, like an unused one, and so does a computer's
  # wait for the owner.
  defp window_state(%{used?: true, candidate_id: id}, _now) when is_binary(id), do: :used
  defp window_state(%{joined: %{}}, _now), do: :approved
  defp window_state(%{denied: reason}, _now) when is_binary(reason), do: :denied

  defp window_state(%{used?: used?, expires_at: at} = window, now) do
    cond do
      DateTime.compare(now, at) != :lt -> :expired
      window.joiner != nil -> :awaiting_approval
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
