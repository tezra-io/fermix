defmodule FermixChannels.SignalTest do
  use ExUnit.Case, async: false

  alias FermixChannels.Signal
  alias FermixChannels.Signal.Listener
  alias FermixCore.Agents.MainAgent
  alias FermixCore.Memory.ConversationStore

  defmodule CapturingAgent do
    def handle_message(message, test_pid) do
      send(test_pid, {:agent_message, message})
      :ok
    end
  end

  defmodule StaticProvider do
    @behaviour FermixCore.Providers.Provider

    @impl true
    def chat(_messages, _opts) do
      {:ok,
       %{
         content: "reply from main agent",
         tool_calls: [],
         usage: %{prompt_tokens: 1, completion_tokens: 1, total_tokens: 2}
       }}
    end

    @impl true
    def models, do: {:ok, ["mock-model"]}
  end

  defmodule FakeSignalClient do
    def receive_messages(opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, :signal_receive_called)
      {:ok, Keyword.get(opts, :receive_messages, [])}
    end

    def send_message(account, recipient, text, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:signal_send, account, recipient, text})
      :ok
    end
  end

  setup do
    Application.put_env(:fermix_channels, :signal,
      enabled: true,
      mode: :subprocess,
      account: "+15550001111",
      allowed_sender_ids: []
    )

    on_exit(fn -> Application.delete_env(:fermix_channels, :signal) end)

    :ok
  end

  describe "listener receive loop" do
    test "normalizes direct receive events, dispatches them, and replies through the client" do
      listener =
        start_supervised!(
          {Listener,
           [
             name: :"signal_listener_#{System.unique_integer([:positive])}",
             poll_interval: :manual,
             agent: CapturingAgent,
             agent_server: self(),
             client: FakeSignalClient,
             client_opts: [test_pid: self(), receive_messages: [receive_event("hello signal")]]
           ]}
        )

      send(listener, :poll)

      assert_receive :signal_receive_called
      assert_receive {:agent_message, agent_message}
      assert agent_message.content == "hello signal"
      assert agent_message.channel == "signal"
      assert agent_message.chat_id == "+15551234567"
      assert agent_message.reply_target == "+15551234567"
      assert :ok = agent_message.reply_fn.("reply from fermix")
      assert_receive {:signal_send, "+15550001111", "+15551234567", "reply from fermix"}
    end

    test "routes received messages through MainAgent and sends the agent reply" do
      test_pid = self()
      agent_name = :"signal_main_agent_#{System.unique_integer([:positive])}"
      store_name = :"signal_conversation_store_#{System.unique_integer([:positive])}"

      conversation_store = start_supervised!({ConversationStore, [name: store_name]})

      agent =
        start_supervised!(
          {MainAgent,
           [
             name: agent_name,
             provider: StaticProvider,
             conversation_store: conversation_store
           ]}
        )

      listener =
        start_supervised!(
          {Listener,
           [
             name: :"signal_listener_#{System.unique_integer([:positive])}",
             poll_interval: :manual,
             agent: MainAgent,
             agent_server: agent,
             client: FakeSignalClient,
             client_opts: [
               test_pid: test_pid,
               receive_messages: [receive_event("hello main agent")]
             ]
           ]}
        )

      send(listener, :poll)

      assert_receive {:signal_send, "+15550001111", "+15551234567", "reply from main agent"},
                     5_000
    end
  end

  describe "send_message/3" do
    test "rejects missing signal account configuration" do
      Application.put_env(:fermix_channels, :signal, enabled: true)

      assert {:error, :not_configured} = Signal.send_message("+15551234567", "hello")
    end
  end

  defp receive_event(text) do
    %{
      "envelope" => %{
        "sourceNumber" => "+15551234567",
        "sourceName" => "Alice",
        "timestamp" => 1_714_000_000_000,
        "dataMessage" => %{
          "timestamp" => 1_714_000_000_000,
          "message" => text
        }
      }
    }
  end
end
