defmodule FermixCore.Realtime.SessionControlTest do
  @moduledoc """
  `SessionControl` is the one client API the listener and the session supervisor
  use for either engine's session process, so the thing under test is the exact
  set of GenServer messages it sends: both `SessionServer` and (later)
  `LiveSessionServer` are written against that list, and a drift here silently
  breaks one of them.
  """

  use ExUnit.Case, async: true

  alias FermixCore.Realtime.Config
  alias FermixCore.Realtime.SessionControl
  alias FermixCore.Realtime.SessionServer

  defmodule EchoSession do
    @moduledoc false
    use GenServer

    def start_link(owner) when is_pid(owner), do: GenServer.start_link(__MODULE__, owner)

    @impl true
    def init(owner), do: {:ok, owner}

    @impl true
    def handle_call(message, _from, owner) do
      send(owner, {:called, message})
      {:reply, reply_for(message), owner}
    end

    @impl true
    def handle_cast(message, owner) do
      send(owner, {:cast, message})
      {:noreply, owner}
    end

    defp reply_for(:reload_runtime), do: {:ok, %{tools: 0, applies: :next_call}}
    defp reply_for(_message), do: :ok
  end

  setup do
    {:ok, session} = EchoSession.start_link(self())
    %{session: session}
  end

  test "call_start sends :call_start", %{session: session} do
    assert :ok = SessionControl.call_start(session)
    assert_receive {:called, :call_start}
  end

  test "audio_chunk is a cast so a busy session never blocks the socket reader", %{
    session: session
  } do
    assert :ok = SessionControl.audio_chunk(session, "pcm")
    assert_receive {:cast, {:audio_chunk, "pcm"}}
  end

  test "interrupt carries the played milliseconds, defaulting to nil", %{session: session} do
    assert :ok = SessionControl.interrupt(session)
    assert_receive {:called, {:interrupt, nil}}

    assert :ok = SessionControl.interrupt(session, 1_750)
    assert_receive {:called, {:interrupt, 1_750}}
  end

  test "mute carries the boolean gate", %{session: session} do
    assert :ok = SessionControl.mute(session, true)
    assert_receive {:called, {:mute, true}}
  end

  test "cancel_task carries the delegation id", %{session: session} do
    assert :ok = SessionControl.cancel_task(session, "dg_1")
    assert_receive {:called, {:cancel_task, "dg_1"}}
  end

  test "call_stop sends :call_stop", %{session: session} do
    assert :ok = SessionControl.call_stop(session)
    assert_receive {:called, :call_stop}
  end

  test "reload_runtime sends :reload_runtime and returns the session's summary", %{
    session: session
  } do
    assert {:ok, %{tools: 0, applies: :next_call}} = SessionControl.reload_runtime(session)
    assert_receive {:called, :reload_runtime}
  end

  test "every verb refuses an argument the session contract does not allow", %{session: session} do
    assert_raise FunctionClauseError, fn -> SessionControl.audio_chunk(session, :not_binary) end
    assert_raise FunctionClauseError, fn -> SessionControl.interrupt(session, -1) end
    assert_raise FunctionClauseError, fn -> SessionControl.mute(session, "yes") end
    assert_raise FunctionClauseError, fn -> SessionControl.cancel_task(session, "") end
  end

  test "engine_module names the engine's session module" do
    assert SessionControl.engine_module(Config.normalize(engine: "openai_realtime")) ==
             SessionServer

    assert SessionControl.engine_module(Config.normalize(engine: "openai_live")) ==
             FermixCore.Realtime.LiveSessionServer
  end

  test "session_scope is engine-scoped so a Live call is recognisable in a trace" do
    realtime = SessionControl.session_scope(Config.normalize(engine: "openai_realtime"))
    live = SessionControl.session_scope(Config.normalize(engine: "openai_live"))

    assert "session:" <> realtime_id = realtime
    assert "voice_live:" <> live_id = live
    assert Integer.parse(realtime_id) != :error
    assert Integer.parse(live_id) != :error
  end

  test "session_scope never repeats within one daemon" do
    config = Config.normalize([])
    scopes = Enum.map(1..50, fn _index -> SessionControl.session_scope(config) end)

    assert length(Enum.uniq(scopes)) == 50
  end
end
