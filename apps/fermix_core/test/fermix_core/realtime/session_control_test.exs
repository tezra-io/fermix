defmodule FermixCore.Realtime.SessionControlTest do
  @moduledoc """
  `SessionControl` is the one client API the listener, the session supervisor
  and the chat use for every engine's session process, so the thing under test
  is the exact set of GenServer messages it sends: `SessionServer`,
  `LiveSessionServer` and `GrokSessionServer` are written against that list, and
  a drift here silently breaks one of them.
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
    defp reply_for(:call_context), do: {:ok, %{call_uuid: "3f2b8c1e-5a4d-4e6f-9b8a-7c6d5e4f3a2b"}}
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

  test "playback_progress carries the id, the played milliseconds and the drain flag", %{
    session: session
  } do
    assert :ok = SessionControl.playback_progress(session, "p17", 420, false)
    assert_receive {:called, {:playback_progress, "p17", 420, false}}

    assert :ok = SessionControl.playback_progress(session, "p17", 870, true)
    assert_receive {:called, {:playback_progress, "p17", 870, true}}
  end

  # The task engines' chat API (M56 §4.3, §4.4), one place for Live and Grok.
  test "chat_typed is a cast of what the owner typed", %{session: session} do
    assert :ok = SessionControl.chat_typed(session, "use https://x.test/lease")
    assert_receive {:cast, {:chat, {:typed, "use https://x.test/lease"}}}
  end

  test "chat_answered is a cast of the chat's answer", %{session: session} do
    answer = %{role: "assistant", content: "Saved the lease.", metadata: %{}}

    assert :ok = SessionControl.chat_answered(session, answer)
    assert_receive {:cast, {:chat, {:answered, ^answer}}}
  end

  test "call_context asks the session and returns its answer", %{session: session} do
    assert {:ok, %{call_uuid: "3f2b8c1e-5a4d-4e6f-9b8a-7c6d5e4f3a2b"}} =
             SessionControl.call_context(session, 1_000)

    assert_receive {:called, :call_context}
  end

  test "every verb refuses an argument the session contract does not allow", %{session: session} do
    assert_raise FunctionClauseError, fn -> SessionControl.audio_chunk(session, :not_binary) end
    assert_raise FunctionClauseError, fn -> SessionControl.interrupt(session, -1) end
    assert_raise FunctionClauseError, fn -> SessionControl.mute(session, "yes") end
    assert_raise FunctionClauseError, fn -> SessionControl.cancel_task(session, "") end

    assert_raise FunctionClauseError, fn ->
      SessionControl.playback_progress(session, "", 0, true)
    end

    assert_raise FunctionClauseError, fn ->
      SessionControl.playback_progress(session, "p1", -1, true)
    end

    assert_raise FunctionClauseError, fn ->
      SessionControl.playback_progress(session, "p1", 0, "yes")
    end

    assert_raise FunctionClauseError, fn -> SessionControl.chat_typed(session, :not_binary) end

    assert_raise FunctionClauseError, fn ->
      SessionControl.chat_answered(session, %{role: "user", content: "hello"})
    end

    assert_raise FunctionClauseError, fn -> SessionControl.call_context(session, -1) end
  end

  test "engine_module names the engine's session module" do
    assert SessionControl.engine_module(Config.normalize(engine: "openai_realtime")) ==
             SessionServer

    assert SessionControl.engine_module(Config.normalize(engine: "openai_live")) ==
             FermixCore.Realtime.LiveSessionServer

    assert SessionControl.engine_module(Config.normalize(engine: "xai_realtime")) ==
             FermixCore.Realtime.GrokSessionServer
  end

  # Grok runs under the Live run kind: both are task engines, and the trace's
  # `engine` metadata tells them apart.
  test "session_scope is engine-scoped so a task-engine call is recognisable in a trace" do
    realtime = SessionControl.session_scope(Config.normalize(engine: "openai_realtime"))
    live = SessionControl.session_scope(Config.normalize(engine: "openai_live"))
    grok = SessionControl.session_scope(Config.normalize(engine: "xai_realtime"))

    assert "session:" <> realtime_id = realtime
    assert "voice_live:" <> live_id = live
    assert "voice_live:" <> grok_id = grok
    assert Integer.parse(realtime_id) != :error
    assert Integer.parse(live_id) != :error
    assert Integer.parse(grok_id) != :error
  end

  test "session_scope never repeats within one daemon" do
    config = Config.normalize([])
    scopes = Enum.map(1..50, fn _index -> SessionControl.session_scope(config) end)

    assert length(Enum.uniq(scopes)) == 50
  end
end
