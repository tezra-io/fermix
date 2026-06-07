defmodule FermixCore.Agents.BackgroundRunTest do
  use ExUnit.Case, async: true

  alias FermixCore.Agents.BackgroundRun

  # Stands in for MainAgent: `checkout_turn_state/2` is a `{:checkout_turn_state, msg}`
  # call that (like the real one) ignores the msg and returns the cached snapshot.
  defmodule StubMainAgent do
    use GenServer

    def start_link(reply), do: GenServer.start_link(__MODULE__, reply)

    @impl true
    def init(reply), do: {:ok, reply}

    @impl true
    def handle_call({:checkout_turn_state, _msg}, _from, reply), do: {:reply, reply, reply}
  end

  # Echoes the work-scoped message back through the response so the test can
  # assert isolation + trust, and reports the deliver closure's media handling.
  defmodule EchoRunner do
    def run(msg, _turn_state, deliver) do
      media = deliver.({:media, %{kind: :document}})

      {:ok,
       "channel=#{msg.channel} chat=#{msg.chat_id} trust=#{msg.source_trust} media=#{inspect(media)}",
       0}
    end
  end

  defmodule ErrorRunner do
    def run(_msg, _turn_state, _deliver), do: {:error, :loop_failed}
  end

  defp run(opts) do
    BackgroundRun.run(
      Map.merge(
        %{prompt: "summarize the news", work_id: "bg-abc", source_trust: :operator},
        Map.new(opts)
      )
    )
  end

  test "runs a work-scoped detached turn and returns the neutral result" do
    {:ok, main_agent} = StubMainAgent.start_link({:ok, %{snapshot: true}, :hit})

    assert {:ok, response} = run(main_agent: main_agent, turn_runner: EchoRunner)

    # work-scoped conversation identity (isolated from any foreground chat)
    assert response =~ "channel=background"
    assert response =~ "chat=bg-abc"
    # source_trust threaded through (never widened)
    assert response =~ "trust=operator"
    # no channel context: mid-turn media is rejected, not silently dropped
    assert response =~ "media={:error, :no_background_channel}"
  end

  test "guest trust is carried, not widened" do
    {:ok, main_agent} = StubMainAgent.start_link({:ok, %{}, :hit})

    assert {:ok, response} =
             run(main_agent: main_agent, turn_runner: EchoRunner, source_trust: :guest)

    assert response =~ "trust=guest"
  end

  test "surfaces a checkout failure" do
    {:ok, main_agent} = StubMainAgent.start_link({:error, :build_failed})

    assert {:error, :build_failed} = run(main_agent: main_agent, turn_runner: EchoRunner)
  end

  test "surfaces a runner error" do
    {:ok, main_agent} = StubMainAgent.start_link({:ok, %{}, :hit})

    assert {:error, :loop_failed} = run(main_agent: main_agent, turn_runner: ErrorRunner)
  end
end
