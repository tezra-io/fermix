defmodule FermixTestSupport.AccessoryEngine do
  @moduledoc """
  A voice engine session double for the accessory call tests, in the shape
  `FermixCore.Realtime.CallClient` drives (`SessionControl`'s verbs). It takes
  the home's one call lease from `init/1` as every engine does, so two
  endpoints starting at once get exactly one session; `call_start` says
  `listening` as the engines do once a call is accepted; every verb is told
  to the observer as `{:engine, session, verb}`; `call_stop` ends it; and the
  test speaks as the engine through `emit/2`.

  `starter/2` is the `session_starter` a test hands the call: it tells the
  observer `{:engine_started, session, opts}` for every session it made.
  """

  use GenServer

  alias FermixCore.Realtime.CallLease

  @doc "A starter for `CallClient` that makes one of these per call."
  def starter(observer, opts \\ []) do
    lease = Keyword.get(opts, :lease)
    engine = Keyword.get(opts, :engine, "openai_realtime")

    fn session_opts ->
      spec = %{observer: observer, opts: session_opts, lease: lease, engine: engine}

      with {:ok, pid} <- GenServer.start(__MODULE__, spec) do
        send(observer, {:engine_started, pid, session_opts})
        {:ok, pid}
      end
    end
  end

  @doc "The engine sends its companion (the call) one frame."
  def emit(session, event), do: GenServer.call(session, {:emit, event})

  def call_start(pid), do: GenServer.call(pid, :call_start)
  def call_stop(pid), do: GenServer.call(pid, :call_stop)
  def audio_chunk(pid, audio), do: GenServer.call(pid, {:verb, {:audio, audio}})
  def interrupt(pid, played_ms), do: GenServer.call(pid, {:verb, {:interrupt, played_ms}})
  def mute(pid, muted?), do: GenServer.call(pid, {:verb, {:mute, muted?}})
  def cancel_task(pid, id), do: GenServer.call(pid, {:verb, {:cancel_task, id}})

  def playback_progress(pid, id, played_ms, drained?),
    do: GenServer.call(pid, {:verb, {:playback_progress, id, played_ms, drained?}})

  @impl true
  def init(%{observer: observer, opts: opts, lease: lease} = spec) do
    Process.monitor(observer)

    case take_lease(lease, Keyword.fetch!(opts, :endpoint), spec.engine) do
      :ok -> {:ok, spec}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:call_start, _from, state) do
    send(companion(state), {:realtime, %{type: "state", state: "listening"}})
    {:reply, :ok, state}
  end

  def handle_call(:call_stop, _from, state) do
    send(state.observer, {:engine, self(), :call_stop})
    {:stop, :normal, :ok, state}
  end

  def handle_call({:verb, verb}, _from, state) do
    send(state.observer, {:engine, self(), verb})
    {:reply, :ok, state}
  end

  def handle_call({:emit, event}, _from, state) do
    send(companion(state), {:realtime, event})
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, observer, _reason}, %{observer: observer} = state),
    do: {:stop, :normal, state}

  defp companion(state), do: Keyword.fetch!(state.opts, :companion)

  defp take_lease(nil, _endpoint, _engine), do: :ok
  defp take_lease(lease, endpoint, engine), do: CallLease.acquire(lease, endpoint, engine)
end
