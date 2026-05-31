defmodule FermixChannels.Channels.SignalTest do
  use ExUnit.Case, async: false

  alias FermixChannels.Channels.Signal
  alias FermixChannels.Channels.Signal.Listener
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
    @behaviour FermixCore.Providers.Adapter

    @impl FermixCore.Providers.Provider
    def chat(_messages, _opts), do: {:ok, response()}

    @impl FermixCore.Providers.Provider
    def models, do: {:ok, ["mock-model"]}

    @impl FermixCore.Providers.Adapter
    def chat(_messages, _capabilities, _opts), do: {:ok, turn()}

    @impl FermixCore.Providers.Adapter
    def continue(_provider_state, _tool_results, _opts), do: {:ok, turn()}

    @impl FermixCore.Providers.Adapter
    def to_provider_tools(capabilities), do: capabilities

    @impl FermixCore.Providers.Adapter
    def parse_tool_calls(_response), do: []

    @impl FermixCore.Providers.Adapter
    def parse_response(response), do: response

    @impl FermixCore.Providers.Adapter
    def supports_streaming?, do: false

    defp response do
      %{
        content: "reply from main agent",
        tool_calls: [],
        usage: %{prompt_tokens: 1, completion_tokens: 1, total_tokens: 2}
      }
    end

    defp turn do
      %{
        content: "reply from main agent",
        tool_calls: [],
        provider_state: %{},
        usage: %{prompt_tokens: 1, completion_tokens: 1, total_tokens: 2},
        model: "mock-model"
      }
    end
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

    def send_attachment(account, recipient, caption, path, opts) do
      send(
        Keyword.fetch!(opts, :test_pid),
        {:signal_attachment_send, account, recipient, caption, path}
      )

      :ok
    end
  end

  setup do
    Application.put_env(:fermix_channels, :signal,
      enabled: true,
      mode: :subprocess,
      account: "+15550001111",
      # F-02: empty allowlist now denies; tests need an explicit allow.
      allowed_sender_ids: ["+15551234567"]
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
      assert agent_message.metadata.user_id == "+15551234567"
      assert agent_message.metadata.chat_type == "private"
      assert :ok = agent_message.reply_fn.({:text, "reply from fermix"})
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

      queue =
        start_supervised!(
          {FermixChannels.Gateway.Queue,
           [name: :"queue_#{System.unique_integer([:positive])}", main_agent: agent]}
        )

      listener =
        start_supervised!(
          {Listener,
           [
             name: :"signal_listener_#{System.unique_integer([:positive])}",
             poll_interval: :manual,
             agent: FermixChannels.Gateway.Queue,
             agent_server: queue,
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

  describe "health_check/1" do
    test "returns ok when account and signal-cli are configured" do
      resolver = fn "signal-cli" -> "/usr/local/bin/signal-cli" end

      assert {:ok, %{detail: "Signal account +15550001111 configured", latency_ms: ms}} =
               Signal.health_check(executable_resolver: resolver)

      assert is_integer(ms)
    end

    test "classifies missing account as misconfigured" do
      Application.put_env(:fermix_channels, :signal, enabled: true)

      assert {:error, {:misconfigured, "signal account is not configured"}} =
               Signal.health_check(
                 executable_resolver: fn _path -> "/usr/local/bin/signal-cli" end
               )
    end

    test "classifies missing signal-cli as misconfigured" do
      resolver = fn "signal-cli" -> nil end

      assert {:error, {:misconfigured, "signal-cli executable not found at signal-cli"}} =
               Signal.health_check(executable_resolver: resolver)
    end
  end

  describe "send_message/3" do
    test "rejects missing signal account configuration" do
      Application.put_env(:fermix_channels, :signal, enabled: true)

      assert {:error, :not_configured} = Signal.send_message("+15551234567", "hello")
    end
  end

  describe "send_media/3" do
    test "sends attachments through the configured Signal client" do
      tmp_dir = FermixTestSupport.SafeRm.make_tmp_dir!("signal-send-media")

      try do
        path = Path.join(tmp_dir, "report.txt")
        File.write!(path, "report")

        assert :ok =
                 Signal.send_media(
                   "+15551234567",
                   %{kind: :document, path: path, caption: "Report", filename: "report.txt"},
                   client: FakeSignalClient,
                   client_opts: [test_pid: self()]
                 )

        assert_receive {:signal_attachment_send, "+15550001111", "+15551234567", "Report", ^path}
      after
        FermixTestSupport.SafeRm.rm_rf!(tmp_dir)
      end
    end

    test "rejects media over the Signal cap before send" do
      tmp_dir = FermixTestSupport.SafeRm.make_tmp_dir!("signal-send-media-cap")

      try do
        path = Path.join(tmp_dir, "oversize.bin")
        write_sparse_file!(path, 100 * 1_024 * 1_024 + 1)

        assert {:error, {:byte_cap_exceeded, actual, allowed}} =
                 Signal.send_media(
                   "+15551234567",
                   %{kind: :document, path: path, filename: "oversize.bin"},
                   client: FakeSignalClient,
                   client_opts: [test_pid: self()]
                 )

        assert actual == 100 * 1_024 * 1_024 + 1
        assert allowed == 100 * 1_024 * 1_024
        refute_received {:signal_attachment_send, _, _, _, _}
      after
        FermixTestSupport.SafeRm.rm_rf!(tmp_dir)
      end
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

  defp write_sparse_file!(path, size) when is_binary(path) and is_integer(size) and size > 0 do
    {:ok, file} = File.open(path, [:write, :binary])

    try do
      {:ok, _position} = :file.position(file, size - 1)
      :ok = IO.binwrite(file, <<0>>)
    after
      File.close(file)
    end
  end
end
