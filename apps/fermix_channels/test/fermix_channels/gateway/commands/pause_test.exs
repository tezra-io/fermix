defmodule FermixChannels.Gateway.Commands.PauseTest do
  # Not async: the in-flight case starts the globally named computer-use tree.
  use ExUnit.Case, async: false

  alias FermixChannels.Gateway.Authorization, as: IngressAuthorization
  alias FermixChannels.Gateway.Commands.Pause
  alias FermixChannels.Gateway.Commands.Resume
  alias FermixChannels.Gateway.Message
  alias FermixCore.ComputerUse.Config
  alias FermixCore.ComputerUse.Session
  alias FermixCore.ComputerUse.SessionManager
  alias FermixCore.ComputerUse.Supervisor, as: CuSupervisor

  # A driver whose action blocks until released, so `/pause` can be run while one
  # action is genuinely inside the helper — and which answers a control at once
  # from a separate call, as the real wire does (the helper's control reader is
  # not its action worker). Its ack names the request still under way, which is
  # exactly the fact `/pause` has to tell the human. Bounded, and no native code.
  defmodule BlockingDriver do
    @behaviour Compux.Driver

    @impl true
    def start(opts) do
      {:ok, in_flight} = Agent.start_link(fn -> nil end)
      {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid), in_flight: in_flight}}
    end

    @impl true
    def execute(_state, %{"action" => "probe"}), do: {:ok, %{"input_control" => true}}

    def execute(%{test_pid: pid, in_flight: in_flight}, request) do
      send(pid, {:driver_entered, request, self()})
      Agent.update(in_flight, fn _ -> "r-" <> request["action"] end)

      receive do
        :driver_release ->
          Agent.update(in_flight, fn _ -> nil end)
          {:ok, %{"ok" => true}}
      after
        5_000 -> {:error, :test_driver_never_released}
      end
    end

    @impl true
    def control(%{in_flight: in_flight}, action) do
      {:ok,
       %{
         action: action,
         ok: true,
         authorization_generation: 2,
         in_flight_request_id: Agent.get(in_flight, & &1)
       }}
    end

    @impl true
    def stop(_state), do: :ok
  end

  defp message,
    do:
      Message.new!(%{
        id: "m1",
        content: "",
        sender: "a",
        channel: "telegram",
        chat_id: "c1",
        reply_target: "c1"
      })

  defp reply_fn(pid), do: fn {:text, text} -> send(pid, {:reply, text}) end

  describe "metadata" do
    test "distinct triggers, no aliases" do
      assert Pause.name() == "pause"
      assert Resume.name() == "resume"
      assert Pause.aliases() == []
      assert Resume.aliases() == []
    end
  end

  describe "authorize/3 (owner-only)" do
    test "operator passes; missing authorization fails closed" do
      ctx = %{authorization: %IngressAuthorization{role: :operator, trust: :operator}}
      assert :ok = Pause.authorize(message(), %{}, ctx)
      assert :ok = Resume.authorize(message(), %{}, ctx)
      assert {:error, :unauthorized} = Pause.authorize(message(), %{}, %{})
      assert {:error, :unauthorized} = Resume.authorize(message(), %{}, %{})
    end
  end

  describe "execute/3 with no running session" do
    # Computer-use isn't running in this async test, so the facade reports
    # :no_session and the command replies with the friendly no-op copy.
    test "pause reports no active session" do
      ctx = %{conversation_key: {"telegram", "c1", :root}}
      assert :ok = Pause.execute(message(), reply_fn(self()), ctx)
      assert_receive {:reply, "No active computer-use session to pause."}
    end

    test "resume reports no paused session" do
      ctx = %{conversation_key: {"telegram", "c1", :root}}
      assert :ok = Resume.execute(message(), reply_fn(self()), ctx)
      assert_receive {:reply, "No paused computer-use session to resume."}
    end
  end

  describe "execute/3 with a running session" do
    setup do
      start_supervised!(CuSupervisor)
      key = {"telegram", "c-pause", :root}
      ctx = %{conversation_key: key, agent_name: "main", computer_use_origin: :interactive}

      {:ok, pid} =
        SessionManager.ensure(Config.normalize(enabled: true), ctx,
          driver: {BlockingDriver, [test_pid: self()]}
        )

      %{ctx: %{conversation_key: key}, session: pid}
    end

    test "an idle session hands the machine back immediately", %{ctx: ctx} do
      assert :ok = Pause.execute(message(), reply_fn(self()), ctx)

      assert_receive {:reply,
                      "Computer use paused — the cursor and keyboard are yours. Run /resume to let me continue."}
    end

    # The honest limit: an action already handed to the helper cannot be recalled,
    # so promising the cursor back this instant is a promise the human watches
    # break. The driver runs in the session's `ActionWorker`, so the pid the
    # double reports is that worker, and the release goes there.
    test "an action already under way is named, not glossed over", %{ctx: ctx, session: session} do
      action =
        Task.async(fn ->
          {:ok, :auto, request} = Session.classify(session, %{"action" => "screenshot"})
          Session.execute(session, request)
        end)

      assert_receive {:driver_entered, %{"action" => "screenshot"}, worker}, 1_000

      assert :ok = Pause.execute(message(), reply_fn(self()), ctx)

      assert_receive {:reply,
                      "Pausing. One action is already under way and will finish; nothing further will be sent. The cursor and keyboard are yours once it completes."}

      send(worker, :driver_release)
      assert {:ok, _result} = Task.await(action)
    end
  end
end
