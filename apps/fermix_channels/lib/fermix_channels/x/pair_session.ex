defmodule FermixChannels.X.PairSession do
  @moduledoc """
  The one pairing session with Fermix Connect (`priv/connect/PROTOCOL.md` §2),
  in the shape of the engine's own provider sign-ins (`Auth.OAuthFlow`): an
  OAuth 2.0 authorization request with PKCE whose redirect is a listener on
  `127.0.0.1`, with Connect as the authorization server. It runs whenever the
  channels application does, because pairing works while the channel is off.

  `start/2` refuses while this Fermix holds a pairing record (`:already_paired`)
  or a session is open (`:pairing_active`), creates the instance key on first
  use, opens an enrollment at the origin and binds the loopback on a port the
  OS picks. It answers once the authorization link exists: `confirm_url` is
  Connect's link with the authorization request appended (§2.1), answered once
  and never kept. The pane opens it; the daemon never opens a browser. The
  session then moves:

    * `awaiting_browser`: the owner signs in with X and approves or denies in
      the browser, and Connect sends the browser back to the loopback. A
      request with another `state` or `Host` is answered 400 and changes
      nothing. On a machine whose browser is elsewhere that redirect fails to
      load, and `paste/3` hands the address the browser ended on to the same
      wait, which reads it by the same rules;
    * `approved`: the callback carried a code, Connect accepted the key proof
      made with it and this attempt's verifier (§2.2), and the pairing record
      is written; the view names the X `handle` Connect paired;
    * `denied`: the owner denied in the browser; nothing is written;
    * `expired`: the session's ten minutes, which are the enrollment's, ran
      out;
    * `cancelled`: `cancel/2` closed it, and the listener with it;
    * `failed`: with `failure.reason` one of `connect_unreachable`,
      `connect_refused`, `proof_rejected`, `already_paired`,
      `unsupported_protocol`, `key_unavailable`, `record_unwritable` and
      `loopback_unavailable` (the listener could not be bound, or stopped
      accepting).

  Nothing polls Connect and nothing asks the owner to compare a fingerprint:
  the code reaches only this machine's loopback, and the proof needs the
  verifier this session holds and the key it enrolled.

  A finished session is kept, readable, until the next start. While a proof is
  in flight the session stays `awaiting_browser`, and a cancel or a paste
  waits for its outcome and the expiry leaves it be: a proof Connect accepted
  is never dropped. Connect calls and the loopback run in tasks, so neither
  blocks a read.

  `opts` (all seams): `:name`, `:pairing` (the `X.Pairing` options),
  `:enrollment` (a module with `X.Enrollment`'s `create/3` and `prove/5`) and
  `:enrollment_opts`, `:authorize` (a function of
  `OAuthFlow.await_authorization/2`'s shape; the loopback itself in
  production), `:clock` (wall time for `paired_at`), `:monotonic`
  (milliseconds), `:timer` (`fn message, ms -> term end`, which sends
  `message` back after `ms`), `:host_name` (the label's source),
  `:on_approved` (what runs once a record is written: the channel's subtree is
  started again) and `:emit` (called with every ending; it emits
  `[:fermix, :channel, :pair]` for the four that event names).
  """

  use GenServer

  require Logger

  alias FermixChannels.Telemetry, as: ChannelTelemetry
  alias FermixChannels.X.Enrollment
  alias FermixChannels.X.Pairing
  alias FermixChannels.X.Supervisor, as: XSupervisor
  alias FermixCore.Auth.OAuthFlow
  alias FermixCore.Auth.OAuthProvider
  alias FermixCore.Realtime.DeviceIdentity

  @ttl_ms 600_000
  # Outlasts every Connect call a reply waits on (`X.Enrollment`'s fifteen
  # seconds) and the record write after it.
  @call_timeout_ms 30_000
  # The message the loopback's waiting process reads a pasted address from.
  @paste_message :x_pair_callback
  # The terminal states `[:fermix, :channel, :pair]` names; a failed session
  # is a log line, not an event.
  @event_states [:approved, :denied, :expired, :cancelled]

  @type state_name :: :awaiting_browser | :approved | :denied | :expired | :cancelled | :failed
  @type failure_reason ::
          :connect_unreachable
          | :connect_refused
          | :proof_rejected
          | :already_paired
          | :unsupported_protocol
          | :key_unavailable
          | :record_unwritable
          | :loopback_unavailable
  @type view :: %{
          session_id: String.t(),
          state: state_name(),
          ttl_ms: non_neg_integer() | nil,
          origin: String.t(),
          handle: nil | String.t(),
          failure: nil | %{reason: failure_reason()}
        }

  # --- Client API ------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Opens a session with Connect at `origin`. `opts`: `:server`."
  @spec start(String.t(), keyword()) ::
          {:ok, %{session: view(), confirm_url: String.t()}} | {:error, term()}
  def start(origin, opts \\ []) when is_binary(origin) and is_list(opts) do
    unless Pairing.origin?(origin),
      do: raise(ArgumentError, "not a Fermix Connect origin: #{inspect(origin)}")

    call(opts, {:start, origin})
  end

  @spec get(String.t(), keyword()) :: {:ok, view()} | {:error, :unknown_pairing_session}
  def get(session_id, opts \\ []) when is_binary(session_id) and is_list(opts),
    do: call(opts, {:get, session_id})

  @doc """
  Hands `url`, the address a browser elsewhere ended on, to the session's
  wait, which reads it as the loopback reads a callback. Answers the session
  as it stands: what the address settles shows on the next read.
  """
  @spec paste(String.t(), String.t(), keyword()) ::
          {:ok, view()} | {:error, :unknown_pairing_session | :pairing_not_waiting}
  def paste(session_id, url, opts \\ [])
      when is_binary(session_id) and is_binary(url) and is_list(opts),
      do: call(opts, {:paste, session_id, url})

  @spec cancel(String.t(), keyword()) :: {:ok, view()} | {:error, :unknown_pairing_session}
  def cancel(session_id, opts \\ []) when is_binary(session_id) and is_list(opts),
    do: call(opts, {:cancel, session_id})

  @doc "The session open or newest kept, as `x.status` names it; `nil` with none."
  @spec latest(keyword()) :: nil | %{session_id: String.t(), state: state_name()}
  def latest(opts \\ []) when is_list(opts) do
    server = Keyword.get(opts, :server, __MODULE__)
    if GenServer.whereis(server), do: GenServer.call(server, :latest), else: nil
  end

  defp call(opts, message),
    do: GenServer.call(Keyword.get(opts, :server, __MODULE__), message, @call_timeout_ms)

  # --- GenServer -------------------------------------------------------------

  @impl true
  def init(opts) do
    {:ok, tasks} = Task.Supervisor.start_link()

    {:ok,
     %{
       deps: deps(opts),
       tasks: tasks,
       running: %{},
       flow: nil,
       starting: nil,
       session: nil,
       waiting: []
     }}
  end

  defp deps(opts) do
    %{
      pairing: Keyword.get(opts, :pairing, []),
      enrollment: Keyword.get(opts, :enrollment, Enrollment),
      enrollment_opts: Keyword.get(opts, :enrollment_opts, []),
      authorize: Keyword.get(opts, :authorize, &OAuthFlow.await_authorization/2),
      clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
      monotonic: Keyword.get(opts, :monotonic, fn -> System.monotonic_time(:millisecond) end),
      timer: Keyword.get(opts, :timer, &send_after/2),
      host_name: Keyword.get(opts, :host_name, &host_name/0),
      on_approved: Keyword.get(opts, :on_approved, &start_channel/0),
      emit: Keyword.get(opts, :emit, &emit/3)
    }
  end

  @impl true
  def handle_call({:start, origin}, from, state), do: open(origin, from, state)
  def handle_call({:get, id}, _from, state), do: {:reply, read(state, id), state}
  def handle_call({:paste, id, url}, from, state), do: paste_call(id, url, from, state)
  def handle_call({:cancel, id}, from, state), do: cancel_call(id, from, state)
  def handle_call(:latest, _from, state), do: {:reply, latest_fact(state.session), state}

  @impl true
  def handle_info({ref, result}, state) when is_map_key(state.running, ref) do
    Process.demonitor(ref, [:flush])
    {kind, running} = Map.pop!(state.running, ref)
    {:noreply, finished(kind, result, %{state | running: running})}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state)
      when is_map_key(state.running, ref) do
    {kind, running} = Map.pop!(state.running, ref)
    Logger.error("X pairing: the #{kind} task crashed: #{inspect(reason)}")
    {:noreply, finished(kind, {:error, {:crashed, reason}}, %{state | running: running})}
  end

  # The authorization link carries a one-use token, so it is never logged.
  def handle_info({:x_pair_authorize_url, attempt, url}, state),
    do: {:noreply, handed_over(attempt, url, state)}

  def handle_info({:expire, id}, state), do: {:noreply, expire(state, id)}

  def handle_info(message, state) do
    Logger.warning("X pairing: ignored an unexpected message: #{inspect(message, limit: 5)}")
    {:noreply, state}
  end

  # --- start -----------------------------------------------------------------

  defp open(_origin, _from, state) when state.starting != nil,
    do: {:reply, {:error, :pairing_active}, state}

  defp open(origin, from, state) do
    if open?(state.session) do
      {:reply, {:error, :pairing_active}, state}
    else
      case prepare(origin, state.deps) do
        {:ok, prepared} -> {:noreply, begin(prepared, from, state)}
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    end
  end

  # A record on disk is a pairing, whether or not it can be read: unpairing
  # removes it first. The key is created only once nothing is in the way.
  defp prepare(origin, deps) do
    with :ok <- unpaired(deps.pairing),
         {:ok, public_key} <- ensure_key(deps.pairing) do
      {:ok, %{origin: origin, label: Enrollment.label(deps.host_name.()), public_key: public_key}}
    end
  end

  defp unpaired(pairing) do
    case Pairing.load(pairing) do
      {:error, :unpaired} -> :ok
      _record_present -> {:error, :already_paired}
    end
  end

  defp ensure_key(pairing) do
    case Pairing.ensure_key(pairing) do
      {:ok, public_key} ->
        {:ok, public_key}

      {:error, reason} ->
        Logger.error("X pairing: the instance key could not be created: #{inspect(reason)}")
        {:error, :key_unavailable}
    end
  end

  # The session's ten minutes start here, before the enrollment is opened.
  defp begin(prepared, from, state) do
    %{enrollment: enrollment, enrollment_opts: enrollment_opts} = state.deps

    starting = %{
      from: from,
      prepared: prepared,
      started_ms: state.deps.monotonic.(),
      attempt: make_ref(),
      created: nil
    }

    state
    |> run(:create, fn -> enrollment.create(prepared.origin, prepared.label, enrollment_opts) end)
    |> Map.put(:starting, starting)
  end

  # The enrollment is open: the loopback binds, and its opener hands the
  # authorization link back here, which is when the start answers.
  defp created({:ok, created}, %{starting: starting} = state) do
    provider = provider(starting.prepared, created)
    remaining = remaining_ms(starting.started_ms, state.deps.monotonic.())
    flow_opts = flow_opts(self(), starting.attempt, remaining)
    authorize = state.deps.authorize

    state
    |> run_flow(fn -> authorize.(provider, flow_opts) end)
    |> Map.put(:starting, %{starting | created: created})
  end

  defp created({:error, reason}, %{starting: starting} = state) do
    GenServer.reply(starting.from, {:error, start_failure(reason)})
    %{state | starting: nil}
  end

  # One attempt's authorization request (§2.1): Connect's link is the
  # authorize endpoint, the enrolled key's id the client, and the redirect this
  # machine's loopback on a port the OS picks, bound once. The flow never
  # exchanges the code (`await_authorization/2` spends nothing); `token_url`
  # names where the code goes, the proof.
  defp provider(prepared, created) do
    %OAuthProvider{
      id: :fermix_connect,
      authorize_url: created.confirm_url,
      token_url: prepared.origin <> "/v1/enrollments/" <> created.enrollment_id <> "/prove",
      client_id: Pairing.key_id(prepared.public_key),
      redirect_host: "127.0.0.1",
      redirect_port: 0,
      redirect_path: "/callback",
      scopes: [],
      fixed_port?: true,
      hardened_callback?: true,
      client_registration: :static
    }
  end

  # The pane opens the link, so the opener only hands it to this process, and
  # the flow prints nothing. Its deadline is what is left of the ten minutes.
  defp flow_opts(server, attempt, remaining_ms) do
    [
      opener: fn url ->
        send(server, {:x_pair_authorize_url, attempt, url})
        :ok
      end,
      puts: fn _line -> :ok end,
      paste_message: @paste_message,
      timeout_ms: max(remaining_ms, 1)
    ]
  end

  defp handed_over(attempt, url, %{starting: %{attempt: attempt} = starting} = state) do
    session = new_session(starting)
    state = %{state | starting: nil, session: session}

    GenServer.reply(starting.from, {:ok, %{session: view(session, state), confirm_url: url}})

    remaining = remaining_ms(session.started_ms, state.deps.monotonic.())
    schedule(state, {:expire, session.session_id}, remaining)
    state
  end

  # A link from an attempt that is no longer starting opens nothing.
  defp handed_over(_attempt, _url, state), do: state

  defp new_session(%{prepared: prepared, created: created, started_ms: started_ms}) do
    %{
      session_id: DeviceIdentity.generate_uuid(),
      enrollment_id: created.enrollment_id,
      origin: prepared.origin,
      public_key: prepared.public_key,
      state: :awaiting_browser,
      started_ms: started_ms,
      handle: nil,
      failure: nil
    }
  end

  defp start_failure(:connect_unreachable), do: :connect_unreachable
  defp start_failure({:connect_refused, _code}), do: :connect_refused
  defp start_failure(:unsupported_protocol), do: :unsupported_protocol
  defp start_failure({:key_unavailable, _reason}), do: :key_unavailable
  defp start_failure({:crashed, reason}), do: {:pairing_crashed, reason}

  # --- the browser's return --------------------------------------------------

  # The loopback ended before it handed a link over: it never listened, and
  # nothing was opened for the owner.
  defp flowed({:error, reason}, %{starting: %{} = starting} = state) do
    GenServer.reply(starting.from, {:error, loopback_failure(reason)})
    %{state | starting: nil}
  end

  defp flowed({:ok, %{code: code, code_verifier: verifier}}, state) do
    if Enrollment.code?(code) do
      prove(state, code, verifier)
    else
      Logger.error("X pairing: the browser returned a code the contract does not name")
      finish(state, :failed, :unsupported_protocol)
    end
  end

  defp flowed({:error, reason}, state) do
    case flow_ending(reason) do
      {:failed, failure_reason} -> finish(state, :failed, failure_reason)
      terminal -> finish(state, terminal, nil)
    end
  end

  # Connect sends `access_denied` alone (§2.1); any other `error` on a
  # callback carrying this attempt's state is Connect refusing the request,
  # and a callback with neither a code nor an error is not the contract's.
  defp flow_ending(:access_denied), do: :denied
  defp flow_ending(:callback_timeout), do: :expired

  defp flow_ending({:authorization_error, code}) do
    Logger.warning("X pairing: Fermix Connect returned the browser with error #{code}")
    {:failed, :connect_refused}
  end

  defp flow_ending(reason) when reason in [:missing_code, :invalid_callback] do
    Logger.error("X pairing: the browser returned a callback the contract does not name")
    {:failed, :unsupported_protocol}
  end

  defp flow_ending(reason), do: {:failed, loopback_failure(reason)}

  defp loopback_failure({:listen_failed, _port, _reason} = reason), do: loopback_down(reason)
  defp loopback_failure({:port_in_use, _port} = reason), do: loopback_down(reason)
  defp loopback_failure({:accept_failed, _reason} = reason), do: loopback_down(reason)
  defp loopback_failure({:crashed, _reason} = reason), do: loopback_down(reason)

  defp loopback_down(reason) do
    Logger.error("X pairing: the listener the browser returns to failed: #{inspect(reason)}")
    :loopback_unavailable
  end

  # --- proving ---------------------------------------------------------------

  defp prove(%{session: session, deps: deps} = state, code, verifier),
    do: run(state, :prove, fn -> prove_and_record(session, code, verifier, deps) end)

  # Runs in the task: the proof, then the record.
  defp prove_and_record(session, code, verifier, deps) do
    %{enrollment: enrollment, enrollment_opts: enrollment_opts} = deps

    with {:ok, proof} <-
           enrollment.prove(
             session.origin,
             session.enrollment_id,
             code,
             verifier,
             enrollment_opts
           ) do
      write_record(record(session, proof, deps.clock.()), deps.pairing)
    end
  end

  defp record(session, proof, now) do
    %Pairing{
      version: 1,
      origin: session.origin,
      instance_id: proof.instance_id,
      tenant_id: proof.tenant_id,
      handle: proof.handle,
      key_id: Pairing.key_id(session.public_key),
      key_generation: proof.key_generation,
      tenant_generation: proof.tenant_generation,
      connect_key_id: proof.connect_key_id,
      connect_public_key: proof.connect_public_key,
      paired_at: now |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }
  end

  defp write_record(record, pairing) do
    case Pairing.save(record, pairing) do
      :ok ->
        {:ok, record}

      {:error, reason} ->
        Logger.error(
          "X pairing: Connect paired instance #{record.instance_id}, but its record could not " <>
            "be written (#{inspect(reason)}); remove that installation from the Connect " <>
            "account page and pair again"
        )

        {:error, {:record, reason}}
    end
  end

  defp proved({:ok, %Pairing{} = record}, state) do
    Logger.info("X pairing: paired as #{record.handle} with #{record.origin}")

    state =
      state
      |> update_session(&%{&1 | handle: record.handle})
      |> finish(:approved, nil)

    report_channel_start(state.deps.on_approved.())
    reply_waiting(state)
  end

  defp proved({:error, reason}, state) do
    state
    |> finish(:failed, proof_failure(reason))
    |> reply_waiting()
  end

  defp proof_failure(:connect_unreachable), do: :connect_unreachable
  defp proof_failure({:connect_refused, "proof_rejected"}), do: :proof_rejected
  defp proof_failure({:connect_refused, _code}), do: :connect_refused
  defp proof_failure(:unsupported_protocol), do: :unsupported_protocol
  defp proof_failure({:key_unavailable, _reason}), do: :key_unavailable
  defp proof_failure({:record, :already_paired}), do: :already_paired
  defp proof_failure({:record, _reason}), do: :record_unwritable
  defp proof_failure({:crashed, _reason}), do: :record_unwritable

  defp reply_waiting(%{waiting: waiting, session: session} = state) do
    Enum.each(waiting, &GenServer.reply(&1, {:ok, view(session, state)}))
    %{state | waiting: []}
  end

  defp report_channel_start({:ok, :started}), do: Logger.info("X pairing: the X channel started")
  defp report_channel_start({:ok, _not_started}), do: :ok

  defp report_channel_start({:error, reason}),
    do: Logger.error("X pairing: the X channel could not start: #{inspect(reason)}")

  # --- pasting, cancelling, expiring ------------------------------------------

  defp paste_call(id, url, from, state) do
    case current(state, id) do
      {:ok, session} -> paste_session(session, url, from, state)
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  defp paste_session(%{state: :awaiting_browser} = session, url, from, state) do
    if proving?(state) do
      {:noreply, %{state | waiting: [from | state.waiting]}}
    else
      send(state.flow.pid, {@paste_message, url})
      {:reply, {:ok, view(session, state)}, state}
    end
  end

  defp paste_session(_finished, _url, _from, state),
    do: {:reply, {:error, :pairing_not_waiting}, state}

  defp cancel_call(id, from, state) do
    case current(state, id) do
      {:ok, session} -> cancel_session(session, from, state)
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  defp cancel_session(%{state: :awaiting_browser}, from, state) do
    if proving?(state) do
      {:noreply, %{state | waiting: [from | state.waiting]}}
    else
      state = state |> stop_flow() |> finish(:cancelled, nil)
      {:reply, {:ok, view(state.session, state)}, state}
    end
  end

  defp cancel_session(session, _from, state), do: {:reply, {:ok, view(session, state)}, state}

  defp expire(%{session: %{session_id: id, state: :awaiting_browser}} = state, id) do
    if proving?(state), do: state, else: state |> stop_flow() |> finish(:expired, nil)
  end

  defp expire(state, _stale_or_finished_id), do: state

  # Killing the loopback's task closes the listener it owns. A callback it had
  # settled meanwhile goes with it, its code unspent: the cancel or the expiry
  # came first.
  defp stop_flow(%{flow: %Task{} = task} = state) do
    _settled_or_nil = Task.shutdown(task, :brutal_kill)
    %{state | flow: nil, running: Map.delete(state.running, task.ref)}
  end

  # --- tasks and session helpers ---------------------------------------------

  defp run(state, kind, fun) do
    task = Task.Supervisor.async_nolink(state.tasks, fun)
    %{state | running: Map.put(state.running, task.ref, kind)}
  end

  defp run_flow(state, fun) do
    task = Task.Supervisor.async_nolink(state.tasks, fun)
    %{state | flow: task, running: Map.put(state.running, task.ref, :flow)}
  end

  defp finished(:create, result, state), do: created(result, state)
  defp finished(:flow, result, state), do: flowed(result, %{state | flow: nil})
  defp finished(:prove, result, state), do: proved(result, state)

  defp proving?(state), do: :prove in Map.values(state.running)

  defp open?(%{state: :awaiting_browser}), do: true
  defp open?(_session_or_nil), do: false

  defp current(%{session: %{session_id: id} = session}, id), do: {:ok, session}
  defp current(_state, _id), do: {:error, :unknown_pairing_session}

  defp read(state, id) do
    with {:ok, session} <- current(state, id), do: {:ok, view(session, state)}
  end

  defp update_session(state, fun), do: %{state | session: fun.(state.session)}

  defp finish(%{session: session} = state, terminal, failure_reason) do
    if failure_reason,
      do: Logger.warning("X pairing: the session failed (#{failure_reason})")

    duration_us = max(state.deps.monotonic.() - session.started_ms, 0) * 1_000
    state.deps.emit.(terminal, duration_us, session)

    failure = if failure_reason, do: %{reason: failure_reason}, else: nil
    update_session(state, &%{&1 | state: terminal, failure: failure})
  end

  defp view(session, state) do
    %{
      session_id: session.session_id,
      state: session.state,
      ttl_ms: ttl_ms(session, state.deps.monotonic.()),
      origin: session.origin,
      handle: session.handle,
      failure: session.failure
    }
  end

  defp ttl_ms(session, now_ms),
    do: if(open?(session), do: remaining_ms(session.started_ms, now_ms), else: nil)

  defp remaining_ms(started_ms, now_ms), do: max(started_ms + @ttl_ms - now_ms, 0)

  defp latest_fact(nil), do: nil
  defp latest_fact(session), do: %{session_id: session.session_id, state: session.state}

  defp schedule(state, message, ms), do: state.deps.timer.(message, ms)

  # --- production defaults ---------------------------------------------------

  defp send_after(message, ms), do: Process.send_after(self(), message, ms)

  defp host_name do
    case :inet.gethostname() do
      {:ok, name} -> List.to_string(name)
      {:error, _reason} -> ""
    end
  end

  defp start_channel, do: XSupervisor.start_registered()

  defp emit(status, duration_us, _session) when status in @event_states do
    ChannelTelemetry.emit_pair(:x, status, duration_us, %{
      platform: nil,
      attestation: nil,
      signer_role: nil
    })
  end

  defp emit(:failed, _duration_us, _session), do: :ok
end
