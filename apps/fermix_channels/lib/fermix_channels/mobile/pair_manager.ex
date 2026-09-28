defmodule FermixChannels.Mobile.PairManager do
  @moduledoc """
  Daemon-owned lifecycle for the single live mobile pairing window.

  Secrets and pending requests exist only in this process. A window lasts at
  most 120 seconds. Failed handshakes are counted per source address: the
  fifth from one address refuses that address for the rest of the window, and
  nothing is counted while a phone is waiting for the owner's decision. No
  number of failures ends the window, so a stranger cannot end the ceremony
  at all: only the owner, the phone and the 120 seconds can. The same phone
  reconnecting (proven by its Noise key) takes its waiting request over.
  Identity, listener, persistence, clocks, timers, and randomness are
  injected at the boundary so tests never bind ports, touch the host
  filesystem, or sleep for expiry.

  A closed window leaves a secret-free record behind so a management client
  that polls can still read how the ceremony ended: at most eight records,
  none older than five minutes on the injected clock.
  """

  use GenServer

  import Bitwise, only: [band: 2, bor: 2]

  alias FermixChannels.Mobile.Identity

  @max_ttl_ms 120_000
  # Per source address: one noisy peer is refused alone. A failed handshake
  # proves nothing about who sent it (garbage needs neither the pairing secret
  # nor the gateway key, and the gateway key is in every pairing QR), so no
  # count of them may end the window for everyone. The addresses one window
  # remembers are bounded; a failure from an address past the bound is not
  # counted, since a peer with that many addresses gains nothing from one more.
  @max_failures 5
  @max_tracked_sources 1_024
  @max_wait_ms 120_000
  @max_text_bytes 128
  @max_retained 8
  @retention_ms 300_000
  @control_chars ~r/[\x{0000}-\x{001F}\x{007F}-\x{009F}]/u

  @type session_id :: String.t()
  @type request :: %{
          name: String.t(),
          model: String.t(),
          app_version: String.t(),
          noise_pk: <<_::256>>,
          sas: String.t(),
          socket_pid: pid()
        }
  @type public_request :: %{
          name: String.t(),
          model: String.t(),
          app_version: String.t(),
          noise_pk: <<_::256>>,
          sas: String.t()
        }
  @type terminal_status :: :approved | :denied | :expired | :cancelled | :device_disconnected
  @type outcome_reason :: :approved | :denied | :timeout | :cancelled | :device_disconnected
  @typedoc "Where a handshake came from; `:unknown` when the caller cannot say."
  @type source :: :inet.ip_address() | :unknown
  @type record :: %{
          session_id: session_id(),
          status: :awaiting_scan | :awaiting_decision | terminal_status(),
          remaining_ms: non_neg_integer() | nil,
          request: public_request() | nil,
          device_id: String.t() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Longest a pairing window can stay open waiting for the owner's decision."
  @spec max_ttl_ms() :: pos_integer()
  def max_ttl_ms, do: @max_ttl_ms

  @doc "Largest device-supplied name, model, or app version accepted at intake."
  @spec max_text_bytes() :: pos_integer()
  def max_text_bytes, do: @max_text_bytes

  @doc "Most finished sessions kept readable after their window closed."
  @spec max_retained() :: pos_integer()
  def max_retained, do: @max_retained

  @doc "Longest a finished session stays readable after its window closed."
  @spec retention_ms() :: pos_integer()
  def retention_ms, do: @retention_ms

  @doc "Most source addresses one window counts failed handshakes for."
  @spec max_tracked_sources() :: pos_integer()
  def max_tracked_sources, do: @max_tracked_sources

  @doc """
  Open the one pairing window. A failed step is named: `{:identity, reason}`
  for the identity guard or `ensure_identity`, `{:listener, reason}` for the
  listener's activation; `:pairing_active` while a window is open.
  """
  @spec open(GenServer.server()) ::
          {:ok, map()}
          | {:error, :pairing_active | {:identity, term()} | {:listener, term()} | term()}
  def open(server \\ __MODULE__), do: GenServer.call(server, :open)

  @spec current(GenServer.server()) :: {:ok, map()} | :none
  def current(server \\ __MODULE__), do: current(server, :unknown)

  @doc "The open window as a handshake from `source` sees it: none once refused."
  @spec current(GenServer.server(), source()) :: {:ok, map()} | :none
  def current(server, source), do: GenServer.call(server, {:current, source})

  @doc """
  The one word the phone's `pair_denied` and the management session view use
  for how a ceremony ended. A window that ran out is `timeout` on both.
  """
  @spec outcome_reason(terminal_status()) :: outcome_reason()
  def outcome_reason(:expired), do: :timeout

  def outcome_reason(status)
      when status in [:approved, :denied, :cancelled, :device_disconnected],
      do: status

  @doc """
  The session as it stands: the open window's record, or a finished one still
  retained. A window whose time ran out reads as expired, not as open.
  """
  @spec session(GenServer.server(), session_id()) :: {:ok, record()} | :unknown
  def session(server, session_id) when is_binary(session_id) and session_id != "" do
    GenServer.call(server, {:session, session_id})
  end

  @doc "The open window's record, else the newest finished one still retained."
  @spec latest(GenServer.server()) :: {:ok, record()} | :none
  def latest(server \\ __MODULE__), do: GenServer.call(server, :latest)

  @spec submit_request(GenServer.server(), session_id(), map()) ::
          {:ok, request()} | {:error, term()}
  def submit_request(server, session_id, attrs)
      when is_binary(session_id) and session_id != "" and is_map(attrs) do
    GenServer.call(server, {:submit_request, session_id, attrs})
  end

  @spec await_request(GenServer.server(), session_id(), pos_integer()) ::
          {:ok, request()} | {:error, term()}
  def await_request(server, session_id, timeout_ms)
      when is_binary(session_id) and session_id != "" and timeout_ms in 1..@max_wait_ms do
    GenServer.call(server, {:await, :request, session_id, timeout_ms}, timeout_ms + 1_000)
  end

  @spec await_decision(GenServer.server(), session_id(), pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def await_decision(server, session_id, timeout_ms)
      when is_binary(session_id) and session_id != "" and timeout_ms in 1..@max_wait_ms do
    GenServer.call(server, {:await, :decision, session_id, timeout_ms}, timeout_ms + 1_000)
  end

  @spec record_failure(GenServer.server(), session_id()) ::
          {:ok, 0..4} | {:error, :timeout | :rate_limited | :session_not_found}
  def record_failure(server, session_id), do: record_failure(server, session_id, :unknown)

  @doc """
  Count one failed handshake from `source`. Its fifth refuses that source for
  the rest of the window, which stays open for everyone else. With a request
  waiting for the owner, or once the window remembers
  `max_tracked_sources/0` other addresses, nothing is counted.
  """
  @spec record_failure(GenServer.server(), session_id(), source()) ::
          {:ok, 0..4} | {:error, :timeout | :rate_limited | :session_not_found}
  def record_failure(server, session_id, source)
      when is_binary(session_id) and session_id != "" and
             (is_tuple(source) or source == :unknown) do
    GenServer.call(server, {:record_failure, session_id, source})
  end

  @spec approve(GenServer.server(), session_id()) :: {:ok, map()} | {:error, term()}
  def approve(server, session_id) when is_binary(session_id) and session_id != "" do
    GenServer.call(server, {:approve, session_id})
  end

  @spec deny(GenServer.server(), session_id()) :: :ok | {:error, term()}
  def deny(server, session_id) when is_binary(session_id) and session_id != "" do
    GenServer.call(server, {:deny, session_id})
  end

  @doc """
  Close the window this session owns as cancelled, if it is still open.

  Cancel is the CLI's cleanup call and expiry is the ordinary end of a pairing
  ceremony, so cancelling an already-closed window succeeds. Use `deny/2` when
  the absence of a window is itself an error worth reporting.
  """
  @spec cancel(GenServer.server(), session_id()) :: :ok | {:error, term()}
  def cancel(server, session_id) when is_binary(session_id) and session_id != "" do
    GenServer.call(server, {:cancel, session_id})
  end

  @impl true
  def init(opts) do
    ttl_ms = Keyword.get(opts, :ttl_ms, @max_ttl_ms)

    if is_integer(ttl_ms) and ttl_ms in 1..@max_ttl_ms do
      {:ok, build_state(opts, ttl_ms)}
    else
      {:stop, {:invalid_pairing_ttl, ttl_ms}}
    end
  end

  @impl true
  def handle_call(:open, _from, state) do
    state = refresh(state)

    case state.window do
      nil -> reply_open(open_window(state))
      _window -> {:reply, {:error, :pairing_active}, state}
    end
  end

  def handle_call({:current, source}, _from, state) do
    state = expire_if_due(state)
    {:reply, current_for(state.window, source), state}
  end

  def handle_call({:session, session_id}, _from, state) do
    state = refresh(state)
    {:reply, find_session(state, session_id), state}
  end

  def handle_call(:latest, _from, state) do
    state = refresh(state)
    {:reply, latest_session(state), state}
  end

  def handle_call({:submit_request, session_id, attrs}, _from, state) do
    with {:ok, state, window} <- fetch_window(state, session_id),
         {:ok, request} <- normalize_request(attrs),
         :ok <- request_available(window, request) do
      :ok = release_replaced_socket(window.request, request)
      public = public_request(request)
      window = %{window | request: request}
      window = reply_waiter(window, :request_waiter, {:ok, public}, state)
      {:reply, {:ok, public}, %{state | window: window}}
    else
      {:error, reason, state} -> {:reply, {:error, reason}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:await, :request, session_id, timeout_ms}, from, state) do
    with {:ok, state, window} <- fetch_window(state, session_id) do
      await_request_call(state, window, from, timeout_ms)
    else
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:await, :decision, session_id, timeout_ms}, from, state) do
    with {:ok, state, window} <- fetch_window(state, session_id),
         :ok <- require_request(window),
         :ok <- waiter_available(window, :decision_waiter) do
      window = put_waiter(window, :decision_waiter, from, timeout_ms, state)
      {:noreply, %{state | window: window}}
    else
      {:error, reason, state} -> {:reply, {:error, reason}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:record_failure, session_id, source}, _from, state) do
    with {:ok, state, window} <- fetch_window(state, session_id) do
      failure_reply(state, window, source)
    else
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:approve, session_id}, _from, state) do
    with {:ok, state, window} <- fetch_window(state, session_id),
         :ok <- require_request(window) do
      approve_window(state, window)
    else
      {:error, reason, state} -> {:reply, {:error, reason}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:deny, session_id}, _from, state) do
    case fetch_window(state, session_id) do
      {:ok, state, window} -> deny_window(state, window)
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:cancel, session_id}, _from, state) do
    case fetch_window(state, session_id) do
      {:ok, state, _window} -> {:reply, :ok, close_window(state, :cancelled)}
      {:error, :session_not_found, state} -> {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({:pair_expire, session_id, token}, state) do
    state =
      if matching_timer?(state.window, session_id, token), do: expire_window(state), else: state

    {:noreply, state}
  end

  def handle_info({:pair_wait_timeout, session_id, key, token}, state) do
    {:noreply, timeout_waiter(state, session_id, key, token)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.window do
      cancel_timer(state.window.timer_ref, state)
      cancel_waiter_timer(state.window.request_waiter, state)
      cancel_waiter_timer(state.window.decision_waiter, state)
    end

    :ok
  end

  defp build_state(opts, ttl_ms) do
    root = Keyword.get(opts, :root)
    listener = Keyword.get(opts, :listener, FermixChannels.Mobile.Listener)
    device_store = Keyword.get(opts, :device_store, FermixChannels.Mobile.DeviceStore)
    custom_identity? = Keyword.has_key?(opts, :ensure_identity)

    %{
      window: nil,
      closed: [],
      ttl_ms: ttl_ms,
      clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end),
      wall_clock: Keyword.get(opts, :wall_clock, &DateTime.utc_now/0),
      schedule_timer: Keyword.get(opts, :schedule_timer, &Process.send_after(self(), &1, &2)),
      cancel_timer: Keyword.get(opts, :cancel_timer, &Process.cancel_timer/1),
      ensure_identity: Keyword.get(opts, :ensure_identity, default_identity(root)),
      identity_guard:
        Keyword.get(
          opts,
          :identity_guard,
          default_identity_guard(root, device_store, custom_identity?)
        ),
      activate_listener:
        Keyword.get(opts, :activate_listener, default_activate_listener(listener)),
      persist_device:
        Keyword.get(opts, :persist_device, default_persist_device(device_store, root)),
      emit_pair: Keyword.get(opts, :emit_pair, &default_emit_pair/2),
      session_id_generator: Keyword.get(opts, :session_id_generator, &uuid/0),
      device_id_generator: Keyword.get(opts, :device_id_generator, &uuid/0),
      secret_generator: Keyword.get(opts, :secret_generator, &:crypto.strong_rand_bytes/1),
      salt_generator: Keyword.get(opts, :salt_generator, &:crypto.strong_rand_bytes/1)
    }
  end

  defp open_window(state) do
    with :ok <- step(:identity, state.identity_guard.()),
         {:ok, identity} <- step(:identity, state.ensure_identity.()),
         :ok <- step(:listener, activate_listener(state.activate_listener, identity)),
         {:ok, session_id} <- generated_id(state.session_id_generator),
         {:ok, secret} <- generated_bytes(state.secret_generator, 32) do
      now = state.clock.()
      timer_token = make_ref()
      timer_ref = state.schedule_timer.({:pair_expire, session_id, timer_token}, state.ttl_ms)

      window = %{
        session_id: session_id,
        secret: secret,
        identity: public_identity(identity),
        opened_at_ms: now,
        expires_at_ms: now + state.ttl_ms,
        timer_ref: timer_ref,
        timer_token: timer_token,
        failures_by_source: %{},
        request: nil,
        request_waiter: nil,
        decision_waiter: nil
      }

      {:ok, public_window(window), %{state | window: window}}
    else
      {:error, reason} -> {:error, reason, state}
      other -> {:error, {:invalid_pair_dependency, other}, state}
    end
  end

  # A caller names the failed step (identity or listener) without knowing
  # every reason the identity module or the listener can give.
  defp step(name, {:error, reason}), do: {:error, {name, reason}}
  defp step(_name, result), do: result

  defp reply_open({:ok, window, state}), do: {:reply, {:ok, window}, state}
  defp reply_open({:error, reason, state}), do: {:reply, {:error, reason}, state}

  defp fetch_window(state, session_id) do
    state = expire_if_due(state)

    case state.window do
      %{session_id: ^session_id} = window -> {:ok, state, window}
      nil -> {:error, :session_not_found, state}
      _other -> {:error, :session_not_found, state}
    end
  end

  defp await_request_call(state, %{request: request} = window, _from, _timeout_ms)
       when not is_nil(request),
       do: {:reply, {:ok, public_request(request)}, %{state | window: window}}

  defp await_request_call(state, window, from, timeout_ms) do
    case waiter_available(window, :request_waiter) do
      :ok ->
        window = put_waiter(window, :request_waiter, from, timeout_ms, state)
        {:noreply, %{state | window: window}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp put_waiter(window, key, from, timeout_ms, state) do
    token = make_ref()
    remaining = max(window.expires_at_ms - state.clock.(), 1)
    delay = min(timeout_ms, remaining)
    message = {:pair_wait_timeout, window.session_id, key, token}
    waiter = %{from: from, timer_ref: state.schedule_timer.(message, delay), token: token}
    Map.put(window, key, waiter)
  end

  defp reply_waiter(window, key, reply, state) do
    case Map.get(window, key) do
      nil ->
        window

      waiter ->
        cancel_timer(waiter.timer_ref, state)
        GenServer.reply(waiter.from, reply)
        Map.put(window, key, nil)
    end
  end

  defp timeout_waiter(state, session_id, key, token) do
    with %{session_id: ^session_id} = window <- state.window,
         %{token: ^token} = waiter <- Map.get(window, key) do
      GenServer.reply(waiter.from, {:error, :timeout})
      %{state | window: Map.put(window, key, nil)}
    else
      _stale -> state
    end
  end

  defp deny_window(state, window) do
    window = reply_waiter(window, :decision_waiter, {:error, :denied}, state)
    {:reply, :ok, close_window(%{state | window: window}, :denied)}
  end

  # The requesting socket must still be alive at the moment of approval: writing
  # a devices.toml row for a phone that never receives `pair_approved` leaves it
  # unable to re-pair, because the duplicate-noise-identity guard refuses the
  # second attempt until the owner revokes the orphan by hand. A dead socket
  # also ends the ceremony: the phone that asked is gone, so nothing is left to
  # approve and the window closes as `:device_disconnected`.
  defp approve_window(state, %{request: %{socket_pid: pid}} = window) do
    if Process.alive?(pid) do
      persist_approval(state, window)
    else
      {:reply, {:error, :device_disconnected}, close_window(state, :device_disconnected)}
    end
  end

  defp persist_approval(state, window) do
    with {:ok, attrs} <- build_device(window.request, state),
         {:ok, device} <- persist_device(attrs, state) do
      window =
        reply_waiter(window, :decision_waiter, {:ok, %{approved: true, device: device}}, state)

      state = close_window(%{state | window: window}, :approved, {:ok, device})
      {:reply, {:ok, device}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # A phone waiting for the owner has proven the pairing secret; handshake
  # noise from anyone else cannot touch that ceremony, so it is not counted.
  defp failure_reply(state, %{request: request} = window, source) when not is_nil(request),
    do: {:reply, {:ok, source_failures(window, source)}, state}

  defp failure_reply(state, window, source) do
    counts = window.failures_by_source

    if Map.has_key?(counts, source) or map_size(counts) < @max_tracked_sources do
      count = min(source_failures(window, source) + 1, @max_failures)
      window = %{window | failures_by_source: Map.put(counts, source, count)}
      {:reply, counted_failure(count), %{state | window: window}}
    else
      {:reply, {:ok, 0}, state}
    end
  end

  defp counted_failure(count) when count >= @max_failures, do: {:error, :rate_limited}
  defp counted_failure(count), do: {:ok, count}

  defp source_failures(window, source), do: Map.get(window.failures_by_source, source, 0)

  defp current_for(nil, _source), do: :none

  defp current_for(window, source) do
    if source_failures(window, source) >= @max_failures,
      do: :none,
      else: {:ok, public_window(window)}
  end

  defp close_window(state, status, socket_result \\ nil) do
    window = state.window
    now = state.clock.()
    cancel_timer(window.timer_ref, state)
    terminal_reply = {:error, outcome_reason(status)}
    window = reply_waiter(window, :request_waiter, terminal_reply, state)
    _window = reply_waiter(window, :decision_waiter, terminal_reply, state)
    notify_socket(window, socket_result || terminal_reply)
    duration_us = max(now - window.opened_at_ms, 0) * 1_000
    :ok = state.emit_pair.(status, duration_us)
    closed = closed_record(window, status, socket_result, now)
    prune_closed(%{state | window: nil, closed: [closed | state.closed]})
  end

  # Secret-free by construction: the PSK, identity and socket never leave the
  # window, so a retained record can be read long after the ceremony ended.
  defp closed_record(window, status, socket_result, now) do
    %{
      session_id: window.session_id,
      status: status,
      request: optional_public_request(window.request),
      device_id: approved_device_id(socket_result),
      closed_at_ms: now
    }
  end

  defp approved_device_id({:ok, device}), do: Map.fetch!(device, :device_id)
  defp approved_device_id(_socket_result), do: nil

  defp refresh(state), do: state |> expire_if_due() |> prune_closed()

  defp prune_closed(state) do
    now = state.clock.()

    closed =
      state.closed
      |> Enum.filter(&(now - &1.closed_at_ms <= @retention_ms))
      |> Enum.take(@max_retained)

    %{state | closed: closed}
  end

  defp find_session(%{window: %{session_id: session_id} = window} = state, session_id),
    do: {:ok, open_record(window, state)}

  defp find_session(state, session_id) do
    case Enum.find(state.closed, &(&1.session_id == session_id)) do
      nil -> :unknown
      closed -> {:ok, retained_record(closed)}
    end
  end

  defp latest_session(%{window: nil, closed: []}), do: :none

  defp latest_session(%{window: nil, closed: [newest | _older]}),
    do: {:ok, retained_record(newest)}

  defp latest_session(state), do: {:ok, open_record(state.window, state)}

  defp open_record(window, state) do
    %{
      session_id: window.session_id,
      status: if(window.request, do: :awaiting_decision, else: :awaiting_scan),
      remaining_ms: max(window.expires_at_ms - state.clock.(), 0),
      request: optional_public_request(window.request),
      device_id: nil
    }
  end

  defp retained_record(closed) do
    closed |> Map.delete(:closed_at_ms) |> Map.put(:remaining_ms, nil)
  end

  defp expire_if_due(%{window: nil} = state), do: state

  defp expire_if_due(state) do
    if state.clock.() >= state.window.expires_at_ms, do: expire_window(state), else: state
  end

  defp expire_window(state), do: close_window(state, :expired)

  defp normalize_request(attrs) do
    request = %{
      name: field(attrs, :name, "device_name"),
      model: field(attrs, :model, "model"),
      app_version: field(attrs, :app_version, "app_version"),
      noise_pk: field(attrs, :noise_pk, "noise_pk"),
      sas: field(attrs, :sas, "sas"),
      socket_pid: field(attrs, :socket_pid, "socket_pid")
    }

    validate_request(request)
  end

  defp validate_request(request) do
    with :ok <- validate_text(:name, request.name),
         :ok <- validate_text(:model, request.model),
         :ok <- validate_text(:app_version, request.app_version),
         :ok <- validate_noise_pk(request.noise_pk),
         :ok <- validate_sas(request.sas),
         :ok <- validate_socket(request.socket_pid) do
      {:ok, request}
    end
  end

  # Device-supplied text is rendered in the operator's SAS approval prompt, so
  # intake is where it must be proven printable: an ESC or C1 sequence could
  # repaint the very prompt the ceremony exists to protect. 128 bytes is the one
  # intake bound; the CLI and the durable store assert the same ceiling
  # downstream instead of discovering it after the handshake completed.
  defp validate_text(field, value) when is_binary(value) do
    cond do
      not String.valid?(value) -> {:error, {:invalid_pair_request, {field, :invalid_utf8}}}
      String.trim(value) == "" -> {:error, {:invalid_pair_request, field}}
      byte_size(value) > @max_text_bytes -> {:error, {:invalid_pair_request, {field, :too_long}}}
      Regex.match?(@control_chars, value) -> control_character_error(field)
      true -> :ok
    end
  end

  defp validate_text(field, _value), do: {:error, {:invalid_pair_request, field}}

  defp control_character_error(field),
    do: {:error, {:invalid_pair_request, {field, :control_characters}}}

  defp validate_noise_pk(pk) when is_binary(pk) and byte_size(pk) == 32, do: :ok
  defp validate_noise_pk(_pk), do: {:error, {:invalid_pair_request, :noise_pk}}

  defp validate_sas(sas) do
    if valid_sas?(sas), do: :ok, else: {:error, {:invalid_pair_request, :sas}}
  end

  defp validate_socket(pid) when is_pid(pid) do
    if Process.alive?(pid), do: :ok, else: {:error, {:invalid_pair_request, :socket_pid}}
  end

  defp validate_socket(_pid), do: {:error, {:invalid_pair_request, :socket_pid}}

  defp build_device(request, state) do
    with {:ok, device_id} <- generated_id(state.device_id_generator),
         {:ok, salt} <- generated_bytes(state.salt_generator, 32),
         %DateTime{} = now <- state.wall_clock.() do
      {:ok,
       %{
         device_id: device_id,
         name: request.name,
         model: request.model,
         noise_pk: request.noise_pk,
         push_token: nil,
         created_at: now,
         last_seen: nil,
         apns_key_salt: salt
       }}
    else
      other -> {:error, {:invalid_pair_dependency, other}}
    end
  end

  defp persist_device(attrs, state) do
    case state.persist_device.(attrs) do
      :ok -> {:ok, attrs}
      {:ok, device} -> {:ok, device}
      {:error, reason} -> {:error, {:device_persist_failed, reason}}
      other -> {:error, {:invalid_device_store_reply, other}}
    end
  end

  # The Noise key is authenticated by the handshake the request arrived on, so
  # a request with the waiting one's key is that phone on a new connection:
  # the old one went quiet without a FIN (a network change, a suspended app).
  defp request_available(%{request: nil}, _request), do: :ok

  defp request_available(%{request: %{noise_pk: key}}, %{noise_pk: key}), do: :ok
  defp request_available(_window, _request), do: {:error, :request_pending}

  defp release_replaced_socket(%{socket_pid: old}, %{socket_pid: new}) when old != new do
    send(old, {:mobile_replaced, new})
    :ok
  end

  defp release_replaced_socket(_waiting, _request), do: :ok
  defp require_request(%{request: nil}), do: {:error, :request_missing}
  defp require_request(_window), do: :ok

  defp waiter_available(window, key) do
    if is_nil(Map.get(window, key)), do: :ok, else: {:error, :already_waiting}
  end

  defp public_window(window) do
    window
    |> Map.take([
      :session_id,
      :secret,
      :identity,
      :opened_at_ms,
      :expires_at_ms,
      :request
    ])
    |> Map.update(:request, nil, &optional_public_request/1)
  end

  defp public_request(request), do: Map.delete(request, :socket_pid)
  defp optional_public_request(nil), do: nil
  defp optional_public_request(request), do: public_request(request)

  defp generated_id(fun) do
    case fun.() do
      id when is_binary(id) and id != "" -> {:ok, id}
      other -> {:error, {:invalid_generated_id, other}}
    end
  end

  defp generated_bytes(fun, size) do
    value = invoke_bytes_generator(fun, size)

    if is_binary(value) and byte_size(value) == size,
      do: {:ok, value},
      else: {:error, :invalid_random_bytes}
  end

  defp invoke_bytes_generator(fun, size) when is_function(fun, 1), do: fun.(size)
  defp invoke_bytes_generator(fun, _size) when is_function(fun, 0), do: fun.()

  defp default_identity(nil), do: fn -> apply(FermixChannels.Mobile.Identity, :ensure, [[]]) end

  defp default_identity(root) do
    fn -> apply(FermixChannels.Mobile.Identity, :ensure, [[root: root]]) end
  end

  defp default_identity_guard(_root, _device_store, true), do: fn -> :ok end

  defp default_identity_guard(root, device_store, false) do
    fn ->
      opts = if is_nil(root), do: [], else: [root: root]

      with {:ok, paths} <- Identity.paths(opts),
           {:ok, state} <- identity_artifact_state(paths) do
        guard_missing_identity(state, device_store, root)
      end
    end
  end

  defp identity_artifact_state(paths) do
    entries = [paths.gateway_key, paths.tls_key, paths.tls_cert, paths.transaction]

    results = Enum.map(entries, &File.lstat/1)

    cond do
      Enum.all?(results, &(&1 == {:error, :enoent})) ->
        {:ok, :missing}

      Enum.any?(results, &match?({:error, reason} when reason != :enoent, &1)) ->
        {:error, :identity_state_unreadable}

      true ->
        {:ok, :present}
    end
  end

  defp guard_missing_identity(:present, _device_store, _root), do: :ok

  defp guard_missing_identity(:missing, device_store, root) do
    case list_devices(device_store, root) do
      {:ok, []} -> :ok
      {:ok, devices} -> {:error, {:identity_missing_for_paired_devices, length(devices)}}
      {:error, reason} -> {:error, {:device_store_unavailable, reason}}
    end
  end

  defp list_devices(nil, root) do
    guarded_store_call(fn ->
      apply(FermixChannels.Mobile.DeviceStore, :list, [[root: root]])
    end)
  end

  defp list_devices(device_store, _root) do
    guarded_store_call(fn ->
      apply(FermixChannels.Mobile.DeviceStore, :list, [device_store])
    end)
  end

  defp guarded_store_call(call) do
    call.()
  catch
    :exit, reason -> {:error, {:device_store_exit, reason}}
  end

  defp public_identity(identity) do
    %{
      gateway_public_key: Map.get(identity, :gateway_public_key),
      tls_fingerprint: Map.get(identity, :tls_fingerprint)
    }
  end

  defp default_activate_listener(listener) do
    fn identity -> apply(FermixChannels.Mobile.Listener, :activate, [listener, identity]) end
  end

  defp default_persist_device(device_store, _root) when not is_nil(device_store) do
    fn attrs ->
      apply(FermixChannels.Mobile.DeviceStore, :add_approved, [device_store, attrs])
    end
  end

  defp default_persist_device(_device_store, root) do
    fn attrs ->
      apply(FermixChannels.Mobile.DeviceStore, :add_approved, [attrs, [root: root]])
    end
  end

  defp default_emit_pair(status, duration_us) do
    apply(FermixChannels.Telemetry, :emit_pair, [:mobile, status, duration_us])
  end

  defp matching_timer?(%{session_id: session_id, timer_token: token}, session_id, token), do: true
  defp matching_timer?(_window, _session_id, _token), do: false

  defp field(attrs, atom_key, string_key),
    do: Map.get(attrs, atom_key, Map.get(attrs, string_key))

  defp valid_sas?(sas) when is_binary(sas) and byte_size(sas) == 6 do
    sas |> String.to_charlist() |> Enum.all?(&(&1 in ?0..?9))
  end

  defp valid_sas?(_sas), do: false

  defp activate_listener(fun, identity) do
    case fun.(identity) do
      :ok -> :ok
      {:ok, _status} -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_listener_reply, other}}
    end
  end

  defp notify_socket(%{request: %{socket_pid: pid}, session_id: session_id}, result) do
    send(pid, {:mobile_pair_decision, session_id, result})
    :ok
  end

  defp notify_socket(_window, _result), do: :ok
  defp cancel_timer(nil, _state), do: :ok
  defp cancel_timer(ref, state), do: state.cancel_timer.(ref)
  defp cancel_waiter_timer(nil, _state), do: :ok
  defp cancel_waiter_timer(waiter, state), do: cancel_timer(waiter.timer_ref, state)

  # Lowercase: the trust store accepts only the canonical lowercase form, and
  # `Integer.to_string/2` writes hex digits in uppercase.
  defp uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    c = bor(band(c, 0x0FFF), 0x4000)
    d = bor(band(d, 0x3FFF), 0x8000)

    [{a, 8}, {b, 4}, {c, 4}, {d, 4}, {e, 12}]
    |> Enum.map_join("-", fn {value, width} ->
      value |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(width, "0")
    end)
  end
end
