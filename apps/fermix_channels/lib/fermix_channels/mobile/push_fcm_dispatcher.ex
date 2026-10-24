defmodule FermixChannels.Mobile.Push.FcmDispatcher do
  @moduledoc """
  Sends FCM HTTP v1 messages for the owner's Firebase project (M51 §10).

  FCM v1 is one HTTPS POST per message, so unlike APNs there is no connection
  to own: requests go through `FermixCore.Net.HttpClient`, on the shared pool
  and through the configured proxy, which APNs' own HTTP/2 socket cannot use.
  The OAuth access token is minted from the service account by Goth when a
  batch needs one, kept until a minute before it expires, and dropped when
  FCM answers 401.

  The server never waits on the network: each batch runs in a linked process
  that answers its caller and hands back the token and how the batch went, so
  `status/1` answers at once while a batch is out.

  A push is sent at least once, not exactly once: `HttpClient` repeats a
  request once on a pooled connection that turns out to be closed, which can
  repeat a send whose first answer was lost. The phone shows a row once,
  whichever copy comes first.
  """

  use GenServer

  require Logger

  alias FermixChannels.Mobile.Push.FcmConfig
  alias FermixCore.Net.HttpClient

  @scope "https://www.googleapis.com/auth/firebase.messaging"
  @max_messages 64
  @max_batches 8
  @token_timeout_ms 10_000
  @request_timeout_ms 10_000
  @call_slack_ms 1_000
  # A token this close to its expiry is minted again rather than sent.
  @token_margin_s 60
  @error_codes %{
    "UNREGISTERED" => :unregistered,
    "INVALID_ARGUMENT" => :invalid_argument,
    "SENDER_ID_MISMATCH" => :sender_id_mismatch,
    "QUOTA_EXCEEDED" => :quota_exceeded,
    "UNAVAILABLE" => :unavailable,
    "INTERNAL" => :internal,
    "THIRD_PARTY_AUTH_ERROR" => :third_party_auth_error
  }

  @type token :: %{value: String.t(), expires_at: integer()}
  @type result :: :ok | {:error, atom()}
  @type health :: :ready | {:degraded, :auth_failed | :unreachable}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) when is_list(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  @doc """
  Send `messages` (FCM v1 request bodies), answering one result per message in
  order: `:ok`, or `{:error, class}` with FCM's error code as an atom.
  """
  @spec dispatch(GenServer.server(), [map()], FcmConfig.t()) ::
          {:ok, [result()]} | {:error, term()}
  def dispatch(server \\ __MODULE__, messages, config)

  def dispatch(server, messages, %FcmConfig{enabled: true} = config)
      when is_list(messages) and length(messages) in 1..@max_messages do
    timeout = @token_timeout_ms + length(messages) * @request_timeout_ms + @call_slack_ms
    call(server, {:dispatch, messages, fingerprint(config)}, timeout)
  end

  def dispatch(_server, messages, %FcmConfig{}) when is_list(messages),
    do: {:error, {:invalid_dispatch_count, length(messages), @max_messages}}

  @doc "Whether the last batch reached FCM, or why it did not."
  @spec status(GenServer.server()) :: health()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl true
  def init(opts) do
    case Keyword.fetch(opts, :config) do
      {:ok, %FcmConfig{enabled: true} = config} ->
        Process.flag(:trap_exit, true)
        {:ok, initial_state(config, opts)}

      _other ->
        {:stop, {:fcm_dispatcher_start_failed, :missing_enabled_config}}
    end
  end

  defp initial_state(config, opts) do
    request = Keyword.get(opts, :request, &HttpClient.request(&1, "fcm"))

    %{
      config: config,
      fingerprint: fingerprint(config),
      token: nil,
      refused_token: nil,
      health: :ready,
      batches: %{},
      request: request,
      fetch_token: Keyword.get(opts, :fetch_token, &fetch_token(&1, request)),
      clock: Keyword.get(opts, :clock, fn -> System.os_time(:second) end)
    }
  end

  @impl true
  def handle_call({:dispatch, _messages, fingerprint}, _from, state)
      when fingerprint != state.fingerprint do
    {:reply, {:error, :push_dispatcher_config_mismatch}, state}
  end

  def handle_call({:dispatch, _messages, _fingerprint}, _from, state)
      when map_size(state.batches) >= @max_batches do
    {:reply, {:error, {:push_unavailable, :busy}}, state}
  end

  def handle_call({:dispatch, messages, _fingerprint}, from, state) do
    batch = %{
      owner: self(),
      from: from,
      messages: messages,
      token: usable_token(state.token, state.clock.()),
      config: state.config,
      request: state.request,
      fetch_token: state.fetch_token
    }

    pid = spawn_link(fn -> run_batch(batch) end)
    {:noreply, %{state | batches: Map.put(state.batches, pid, from)}}
  end

  def handle_call(:status, _from, state), do: {:reply, state.health, state}

  @impl true
  def handle_info({:batch_done, pid, token, health}, state) do
    state = %{state | batches: Map.delete(state.batches, pid)}
    {:noreply, state |> settle_token(token) |> settle_health(health)}
  end

  # A batch that died before it answered is answered here. Its exit reason can
  # hold the frames of what it was sending, so only its class is told.
  def handle_info({:EXIT, pid, reason}, state) when is_map_key(state.batches, pid) do
    {from, batches} = Map.pop(state.batches, pid)
    class = exit_class(reason)
    Logger.error("mobile FCM batch exited before it answered (#{inspect(class)})")
    GenServer.reply(from, {:error, {:push_dependency_exit, :fcm_batch, class}})
    {:noreply, %{state | batches: batches}}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  # Batches overlap, so a reported token is weighed against the cached one: a
  # token FCM refused is dropped and never cached again, even by a slower batch
  # that started with it, and of two good tokens the later-expiring one stays.
  defp settle_token(state, :none), do: state

  defp settle_token(state, {:refused, %{value: value}}) do
    token = if match?(%{value: ^value}, state.token), do: nil, else: state.token
    %{state | token: token, refused_token: value}
  end

  defp settle_token(%{refused_token: value} = state, {:kept, %{value: value}}), do: state
  defp settle_token(%{token: nil} = state, {:kept, token}), do: %{state | token: token}

  defp settle_token(state, {:kept, token}) do
    if token.expires_at > state.token.expires_at, do: %{state | token: token}, else: state
  end

  defp settle_health(state, :unchanged), do: state
  defp settle_health(state, health), do: %{state | health: health}

  defp exit_class(reason) when is_atom(reason), do: reason
  defp exit_class({exception, _stack}) when is_exception(exception), do: exception.__struct__

  defp exit_class(reason)
       when is_tuple(reason) and tuple_size(reason) > 0 and is_atom(elem(reason, 0)),
       do: elem(reason, 0)

  defp exit_class(_reason), do: :unknown

  defp usable_token(%{expires_at: expires_at} = token, now)
       when expires_at - now > @token_margin_s,
       do: token

  defp usable_token(_token, _now), do: nil

  # The batch process: a token, then each message in turn. It reports to the
  # server before it answers, so whatever the caller asks next (its next batch,
  # the status) already has this batch's token and outcome.
  defp run_batch(batch) do
    {reply, token, health} = batch_outcome(batch)
    send(batch.owner, {:batch_done, self(), token, health})
    GenServer.reply(batch.from, reply)
  end

  defp batch_outcome(batch) do
    case batch_token(batch) do
      {:ok, token} ->
        results = Enum.map(batch.messages, &send_message(&1, token, batch))
        {{:ok, results}, token_outcome(token, results), health(results)}

      {:error, class} ->
        Logger.warning("mobile FCM could not get an access token (#{inspect(class)})")
        {{:error, {:fcm_token_failed, class}}, :none, {:degraded, token_failure(class)}}
    end
  rescue
    error ->
      Logger.error(
        "mobile FCM batch raised:\n" <>
          Exception.format(:error, error, arity_only(__STACKTRACE__))
      )

      {{:error, {:push_dependency_exception, :fcm_batch, error.__struct__}}, :none, :unchanged}
  end

  defp batch_token(%{token: %{} = token}), do: {:ok, token}
  defp batch_token(batch), do: guarded(:fetch_token, fn -> batch.fetch_token.(batch.config) end)

  defp token_outcome(token, results) do
    if {:error, :unauthenticated} in results, do: {:refused, token}, else: {:kept, token}
  end

  # Google out of reach is not Google refusing the account.
  defp token_failure(:unreachable), do: :unreachable
  defp token_failure(_class), do: :auth_failed

  defp health(results) do
    cond do
      {:error, :unauthenticated} in results -> {:degraded, :auth_failed}
      Enum.all?(results, &(&1 == {:error, :unreachable})) -> {:degraded, :unreachable}
      true -> :ready
    end
  end

  defp send_message(message, token, batch) do
    request =
      Req.new(
        method: :post,
        url: "https://fcm.googleapis.com/v1/projects/#{batch.config.project_id}/messages:send",
        json: message,
        headers: [{"authorization", "Bearer " <> token.value}],
        receive_timeout: @request_timeout_ms,
        retry: false
      )

    case guarded(:request, fn -> batch.request.(request) end) do
      {:ok, %Req.Response{status: 200}} -> :ok
      {:ok, %Req.Response{} = response} -> {:error, error_class(response)}
      {:error, {:push_dependency_exception, _name, _class}} -> {:error, :dependency_failed}
      {:error, {:push_dependency_exit, _name, _reason}} -> {:error, :dependency_failed}
      {:error, _transport} -> {:error, :unreachable}
    end
  end

  defp error_class(%Req.Response{status: 401}), do: :unauthenticated
  defp error_class(%Req.Response{status: 403}), do: :permission_denied

  defp error_class(%Req.Response{status: status, body: body}) do
    case fcm_error_code(body) do
      nil when status == 404 -> :unregistered
      nil -> :rejected
      code -> code
    end
  end

  defp fcm_error_code(%{"error" => %{"details" => details}}) when is_list(details) do
    Enum.find_value(details, fn
      %{"errorCode" => code} -> Map.get(@error_codes, code)
      _detail -> nil
    end)
  end

  defp fcm_error_code(_body), do: nil

  defp fetch_token(config, request) do
    source = {:service_account, config.credentials, scopes: [@scope]}
    http = {&token_request(&1, request), []}

    case Goth.Token.fetch(%{source: source, http_client: http}) do
      {:ok, %Goth.Token{token: value, expires: expires_at}}
      when is_binary(value) and is_integer(expires_at) ->
        {:ok, %{value: value, expires_at: expires_at}}

      {:ok, _token} ->
        {:error, :rejected}

      {:error, %Req.TransportError{}} ->
        {:error, :unreachable}

      {:error, _reason} ->
        {:error, :rejected}
    end
  end

  # Goth's HTTP client contract: the token request goes out like every other,
  # through the shared pool and the proxy.
  defp token_request(options, request) do
    req =
      Req.new(
        method: Keyword.fetch!(options, :method),
        url: Keyword.fetch!(options, :url),
        headers: Keyword.fetch!(options, :headers),
        body: Keyword.fetch!(options, :body),
        receive_timeout: @token_timeout_ms,
        retry: false,
        decode_body: false
      )

    case request.(req) do
      {:ok, %Req.Response{status: status, headers: headers, body: body}} ->
        {:ok, %{status: status, headers: flat_headers(headers), body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp flat_headers(headers),
    do: for({name, values} <- headers, value <- List.wrap(values), do: {name, value})

  # A raising dependency is a defect or a vendor fault, and each says which:
  # the exception's class travels in the reason and its trace is logged with
  # frame arity only, since the frames' arguments carry tokens and messages.
  defp guarded(name, fun) do
    fun.()
  rescue
    error ->
      Logger.error(
        "mobile FCM dependency #{inspect(name)} raised:\n" <>
          Exception.format(:error, error, arity_only(__STACKTRACE__))
      )

      {:error, {:push_dependency_exception, name, error.__struct__}}
  catch
    :exit, reason -> {:error, {:push_dependency_exit, name, reason}}
  end

  defp arity_only(stacktrace) do
    Enum.map(stacktrace, fn
      {module, function, args, location} when is_list(args) ->
        {module, function, length(args), location}

      entry ->
        entry
    end)
  end

  defp call(server, request, timeout) do
    GenServer.call(server, request, timeout)
  catch
    :exit, reason -> {:error, {:push_dispatcher_unavailable, reason}}
  end

  defp fingerprint(config) do
    config
    |> Map.from_struct()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
  end
end
