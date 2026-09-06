defmodule FermixChannels.Mobile.Push.PigeonDispatcher do
  @moduledoc false

  use GenServer

  @behaviour FermixChannels.Mobile.Push.Dispatcher

  require Logger

  alias FermixChannels.Mobile.Push.Config
  alias Pigeon.APNS.Notification

  @max_notifications 64
  @shutdown_timeout_ms 5_000
  @call_slack_ms 1_000

  @type dependency_opts :: [
          start_dispatcher: (Config.t() -> {:ok, term()} | {:error, term()}),
          push: (term(), [Notification.t()], pos_integer() ->
                   {:ok, [Notification.t()]} | {:error, term()}),
          stop_dispatcher: (term() -> :ok | {:error, term()})
        ]

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
      restart: :transient,
      shutdown: @shutdown_timeout_ms + @call_slack_ms
    }
  end

  @impl FermixChannels.Mobile.Push.Dispatcher
  @spec dispatch([Notification.t()], Config.t()) ::
          {:ok, [Notification.t()]} | {:error, term()}
  def dispatch(notifications, %Config{} = config) do
    dispatch(__MODULE__, notifications, config)
  end

  @doc false
  @spec dispatch(GenServer.server(), [Notification.t()], Config.t()) ::
          {:ok, [Notification.t()]} | {:error, term()}
  def dispatch(server, notifications, %Config{enabled: true} = config)
      when is_list(notifications) and length(notifications) <= @max_notifications do
    timeout = max(@call_slack_ms, length(notifications) * config.timeout_ms + @call_slack_ms)
    call(server, {:dispatch, notifications, config_fingerprint(config)}, timeout)
  end

  def dispatch(_server, notifications, %Config{}) when is_list(notifications),
    do: {:error, {:invalid_dispatch_count, length(notifications), @max_notifications}}

  @impl true
  def init(opts) do
    with {:ok, config} <- fetch_config(opts),
         {:ok, dispatcher} <- start_dispatcher(config, opts) do
      {:ok,
       %{
         dispatcher: dispatcher,
         config_fingerprint: config_fingerprint(config),
         timeout_ms: config.timeout_ms,
         push: Keyword.get(opts, :push, &push_all/3),
         stop_dispatcher: Keyword.get(opts, :stop_dispatcher, &stop_dispatcher/1)
       }}
    else
      {:error, reason} -> {:stop, {:push_dispatcher_start_failed, reason}}
    end
  end

  @impl true
  def handle_call({:dispatch, _notifications, fingerprint}, _from, state)
      when fingerprint != state.config_fingerprint do
    {:reply, {:error, :push_dispatcher_config_mismatch}, state}
  end

  def handle_call({:dispatch, notifications, _fingerprint}, _from, state) do
    result =
      call_dependency(:push, state.push, [state.dispatcher, notifications, state.timeout_ms])

    {:reply, result, state}
  end

  @impl true
  def terminate(_reason, state) do
    case call_dependency(:stop_dispatcher, state.stop_dispatcher, [state.dispatcher]) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("mobile APNs dispatcher shutdown failed: #{inspect(reason)}")
    end
  end

  defp fetch_config(opts) do
    case Keyword.fetch(opts, :config) do
      {:ok, %Config{enabled: true} = config} -> {:ok, config}
      {:ok, values} -> enabled_config(values)
      :error -> {:error, :missing_push_config}
    end
  end

  defp enabled_config(values) do
    with {:ok, %Config{enabled: true} = config} <- Config.new(values) do
      {:ok, config}
    else
      {:ok, %Config{enabled: false}} -> {:error, :push_disabled}
      {:error, _reason} = error -> error
    end
  end

  defp start_dispatcher(config, opts) do
    callback = Keyword.get(opts, :start_dispatcher, &start_pigeon_dispatcher/1)
    call_dependency(:start_dispatcher, callback, [config])
  end

  defp start_pigeon_dispatcher(config) do
    Pigeon.Dispatcher.start_link(
      adapter: Pigeon.APNS,
      key: config.key,
      key_identifier: config.key_id,
      team_id: config.team_id,
      mode: Config.pigeon_mode(config),
      pool_size: 1
    )
  end

  defp push_all(dispatcher, notifications, timeout_ms) do
    {:ok, Pigeon.push(dispatcher, notifications, timeout: timeout_ms)}
  end

  defp stop_dispatcher(dispatcher) do
    Supervisor.stop(dispatcher, :normal, @shutdown_timeout_ms)
  end

  defp call(server, request, timeout) do
    GenServer.call(server, request, timeout)
  catch
    :exit, reason -> {:error, {:push_dispatcher_unavailable, reason}}
  end

  # Same contract as `FermixChannels.Mobile.Push.call_dependency/3`: the
  # exception class travels in the reason and the trace is logged, so a Fermix
  # defect stops reading as an APNs hiccup. Stack frame arguments are dropped
  # before formatting — they carry the notification list, whose device tokens and
  # encrypted payloads must never reach a log line.
  defp call_dependency(name, callback, args) when is_function(callback, length(args)) do
    apply(callback, args)
  rescue
    error ->
      Logger.error(
        "mobile push dependency #{inspect(name)} raised:\n" <>
          Exception.format(:error, error, arity_only(__STACKTRACE__))
      )

      {:error, {:push_dependency_exception, name, error.__struct__, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:push_dependency_exit, name, reason}}
  end

  defp call_dependency(name, callback, _args),
    do: {:error, {:invalid_push_dependency, name, callback}}

  defp arity_only(stacktrace) do
    Enum.map(stacktrace, fn
      {module, function, args, location} when is_list(args) ->
        {module, function, length(args), location}

      entry ->
        entry
    end)
  end

  defp config_fingerprint(config) do
    config
    |> Map.from_struct()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
  end
end
