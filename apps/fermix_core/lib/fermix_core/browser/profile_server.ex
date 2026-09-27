defmodule FermixCore.Browser.ProfileServer do
  @moduledoc """
  One `{owner, profile}` scope's browser, whichever backend drives it.

  This is the backend-neutral half of the browser surface
  (`FermixCore.Browser.Backend`): the process a conversation's browser lives
  in, and the rules that hold whatever browser is underneath.

  Lifecycle is lazy and self-bounded: the backend brings its runtime up on the
  first request that needs one, and the server self-stops after
  `idle_profile_ttl_ms` of inactivity. `terminate/2` hands the backend its
  teardown on every exit path (idle, eviction, shutdown, crash), so no browser
  is ever orphaned. A verb the profile's mode cannot do (`Capabilities`) is
  refused here, in the order a granted tab has always answered in, before the
  backend is asked to do it.

  Callers reach this process directly (via the registry); the manager only
  starts/evicts it. Requests are serialized per scope by the GenServer.
  """

  use GenServer

  alias FermixCore.Browser.Backend
  alias FermixCore.Browser.Capabilities
  alias FermixCore.Browser.Error
  alias FermixCore.Telemetry

  # Each tool action a backend answers, and the callback that answers it.
  @operations %{
    "open" => :open,
    "navigate" => :navigate,
    "snapshot" => :snapshot,
    "tabs" => :tabs,
    "focus" => :focus,
    "close" => :close,
    "screenshot" => :screenshot,
    "pdf" => :pdf,
    "console" => :console,
    "dialog" => :dialog,
    "cookies" => :cookies,
    "storage" => :storage,
    "upload" => :upload,
    "download" => :download,
    "act" => :act,
    "webmcp" => :webmcp
  }

  # The browser-wide verbs a mode may withhold, and the capability that
  # withholds each. `open` is refused before the backend runs anything; these
  # after its runtime is up, so a tab that was never granted says so before it
  # says what a granted one could not do.
  @gated %{
    "focus" => :focus_tab,
    "close" => :close_tab,
    "cookies" => :cookies,
    "download" => :downloads
  }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    case via(opts) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec status(GenServer.server()) :: map()
  def status(pid), do: GenServer.call(pid, :status)

  @spec request(GenServer.server(), map()) :: {:ok, map()} | {:error, Error.t()}
  def request(pid, request), do: GenServer.call(pid, {:request, request}, :infinity)

  @spec stop(GenServer.server(), timeout()) :: :ok
  def stop(pid, timeout) do
    GenServer.stop(pid, :normal, timeout)
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    profile = Keyword.fetch!(opts, :profile)
    mode = Map.get(profile, :mode)
    backend = Backend.for_mode(mode)

    state = %{
      profile_name: Keyword.fetch!(opts, :profile_name),
      # What this profile's browser can be asked to do, resolved once: the mode
      # never changes for the life of the server (§3.3).
      caps: Capabilities.for_mode(mode),
      config: Keyword.fetch!(opts, :config),
      registry: Keyword.get(opts, :registry),
      key: Keyword.get(opts, :key),
      now_fn: Keyword.get(opts, :now_fn, fn -> System.monotonic_time(:millisecond) end),
      backend: backend,
      backend_state: backend.init(opts),
      idle_ref: nil
    }

    {:ok, schedule_idle(state)}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, status_map(state), state}

  def handle_call({:request, request}, _from, state) do
    {reply, state} = run_request(request, touch_idle(state))
    {:reply, attach_console(reply, state), state}
  end

  # A failed action carries the recent console/JS-exception buffer (oldest
  # first, same order as the explicit `console` action) in its error details —
  # page-side context is often the only clue to why a click/fill/navigate
  # failed. Gated behind content capture so regular error details stay
  # body-free. Entry COUNT is capped by `console_buffer_limit`; entry size is
  # not — capture-on is full-fidelity by design.
  defp attach_console({:error, %Error{} = error}, state) do
    case state.backend.console_buffer(state.backend_state) do
      [_ | _] = console -> {:error, with_console(error, console)}
      [] -> {:error, error}
    end
  end

  defp attach_console(reply, _state), do: reply

  defp with_console(error, console) do
    if Telemetry.capture_content?(),
      do: %{error | details: Map.put(error.details, "console", Enum.reverse(console))},
      else: error
  end

  @impl true
  def handle_info(:idle_timeout, state), do: {:stop, :normal, state}

  # Everything else is the runtime talking — events, port output, a transport's
  # exit — and only the backend knows what it means.
  def handle_info(message, state) do
    {:noreply, put_backend(state, state.backend.handle_message(message, state.backend_state))}
  end

  @impl true
  def terminate(_reason, state) do
    state.backend.stop(state.backend_state)
    :ok
  end

  defp run_request(%{action: "status"}, state), do: {{:ok, status_map(state)}, state}

  defp run_request(%{action: "stop"}, state) do
    {{:ok, %{"ok" => true, "stopped" => true}},
     put_backend(state, state.backend.stop(state.backend_state))}
  end

  defp run_request(%{action: "start", context: context}, state) do
    case start_backend(context, state) do
      {:ok, state} -> {{:ok, status_map(state)}, state}
      {:error, error, state} -> {{:error, error}, state}
    end
  end

  defp run_request(%{action: "open"}, %{caps: %{new_tab: false}} = state) do
    {Capabilities.refuse(:new_tab), state}
  end

  defp run_request(%{action: action} = request, state) when is_map_key(@gated, action) do
    capability = Map.fetch!(@gated, action)

    if Map.fetch!(state.caps, capability),
      do: operate(request, state),
      else: refuse_started(capability, request.context, state)
  end

  defp run_request(%{action: action} = request, state) when is_map_key(@operations, action) do
    operate(request, state)
  end

  defp operate(%{action: action, args: args, context: context}, state) do
    callback = Map.fetch!(@operations, action)

    case apply(state.backend, callback, [args, context, state.backend_state]) do
      {:ok, result, backend_state} ->
        {{:ok, result}, put_backend(state, backend_state)}

      {:error, %Error{} = error, backend_state} ->
        {{:error, error}, put_backend(state, backend_state)}
    end
  end

  defp refuse_started(capability, context, state) do
    case start_backend(context, state) do
      {:ok, state} -> {Capabilities.refuse(capability), state}
      {:error, error, state} -> {{:error, error}, state}
    end
  end

  defp start_backend(context, state) do
    case state.backend.start(context, state.backend_state) do
      {:ok, backend_state} ->
        {:ok, put_backend(state, backend_state)}

      {:error, %Error{} = error, backend_state} ->
        {:error, error, put_backend(state, backend_state)}
    end
  end

  defp put_backend(state, backend_state), do: %{state | backend_state: backend_state}

  defp status_map(state) do
    Map.merge(
      state.backend.status(state.backend_state),
      %{"ok" => true, "profile" => state.profile_name}
    )
  end

  defp schedule_idle(%{idle_ref: ref} = state) do
    if is_reference(ref), do: Process.cancel_timer(ref)
    new_ref = Process.send_after(self(), :idle_timeout, state.config.idle_profile_ttl_ms)
    %{state | idle_ref: new_ref}
  end

  defp touch_idle(state) do
    state |> touch_registry() |> schedule_idle()
  end

  defp touch_registry(%{registry: nil} = state), do: state
  defp touch_registry(%{key: nil} = state), do: state

  defp touch_registry(%{registry: registry, key: key, now_fn: now} = state) do
    Registry.update_value(registry, key, fn _old -> now.() end)
    state
  end

  defp via(opts) do
    case {Keyword.get(opts, :registry), Keyword.get(opts, :key)} do
      {registry, key} when not is_nil(registry) and not is_nil(key) ->
        {:via, Registry, {registry, key, System.monotonic_time(:millisecond)}}

      _other ->
        nil
    end
  end
end
