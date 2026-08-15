defmodule FermixChannels.Gateway.Commands.BackgroundTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Gateway.Authorization, as: IngressAuthorization
  alias FermixChannels.Gateway.Commands.Background
  alias FermixChannels.Gateway.Commands.Tasks
  alias FermixChannels.Gateway.Message
  alias FermixChannels.Gateway.WorkRegistry

  defmodule FakeBackgroundRun do
    def run(%{prompt: prompt, source_trust: :operator}), do: {:ok, "summary of: " <> prompt}
  end

  defmodule FailingBackgroundRun do
    def run(_request), do: {:error, :checkout_unavailable}
  end

  # Stands in for a registry that is already at its running ceiling, so the
  # command's rendering of that refusal can be pinned without spawning the cap.
  defmodule StubRegistry do
    use GenServer

    def start_link(reply), do: GenServer.start_link(__MODULE__, reply)

    @impl true
    def init(reply), do: {:ok, reply}

    @impl true
    def handle_call({:start, _request}, _from, reply), do: {:reply, reply, reply}
  end

  setup do
    work_sup = start_supervised!({Task.Supervisor, []})

    registry =
      start_supervised!(
        {WorkRegistry,
         name: :"wr_#{System.unique_integer([:positive])}", work_supervisor: work_sup}
      )

    %{registry: registry}
  end

  defp message(content) do
    Message.new!(%{
      id: "m1",
      content: content,
      sender: "a",
      channel: "telegram",
      chat_id: "c1",
      reply_target: "c1",
      metadata: %{}
    })
  end

  defp reply_fn(pid), do: fn {:text, text} -> send(pid, {:reply, text}) end

  defp operator_context(registry, background_run \\ FakeBackgroundRun) do
    %{
      authorization: %IngressAuthorization{role: :operator, trust: :operator},
      conversation_key: {"telegram", "c1", :root},
      work_registry: registry,
      background_run: background_run
    }
  end

  defp deferred_context(registry, background_run \\ FakeBackgroundRun) do
    test_pid = self()

    operator_context(registry, background_run)
    |> Map.put(:defer_command_fn, fn ->
      send(test_pid, :command_deferred)
      fn outcome -> send(test_pid, {:command_terminal, outcome}) end
    end)
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end

  describe "Background.execute/3" do
    test "rejects a blank prompt with usage" do
      ctx = %{authorization: %IngressAuthorization{role: :operator, trust: :operator}}
      assert :ok = Background.execute(message(""), reply_fn(self()), ctx)
      assert_receive {:reply, "Usage: /background <prompt>"}
    end

    test "starts work, acks with a work id, and delivers the result", %{registry: registry} do
      assert :ok =
               Background.execute(
                 message("summarize the news"),
                 reply_fn(self()),
                 operator_context(registry)
               )

      # ack (sent by the command) and result (sent by the background task) race;
      # collect both and check order-independently.
      assert_receive {:reply, first}, 2_000
      assert_receive {:reply, second}, 2_000
      replies = [first, second]

      assert Enum.any?(replies, &(&1 =~ ~r/Started background work bg-\w+/))
      assert Enum.any?(replies, &(&1 =~ "summary of: summarize the news"))

      assert eventually(fn -> match?([%{command: "background"}], WorkRegistry.list(registry)) end)
    end

    test "defers before async work and settles only after the final reply", %{registry: registry} do
      assert :ok =
               Background.execute(
                 message("summarize the news"),
                 reply_fn(self()),
                 deferred_context(registry)
               )

      assert_receive :command_deferred
      assert_receive {:reply, first}, 2_000
      assert_receive {:reply, second}, 2_000

      final = Enum.find([first, second], &(&1 =~ "summary of: summarize the news"))
      assert is_binary(final)
      assert_receive {:command_terminal, :completed}
    end

    test "a failed async run settles failed after its final reply", %{registry: registry} do
      import ExUnit.CaptureLog

      capture_log(fn ->
        assert :ok =
                 Background.execute(
                   message("do it"),
                   reply_fn(self()),
                   deferred_context(registry, FailingBackgroundRun)
                 )

        assert_receive :command_deferred
        assert_receive {:reply, first}, 2_000
        assert_receive {:reply, second}, 2_000

        final = Enum.find([first, second], &(&1 =~ "failed: :checkout_unavailable"))
        assert is_binary(final)
        assert_receive {:command_terminal, {:failed, :checkout_unavailable}}
      end)
    end

    test "refusing at the running cap names the cap" do
      {:ok, registry} = StubRegistry.start_link({:error, {:max_running_work, 8}})

      assert :ok =
               Background.execute(message("another one"), reply_fn(self()), %{
                 authorization: %IngressAuthorization{role: :operator, trust: :operator},
                 work_registry: registry
               })

      assert_receive {:reply, text}
      assert text =~ "Too many background tasks already running (limit 8)"
    end

    # The running cap and every other start failure stay distinctly messaged.
    test "any other start failure keeps its own message" do
      {:ok, registry} = StubRegistry.start_link({:error, :missing_run})

      assert :ok =
               Background.execute(message("another one"), reply_fn(self()), %{
                 authorization: %IngressAuthorization{role: :operator, trust: :operator},
                 work_registry: registry
               })

      assert_receive {:reply, text}
      assert text == "Couldn't start background work: :missing_run"
    end

    test "a failed background run is recorded as :failed", %{registry: registry} do
      import ExUnit.CaptureLog

      capture_log(fn ->
        Background.execute(
          message("do it"),
          reply_fn(self()),
          operator_context(registry, FailingBackgroundRun)
        )

        assert_receive {:reply, _a}, 2_000
        assert_receive {:reply, _b}, 2_000

        scope = {"telegram", "c1", :root}

        assert eventually(fn ->
                 match?([%{status: :failed}], WorkRegistry.list(registry, scope))
               end)
      end)
    end
  end

  describe "Tasks.execute/3" do
    test "lists background work for the requesting conversation", %{registry: registry} do
      Background.execute(message("do a thing"), reply_fn(self()), operator_context(registry))
      assert_receive {:reply, _a}, 2_000
      assert_receive {:reply, _b}, 2_000

      ctx = %{work_registry: registry, conversation_key: {"telegram", "c1", :root}}
      assert :ok = Tasks.execute(message(""), reply_fn(self()), ctx)
      assert_receive {:reply, listing}
      assert listing =~ "Background work:"
      assert listing =~ "do a thing"
    end

    test "is scoped: a different conversation sees nothing", %{registry: registry} do
      Background.execute(
        message("conversation A work"),
        reply_fn(self()),
        operator_context(registry)
      )

      assert_receive {:reply, _a}, 2_000
      assert_receive {:reply, _b}, 2_000

      other = %{work_registry: registry, conversation_key: {"telegram", "OTHER", :root}}
      assert :ok = Tasks.execute(message(""), reply_fn(self()), other)
      assert_receive {:reply, "No background work."}
    end

    test "reports when there is no background work", %{registry: registry} do
      ctx = %{work_registry: registry, conversation_key: {"telegram", "c1", :root}}
      assert :ok = Tasks.execute(message(""), reply_fn(self()), ctx)
      assert_receive {:reply, "No background work."}
    end
  end
end
