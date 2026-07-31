defmodule FermixChannels.Gateway.Commands.StopTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Gateway.Authorization, as: IngressAuthorization
  alias FermixChannels.Gateway.Commands.Stop
  alias FermixChannels.Gateway.Message

  # Stands in for `Gateway.Queue` / `Harness.Manager` (`stop_all/1` is a
  # `:stop_all` call).
  defmodule StubQueue do
    use GenServer

    def start_link(counts), do: GenServer.start_link(__MODULE__, counts)

    @impl true
    def init(counts), do: {:ok, counts}

    @impl true
    def handle_call(:stop_all, _from, counts), do: {:reply, counts, counts}
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

  describe "authorize/3" do
    test "operator passes" do
      ctx = %{authorization: %IngressAuthorization{role: :operator, trust: :operator}}
      assert :ok = Stop.authorize(message(), %{}, ctx)
    end

    test "missing authorization fails closed (owner-only)" do
      assert {:error, :unauthorized} = Stop.authorize(message(), %{}, %{})
    end
  end

  describe "execute/3" do
    test "reports cancelled turns, cleared messages, background work, and coding runs" do
      {:ok, queue} = StubQueue.start_link(%{active_stopped: 1, pending_cleared: 2})
      {:ok, registry} = StubQueue.start_link(%{cancelled: 3})
      {:ok, harness} = StubQueue.start_link(%{cancelled: 2})

      assert :ok =
               Stop.execute(message(), reply_fn(self()), %{
                 agent_server: queue,
                 work_registry: registry,
                 harness_manager: harness
               })

      assert_receive {:reply, text}
      assert text =~ "cancelled 1 active turn"
      assert text =~ "cleared 2 queued messages"
      assert text =~ "stopped 3 background tasks"
      assert text =~ "cancelled 2 coding runs"
      assert text =~ "including any a scheduled job started"
      assert text =~ "Scheduled jobs themselves and voice are not affected"
    end

    test "reports nothing to stop when idle" do
      {:ok, queue} = StubQueue.start_link(%{active_stopped: 0, pending_cleared: 0})
      {:ok, registry} = StubQueue.start_link(%{cancelled: 0})
      {:ok, harness} = StubQueue.start_link(%{cancelled: 0})

      assert :ok =
               Stop.execute(message(), reply_fn(self()), %{
                 agent_server: queue,
                 work_registry: registry,
                 harness_manager: harness
               })

      assert_receive {:reply, "No active Fermix execution to stop."}
    end
  end
end
