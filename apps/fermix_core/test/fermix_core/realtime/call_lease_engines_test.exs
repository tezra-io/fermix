defmodule FermixCore.Realtime.CallLeaseEnginesTest do
  @moduledoc """
  One owner-voice call per home across the engines: every engine session takes
  the one `CallLease` from its own `init/1`, OpenAI Realtime's included, so a
  second call is refused before a second paid session exists, and the refusal
  names the endpoint that holds the call.
  """

  use ExUnit.Case, async: false

  alias FermixCore.Realtime.CallLease
  alias FermixCore.Realtime.CallRegistry
  alias FermixCore.Realtime.Config
  alias FermixCore.Realtime.LiveSessionServer
  alias FermixCore.Realtime.SessionServer
  alias FermixCore.Realtime.SessionSupervisor

  @robot {:accessory, "desk-robot"}

  # A provider socket that takes `session.start` and never answers.
  defmodule QuietLiveClient do
    def start_link(_opts), do: Agent.start(fn -> :quiet end)
    def send_event(_pid, _event), do: :ok
    def close(pid), do: Agent.stop(pid)
  end

  # Never reached: a call whose provider never starts opens no bridge call.
  defmodule QuietBridge do
    @behaviour FermixCore.Realtime.VoiceBridge

    @impl true
    def conversation_window(_bounds), do: {:ok, %{messages: [], gists: []}}
    @impl true
    def call_active?, do: false
    @impl true
    def chat_call(_key, _channel), do: :none
    @impl true
    def show(_call, _text), do: {:error, :not_in_this_test}
    @impl true
    def open_call(_call), do: {:error, :not_in_this_test}
    @impl true
    def submit(_handle, _request, _callbacks), do: {:error, :not_in_this_test}
    @impl true
    def cancel(_handle, _ref), do: :ok
    @impl true
    def close_call(_handle), do: :ok
    @impl true
    def detach(_handle, _task_ref, _task), do: {:error, :no_owner}
  end

  setup do
    unique = System.unique_integer([:positive])
    lease = :"engines_lease_#{unique}"
    registry = :"engines_calls_#{unique}"
    start_supervised!({CallLease, name: lease})
    start_supervised!({CallRegistry, name: registry})
    sessions = start_supervised!({SessionSupervisor, name: :"engines_sessions_#{unique}"})
    %{lease: lease, registry: registry, sessions: sessions}
  end

  test "a Realtime session is refused while another Realtime session holds the call", ctx do
    {:ok, first} = start_realtime(ctx, @robot)

    assert start_realtime(ctx, :desktop) == {:error, {:call_in_progress, "accessory:desk-robot"}}

    assert {:ok, %{endpoint: "accessory:desk-robot", engine: "openai_realtime"}} =
             CallLease.holder(ctx.lease)

    assert Process.alive?(first)
    assert SessionSupervisor.active_sessions(ctx.sessions) == 1
  end

  test "a Realtime session is refused while a Live call holds it, and starts once it ends", ctx do
    {:ok, live} = start_live(ctx, @robot)

    assert start_realtime(ctx, :desktop) == {:error, {:call_in_progress, "accessory:desk-robot"}}
    assert {:ok, %{session: ^live}} = CallRegistry.active(ctx.registry)

    stop_session(live)
    assert {:ok, _realtime} = start_realtime(ctx, :desktop)
    assert {:ok, %{endpoint: "desktop", engine: "openai_realtime"}} = CallLease.holder(ctx.lease)
  end

  test "a Live session is refused while a Realtime session holds the call", ctx do
    {:ok, _realtime} = start_realtime(ctx, :desktop)

    assert start_live(ctx, @robot) == {:error, {:call_in_progress, "desktop"}}
    # The refused Live session took no chat context either.
    assert CallRegistry.active(ctx.registry) == :none
  end

  # Two endpoints pressing "call" at once: exactly one session exists after.
  test "of concurrent starts, exactly one session exists", ctx do
    endpoints = [:desktop, @robot, {:accessory, "hall-robot"}, :desktop]

    results =
      endpoints
      |> Enum.map(fn endpoint -> Task.async(fn -> start_realtime(ctx, endpoint) end) end)
      |> Task.await_many(10_000)

    assert [{:ok, _winner}] = Enum.filter(results, &match?({:ok, _pid}, &1))
    {:ok, %{endpoint: held_by}} = CallLease.holder(ctx.lease)
    assert Enum.count(results, &(&1 == {:error, {:call_in_progress, held_by}})) == 3
    assert SessionSupervisor.active_sessions(ctx.sessions) == 1
  end

  test "a crashed session releases the call for the next one", ctx do
    {:ok, first} = start_realtime(ctx, @robot)
    ref = Process.monitor(first)
    Process.exit(first, :kill)
    assert_receive {:DOWN, ^ref, :process, ^first, :killed}

    assert {:ok, _second} = start_realtime(ctx, :desktop)
    assert {:ok, %{endpoint: "desktop"}} = CallLease.holder(ctx.lease)
  end

  test "a session is never started without an endpoint", ctx do
    opts = ctx |> realtime_opts(:desktop) |> Keyword.delete(:endpoint)

    assert {:error, {%KeyError{key: :endpoint}, _stacktrace}} =
             SessionSupervisor.start_session(ctx.sessions, opts)

    assert CallLease.holder(ctx.lease) == :none
  end

  defp start_realtime(ctx, endpoint),
    do: SessionSupervisor.start_session(ctx.sessions, realtime_opts(ctx, endpoint))

  defp realtime_opts(ctx, endpoint) do
    [
      engine_module: SessionServer,
      companion: self(),
      endpoint: endpoint,
      call_lease: ctx.lease,
      config: Config.normalize(enabled: true),
      capabilities: [],
      prompt_loader: fn _opts -> {:ok, %{messages: [], parts: [], accounting: []}} end
    ]
  end

  defp start_live(ctx, endpoint) do
    SessionSupervisor.start_session(ctx.sessions,
      engine_module: LiveSessionServer,
      companion: self(),
      endpoint: endpoint,
      call_lease: ctx.lease,
      call_registry: ctx.registry,
      config: Config.normalize(enabled: true, engine: "openai_live", model: "gpt-live-1"),
      api_key: "sk-test",
      live_client: QuietLiveClient,
      voice_bridge: QuietBridge,
      prompt: "# LIVE.md",
      close_deadline_ms: 10
    )
  end

  defp stop_session(session) do
    ref = Process.monitor(session)
    GenServer.stop(session, :normal, 10_000)
    assert_receive {:DOWN, ^ref, :process, ^session, _reason}
  end
end
