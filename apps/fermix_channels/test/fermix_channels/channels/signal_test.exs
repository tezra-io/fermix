defmodule FermixChannels.Channels.SignalTest do
  use ExUnit.Case, async: false

  alias FermixChannels.Channels.Signal
  alias FermixChannels.Channels.Signal.Listener
  alias FermixChannels.Gateway.Message
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

    def send_reaction(account, recipient, author, timestamp, emoji, opts) do
      send(
        Keyword.fetch!(opts, :test_pid),
        {:signal_reaction, account, recipient, author, timestamp, emoji}
      )

      :ok
    end
  end

  # Records every outbound chunk in order and, with a `fail_at:` index, rejects
  # exactly that 1-based send so the sequencing after a failure is observable.
  defmodule ChunkRecordingSignalClient do
    def send_message(_account, _recipient, text, opts) do
      counter = Keyword.fetch!(opts, :counter)
      :counters.add(counter, 1, 1)
      send(Keyword.fetch!(opts, :test_pid), {:signal_chunk, text})
      reply(:counters.get(counter, 1), Keyword.fetch!(opts, :fail_at))
    end

    defp reply(index, fail_at) when index == fail_at, do: {:error, {:permanent, :remote_rejected}}
    defp reply(_index, _fail_at), do: :ok
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

  describe "reactions" do
    test "reaction_capability is any_emoji" do
      assert Signal.reaction_capability() == :any_emoji
    end

    test "react sends a signal-cli reaction targeting the message author + timestamp" do
      message =
        Message.new!(%{
          id: "1714000000000",
          content: "thanks",
          sender: "+15551234567",
          channel: "signal",
          chat_id: "+15551234567",
          reply_target: "+15551234567",
          metadata: %{
            sender_id: "+15551234567",
            signal_client: FakeSignalClient,
            signal_client_opts: [test_pid: self()]
          }
        })

      assert :ok = Signal.react(message, "👍")

      assert_receive {:signal_reaction, "+15550001111", "+15551234567", "+15551234567",
                      "1714000000000", "👍"}
    end
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
    # MILESTONE_31 §18 row "Channels", plain-text half: Signal renders no markup,
    # so the portable guarantee is that the tool-returned URL reaches the reader
    # byte-for-byte — query string, redirect token, and all (§9.5). Nothing may
    # shorten, rewrite, or strip it on the way out.
    test "carries place, source, and media URLs verbatim on a plain-text surface" do
      text = """
      - [Example Coffee](https://example.coffee/?utm=brave) — 4.6/5, 0.4 km away.
      Source: https://provider.example/place/abc?token=xyz
      Photo: https://cdn.example/p.jpg
      """

      assert :ok =
               Signal.send_message("+15551234567", text,
                 client: FakeSignalClient,
                 client_opts: [test_pid: self()]
               )

      assert_received {:signal_send, "+15550001111", "+15551234567", sent}
      assert sent =~ "https://example.coffee/?utm=brave"
      assert sent =~ "https://provider.example/place/abc?token=xyz"
      assert sent =~ "https://cdn.example/p.jpg"
    end

    # CHANNEL_LONGFORM_PRESENTATION §3.1: Signal has no platform cap, so the
    # ladder runs at Fermix's readability ceiling — a long reply arrives as a
    # few readable messages instead of one unbounded wall of text.
    test "splits long text at the readability cap into sequential sends" do
      text = paragraph_fixture(48)

      assert :ok = Signal.send_message("+15551234567", text, recording_client_opts(fail_at: nil))

      chunks = collect_chunks()
      assert length(chunks) == 3
      assert Enum.all?(chunks, &(String.length(&1) <= 4_000))
      # Paragraph-boundary cuts: rejoining reproduces the source exactly.
      assert Enum.join(chunks, "\n\n") == String.trim(text)
    end

    test "cuts long text on word boundaries, never mid-word" do
      text = sentence_fixture(200)

      assert :ok = Signal.send_message("+15551234567", text, recording_client_opts(fail_at: nil))

      chunks = collect_chunks()
      assert length(chunks) > 1
      # A chunk that began or ended mid-word would split one source word in two.
      assert Enum.flat_map(chunks, &String.split/1) == String.split(text)
    end

    test "the first failing chunk aborts the remaining sends" do
      assert {:error, {:permanent, :remote_rejected}} =
               Signal.send_message(
                 "+15551234567",
                 paragraph_fixture(48),
                 recording_client_opts(fail_at: 2)
               )

      # Three chunks were due; the send stopped at the failure.
      assert length(collect_chunks()) == 2
    end

    test "sends under-cap text as a single unchanged message" do
      assert :ok =
               Signal.send_message(
                 "+15551234567",
                 "short reply",
                 recording_client_opts(fail_at: nil)
               )

      assert collect_chunks() == ["short reply"]
    end

    # CHANNEL_LONGFORM_PRESENTATION §3.1, S4: signal-cli transmits an unstyled
    # body, so a long model reply must arrive both STRIPPED and SPLIT — the two
    # halves have to hold together, because the splitter runs on the Markdown
    # and the renderer runs on each chunk it produced.
    test "a long markdown reply arrives stripped and split on section boundaries" do
      assert :ok =
               Signal.send_message(
                 "+15551234567",
                 markdown_fixture(60),
                 recording_client_opts(fail_at: nil)
               )

      chunks = collect_chunks()
      assert length(chunks) > 1
      assert Enum.all?(chunks, &(String.length(&1) <= 4_000))

      # Stripped: no Markdown decoration survives anywhere in the sequence.
      assert Enum.all?(chunks, &(not String.contains?(&1, "**")))
      assert Enum.all?(chunks, &(not String.contains?(&1, "## ")))
      assert Enum.all?(chunks, &(not String.contains?(&1, "](http")))

      # ... while the content and the URL survive intact (§9.5).
      first = hd(chunks)
      assert first =~ "Overview 1 covers"
      assert first =~ "dive site 1: https://example.com/site/1"
      assert first =~ "• bullet 1 alpha"

      # Boundaries stay clean: every message opens on a section heading, so no
      # chunk stranded one at its tail and none starts mid-sentence.
      assert Enum.all?(chunks, &String.starts_with?(&1, "Section "))
    end

    # M30 §11.3: an unconfigured Signal account is an unavailable adapter, not a
    # bare `:not_configured` the delivery normalizer would have to guess at.
    test "rejects missing signal account configuration as an unavailable adapter" do
      Application.put_env(:fermix_channels, :signal, enabled: true)

      assert {:error, {:permanent, :adapter_unavailable}} =
               Signal.send_message("+15551234567", "hello")
    end
  end

  # -- telemetry --

  # One delivered message is one outbound row (design §8). Before S4 the adapter
  # emitted a single `count: N` row only when EVERY chunk of a reply landed — so
  # a reply that half-landed reported nothing at all.
  describe "outbound telemetry" do
    defp attach_message_events(handler_id) do
      :ok =
        :telemetry.attach(
          handler_id,
          [:fermix, :channel, :message],
          fn event, measurements, metadata, pid ->
            send(pid, {:telemetry, event, measurements, metadata})
          end,
          self()
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)
    end

    # Drains the outbound `channel_msg` rows recorded so far, in emission order.
    defp outbound_rows(acc \\ []) do
      receive do
        {:telemetry, [:fermix, :channel, :message], measurements,
         %{direction: :outbound} = metadata} ->
          outbound_rows([{measurements, metadata} | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    defp assert_single_message_row({measurements, metadata}) do
      assert measurements.count == 1
      assert measurements.duration_us >= 0
      assert metadata.channel == :signal
      assert metadata.direction == :outbound
    end

    test "emits one row per delivered chunk, not one row per reply" do
      attach_message_events("test-signal-outbound-per-chunk")

      assert :ok =
               Signal.send_message(
                 "+15551234567",
                 paragraph_fixture(48),
                 recording_client_opts(fail_at: nil)
               )

      chunks = collect_chunks()
      assert length(chunks) == 3

      rows = outbound_rows()
      assert length(rows) == length(chunks)
      Enum.each(rows, &assert_single_message_row/1)
    end

    test "a partial failure leaves truthful rows for the chunks that were delivered" do
      attach_message_events("test-signal-outbound-partial")

      assert {:error, {:permanent, :remote_rejected}} =
               Signal.send_message(
                 "+15551234567",
                 paragraph_fixture(48),
                 recording_client_opts(fail_at: 2)
               )

      # Chunk 1 reached the recipient and chunk 2 was rejected: exactly one row,
      # where the all-or-nothing emission reported none.
      assert [row] = outbound_rows()
      assert_single_message_row(row)
    end

    test "a send that fails on its first chunk emits nothing" do
      attach_message_events("test-signal-outbound-first-chunk-failed")

      assert {:error, {:permanent, :remote_rejected}} =
               Signal.send_message(
                 "+15551234567",
                 "short reply",
                 recording_client_opts(fail_at: 1)
               )

      assert outbound_rows() == []
    end
  end

  # M30 §11.3: the CLI classifier is the Signal send path's whole platform
  # knowledge. It is exercised directly with fabricated runner results so the
  # test spawns no process and reads no host state; stdout must never reach the
  # returned reason.
  describe "Signal.CLI.classify_send_result/1" do
    alias FermixChannels.Channels.Signal.CLI

    test "a zero exit is a successful send" do
      assert :ok = CLI.classify_send_result({:ok, %{exit: 0, stdout: ""}})
    end

    test "a non-zero CLI exit is a permanent remote rejection" do
      assert {:error, {:permanent, :remote_rejected}} =
               CLI.classify_send_result({:ok, %{exit: 1, stdout: "Failed to send message"}})
    end

    test "CLI stdout never reaches the returned reason" do
      assert {:error, reason} =
               CLI.classify_send_result(
                 {:ok, %{exit: 2, stdout: "recipient +15551234567 unknown"}}
               )

      refute inspect(reason) =~ "15551234567"
    end

    test "a command watchdog expiry is a transport timeout" do
      assert {:error, {:transport, :timeout}} =
               CLI.classify_send_result({:error, {:timeout, 30_000}})
    end

    test "a missing executable is an unavailable adapter" do
      assert {:error, {:permanent, :adapter_unavailable}} =
               CLI.classify_send_result({:error, {:executable_not_found, "signal-cli"}})
    end

    # `CommandRunner.reason/0` also carries the supervised path's own failures.
    # Left unhandled they raise three layers up, where the crash is normalized
    # to the terminal `{:delivery_crashed, :worker_crash}` and the reminder
    # fails on attempt one — so the classifier must close over them here.
    test "a command host failure is a transport failure, not a raise" do
      assert {:error, {:transport, :timeout}} =
               CLI.classify_send_result({:error, {:command_host_crashed, :no_start_ack}})

      assert {:error, {:transport, :timeout}} =
               CLI.classify_send_result({:error, {:port_failed, :eagain}})
    end

    test "an unrecognized runner result is a classified contract violation" do
      assert {:error, {:unexpected_delivery_result, :invalid_contract}} =
               CLI.classify_send_result({:error, :something_new})
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

  # -- outbound chunking fixtures --

  defp recording_client_opts(opts) do
    [
      client: ChunkRecordingSignalClient,
      client_opts: [
        test_pid: self(),
        counter: :counters.new(1, []),
        fail_at: Keyword.fetch!(opts, :fail_at)
      ]
    ]
  end

  @max_recorded_chunks 32

  defp collect_chunks, do: collect_chunks(@max_recorded_chunks, [])

  defp collect_chunks(0, _acc) do
    raise "more than #{@max_recorded_chunks} chunk sends recorded"
  end

  defp collect_chunks(remaining, acc) do
    receive do
      {:signal_chunk, text} -> collect_chunks(remaining - 1, [text | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # A model-shaped reply: sectioned, with every inline construct the dialect
  # strips, so the adapter test sees the same text the golden set does.
  defp markdown_fixture(count) do
    Enum.map_join(1..count, "\n\n", &fixture_section/1)
  end

  defp fixture_section(n) do
    """
    ## Section #{n}

    **Overview #{n}** covers [dive site #{n}](https://example.com/site/#{n}) and _tides_.

    - bullet #{n} alpha
    - bullet #{n} bravo\
    """
  end

  defp paragraph_fixture(count) do
    Enum.map_join(1..count, "\n\n", &fixture_paragraph/1)
  end

  defp fixture_paragraph(n) do
    "Paragraph #{n}. " <> Enum.map_join(1..20, " ", fn w -> "word-#{n}-#{w}" end) <> "."
  end

  defp sentence_fixture(count) do
    Enum.map_join(1..count, " ", fn n ->
      "Sentence #{n} about alpha bravo charlie delta echo foxtrot golf hotel."
    end)
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
