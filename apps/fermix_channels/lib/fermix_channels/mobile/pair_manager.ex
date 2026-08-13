defmodule FermixChannels.Mobile.PairManager do
  @moduledoc """
  Daemon-owned lifecycle for the single live mobile pairing window.

  Secrets and pending requests exist only in this process. A window lasts at
  most 120 seconds and five failed handshakes close it. Identity, listener,
  persistence, clocks, timers, and randomness are injected at the boundary so
  tests never bind ports, touch the host filesystem, or sleep for expiry.
  """

  use GenServer

  import Bitwise, only: [band: 2, bor: 2]

  @max_ttl_ms 120_000
  @max_failures 5
  @max_wait_ms 120_000

  @type session_id :: String.t()
  @type request :: %{
          name: String.t(),
          model: String.t(),
          app_version: String.t(),
          noise_pk: <<_::256>>,
          sas: String.t(),
          socket_pid: pid()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec open(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def open(server \\ __MODULE__), do: GenServer.call(server, :open)

  @spec current(GenServer.server()) :: {:ok, map()} | :none
  def current(server \\ __MODULE__), do: GenServer.call(server, :current)

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
          {:ok, 1..4} | {:error, :expired | :rate_limited | :session_not_found}
  def record_failure(server, session_id)
      when is_binary(session_id) and session_id != "" do
    GenServer.call(server, {:record_failure, session_id})
  end

  @spec approve(GenServer.server(), session_id()) :: {:ok, map()} | {:error, term()}
  def approve(server, session_id) when is_binary(session_id) and session_id != "" do
    GenServer.call(server, {:approve, session_id})
  end

  @spec deny(GenServer.server(), session_id()) :: :ok | {:error, term()}
  def deny(server, session_id) when is_binary(session_id) and session_id != "" do
    GenServer.call(server, {:deny, session_id})
  end

  @spec cancel(GenServer.server(), session_id()) :: :ok | {:error, term()}
  def cancel(server, session_id) when is_binary(session_id) and session_id != "" do
    deny(server, session_id)
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
    state = expire_if_due(state)

    case state.window do
      nil -> reply_open(open_window(state))
      _window -> {:reply, {:error, :pairing_active}, state}
    end
  end

  def handle_call(:current, _from, state) do
    state = expire_if_due(state)
    reply = if state.window, do: {:ok, public_window(state.window)}, else: :none
    {:reply, reply, state}
  end

  def handle_call({:submit_request, session_id, attrs}, _from, state) do
    with {:ok, state, window} <- fetch_window(state, session_id),
         :ok <- request_available(window),
         {:ok, request} <- normalize_request(attrs) do
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

  def handle_call({:record_failure, session_id}, _from, state) do
    with {:ok, state, window} <- fetch_window(state, session_id) do
      failure_reply(state, %{window | failures: window.failures + 1})
    else
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:approve, session_id}, _from, state) do
    with {:ok, state, window} <- fetch_window(state, session_id),
         :ok <- require_request(window),
         {:ok, attrs} <- build_device(window.request, state),
         {:ok, device} <- persist_device(attrs, state) do
      window =
        reply_waiter(window, :decision_waiter, {:ok, %{approved: true, device: device}}, state)

      state = close_window(%{state | window: window}, :approved, {:ok, device})
      {:reply, {:ok, device}, state}
    else
      {:error, reason, state} -> {:reply, {:error, reason}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:deny, session_id}, _from, state) do
    with {:ok, state, window} <- fetch_window(state, session_id) do
      window = reply_waiter(window, :decision_waiter, {:error, :denied}, state)
      state = close_window(%{state | window: window}, :denied)
      {:reply, :ok, state}
    else
      {:error, reason, state} -> {:reply, {:error, reason}, state}
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
    with :ok <- state.identity_guard.(),
         {:ok, identity} <- state.ensure_identity.(),
         :ok <- activate_listener(state.activate_listener, identity),
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
        failures: 0,
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

  defp failure_reply(state, %{failures: failures} = window) when failures >= @max_failures do
    state = %{state | window: window} |> close_window(:rate_limited)
    {:reply, {:error, :rate_limited}, state}
  end

  defp failure_reply(state, window) do
    {:reply, {:ok, window.failures}, %{state | window: window}}
  end

  defp close_window(state, status, socket_result \\ nil) do
    window = state.window
    cancel_timer(window.timer_ref, state)
    terminal_reply = {:error, terminal_reason(status)}
    window = reply_waiter(window, :request_waiter, terminal_reply, state)
    _window = reply_waiter(window, :decision_waiter, terminal_reply, state)
    notify_socket(window, socket_result || terminal_reply)
    duration_us = max(state.clock.() - window.opened_at_ms, 0) * 1_000
    :ok = state.emit_pair.(status, duration_us)
    %{state | window: nil}
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
    cond do
      not nonempty?(request.name) ->
        {:error, {:invalid_pair_request, :name}}

      not nonempty?(request.model) ->
        {:error, {:invalid_pair_request, :model}}

      not nonempty?(request.app_version) ->
        {:error, {:invalid_pair_request, :app_version}}

      not (is_binary(request.noise_pk) and byte_size(request.noise_pk) == 32) ->
        {:error, {:invalid_pair_request, :noise_pk}}

      not valid_sas?(request.sas) ->
        {:error, {:invalid_pair_request, :sas}}

      not (is_pid(request.socket_pid) and Process.alive?(request.socket_pid)) ->
        {:error, {:invalid_pair_request, :socket_pid}}

      true ->
        {:ok, request}
    end
  end

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

  defp request_available(%{request: nil}), do: :ok
  defp request_available(_window), do: {:error, :request_pending}
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
      :failures,
      :request
    ])
    |> Map.update(:request, nil, fn
      nil -> nil
      request -> public_request(request)
    end)
  end

  defp public_request(request), do: Map.delete(request, :socket_pid)

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

      with {:ok, paths} <- FermixChannels.Mobile.Identity.paths(opts),
           {:ok, state} <- identity_artifact_state(paths) do
        guard_missing_identity(state, device_store, root)
      end
    end
  end

  defp identity_artifact_state(paths) do
    entries = [paths.gateway_key, paths.tls_key, paths.tls_cert, paths.transaction]

    results = Enum.map(entries, &File.lstat/1)

    cond do
      Enum.all?(results, &(&1 == {:error, :enoent})) -> {:ok, :missing}
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
    try do
      call.()
    catch
      :exit, reason -> {:error, {:device_store_exit, reason}}
    end
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

  defp default_persist_device(device_store, _root) when not is_nil(device_store),
    do: fn attrs -> apply(FermixChannels.Mobile.DeviceStore, :add, [device_store, attrs]) end

  defp default_persist_device(_device_store, root),
    do: fn attrs -> apply(FermixChannels.Mobile.DeviceStore, :add, [attrs, [root: root]]) end

  defp default_emit_pair(status, duration_us) do
    apply(FermixChannels.Telemetry, :emit_pair, [:mobile, status, duration_us])
  end

  defp matching_timer?(%{session_id: session_id, timer_token: token}, session_id, token), do: true
  defp matching_timer?(_window, _session_id, _token), do: false
  defp terminal_reason(:approved), do: :approved
  defp terminal_reason(:denied), do: :denied
  defp terminal_reason(:expired), do: :expired
  defp terminal_reason(:rate_limited), do: :rate_limited

  defp field(attrs, atom_key, string_key),
    do: Map.get(attrs, atom_key, Map.get(attrs, string_key))

  defp nonempty?(value), do: is_binary(value) and String.trim(value) != ""

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

  defp uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    c = bor(band(c, 0x0FFF), 0x4000)
    d = bor(band(d, 0x3FFF), 0x8000)

    [{a, 8}, {b, 4}, {c, 4}, {d, 4}, {e, 12}]
    |> Enum.map_join("-", fn {value, width} ->
      value |> Integer.to_string(16) |> String.pad_leading(width, "0")
    end)
  end
end
