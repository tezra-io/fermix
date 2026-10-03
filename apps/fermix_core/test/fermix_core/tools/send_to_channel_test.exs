defmodule FermixCore.Tools.SendToChannelTest do
  @moduledoc """
  M56 §4.7: `send_to_channel`, "send it to my Telegram". The owner's own inbox
  on the channel named, resolved through `Delivery.OwnerInbox`, one send
  through `Delivery.ChannelSend` with a key a retry repeats, and a refusal
  with its reason, never another channel.

  The channels are this test's adapters, injected through the jobs config the
  delivery path reads (`:jobs_config`, `:configured_owners`), so nothing global
  is read or changed.
  """

  use ExUnit.Case, async: true

  alias FermixCore.Agents.VoiceCall
  alias FermixCore.Capabilities.Builtin
  alias FermixCore.Capabilities.BuiltinSeeder
  alias FermixCore.Capabilities.Registry
  alias FermixCore.Tools.SendToChannel

  # Every send any adapter below takes, and the proactive keys a timeline has
  # already written, for the test that started it. A send runs in a process
  # the delivery watchdog spawns, so the log is the one place it is seen. One
  # name serves: a module's tests run one at a time.
  defmodule SendLog do
    use Agent

    def start_link(test_pid),
      do: Agent.start_link(fn -> %{test_pid: test_pid, keys: MapSet.new()} end, name: __MODULE__)

    # Like a timeline: a key it has written is the same row, and nothing more
    # is sent.
    def record(platform, destination, text, opts) do
      key = Keyword.get(opts, :proactive_key)

      Agent.get_and_update(__MODULE__, fn state ->
        if MapSet.member?(state.keys, key) do
          {:existing, state}
        else
          send(state.test_pid, {:sent, platform, destination, text, opts})
          {:created, %{state | keys: MapSet.put(state.keys, key)}}
        end
      end)
    end
  end

  # A remote platform's adapter: it sends, and the owner's inbox on it is the
  # DM its owner id derives.
  defmodule TelegramAdapter do
    def send_message(destination, text, opts) do
      _status = SendLog.record("telegram", destination, text, opts)
      :ok
    end
  end

  defmodule RefusingAdapter do
    def send_message(_destination, _text, _opts), do: {:error, {:permanent, :authentication}}
  end

  # The Mac's chat: an owner-only transport naming its own inbox.
  defmodule CompanionAdapter do
    def send_message(destination, text, opts) do
      _status = SendLog.record("companion", destination, text, opts)
      :ok
    end

    def owner_inbox, do: {:ok, "main"}
  end

  @text "The lease renews on 2026-11-01; the landlord's number is 555-0142."

  setup do
    start_supervised!({SendLog, self()})
    :ok
  end

  test "is a registered, classified, owner-only write in a category no voice call excludes" do
    assert SendToChannel.name() == "send_to_channel"
    assert SendToChannel in BuiltinSeeder.builtin_tool_modules()
    assert "send_to_channel" in Builtin.classified_names()
    assert Builtin.owner_only_declared?("send_to_channel")

    capability = Builtin.from_tool_module(SendToChannel)
    assert capability.owner_only? == true
    # A write: a guest and a delegated worker never get it.
    assert capability.policy_class == :read_write
    assert capability.metadata.category == :delivery

    refute :delivery in VoiceCall.excluded_categories()
  end

  test "is no guest's, by surface or by name" do
    registry = :"send_to_channel_registry_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, name: registry})
    :ok = Registry.register(registry, Builtin.from_tool_module(SendToChannel))

    assert ["send_to_channel"] == registry |> Registry.list(trust: :operator) |> names()
    assert [] == registry |> Registry.list(trust: :guest) |> names()
  end

  describe "the owner's inbox on the channel named" do
    test "is sent the text once, and the result says where it went" do
      assert {:ok, %{success: true, output: output}} =
               SendToChannel.execute(args("telegram"), context())

      assert_receive {:sent, "telegram", "owner-t", @text, opts}
      assert is_binary(opts[:proactive_key])
      assert output =~ "telegram"
      refute_receive {:sent, _platform, _destination, _text, _opts}, 100
    end

    test "a transport only the owner reaches is sent to the inbox its adapter names" do
      assert {:ok, %{success: true}} = SendToChannel.execute(args("companion"), context())
      assert_receive {:sent, "companion", "main", @text, _opts}
    end

    test "a retry of the same text in the same turn repeats the key, and the same result" do
      first = SendToChannel.execute(args("companion"), context())
      second = SendToChannel.execute(args("companion"), context())

      assert first == second
      assert {:ok, %{success: true}} = first
      assert_receive {:sent, "companion", "main", @text, _opts}
      refute_receive {:sent, _platform, _destination, _text, _opts}, 100
    end

    test "the key is the turn's and the text's: another turn or another text is its own send" do
      SendToChannel.execute(args("companion"), context(session_id: "turn-a"))
      SendToChannel.execute(args("companion"), context(session_id: "turn-b"))
      SendToChannel.execute(args("companion", "something else"), context(session_id: "turn-b"))

      assert_receive {:sent, "companion", "main", @text, first}
      assert_receive {:sent, "companion", "main", @text, second}
      assert_receive {:sent, "companion", "main", "something else", third}
      keys = Enum.map([first, second, third], & &1[:proactive_key])
      assert keys == Enum.uniq(keys)
    end
  end

  describe "a refusal" do
    test "a channel that is not configured is refused, and nothing is sent anywhere" do
      assert {:ok, %{success: false, error: error}} =
               SendToChannel.execute(args("discord"), context())

      assert error =~ "discord"
      assert error =~ "no channel is configured"
      # It names where the owner can be reached instead; it sends there never.
      assert error =~ "companion, telegram"
      refute_receive {:sent, _platform, _destination, _text, _opts}, 100
    end

    test "a configured channel with no owner inbox is refused, never sent to another" do
      assert {:ok, %{success: false, error: error}} =
               SendToChannel.execute(args("slack"), context())

      assert error =~ "slack"
      assert error =~ "no inbox of the owner's"
      refute_receive {:sent, _platform, _destination, _text, _opts}, 100
    end

    test "the channel's own refusal comes back with its reason" do
      context = context(channels: %{"telegram" => RefusingAdapter})

      assert {:ok, %{success: false, error: error}} =
               SendToChannel.execute(args("telegram"), context)

      assert error =~ "channel credentials were rejected"
    end

    test "text past 4 KB is refused before anything is resolved or sent" do
      long = String.duplicate("a", SendToChannel.text_max_bytes() + 1)

      assert {:ok, %{success: false, error: error}} =
               SendToChannel.execute(args("telegram", long), context())

      assert error =~ "4096"
      refute_receive {:sent, _platform, _destination, _text, _opts}, 100
    end

    test "an empty text or a missing channel is refused" do
      assert {:ok, %{success: false}} = SendToChannel.execute(args("telegram", ""), context())
      assert {:ok, %{success: false}} = SendToChannel.execute(%{"text" => @text}, context())
      refute_receive {:sent, _platform, _destination, _text, _opts}, 100
    end
  end

  describe "the offer" do
    test "is made only while a delivery channel has an owner inbox, naming those channels" do
      assert SendToChannel.advertise?(context())

      assert %{properties: %{channel: %{enum: ["companion", "telegram"]}}} =
               SendToChannel.dynamic_parameters(context())

      refute SendToChannel.advertise?(context(channels: %{"slack" => TelegramAdapter}))
      refute SendToChannel.advertise?(context(channels: %{}))
    end

    test "says it is for the owner's own channels, not for replying" do
      assert SendToChannel.when_to_use() =~ "my Telegram"
      assert SendToChannel.when_to_use() =~ "not for replying"
    end
  end

  # Telemetry through the one tool emitter, with the channel and sizes: the
  # text, which may have been said aloud, reaches no field.
  test "emits one tool event with the channel and the text's size, never the text" do
    handler = "send-to-channel-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler,
      [:fermix, :tool, :exec],
      fn _event, _measurements, metadata, _config ->
        if metadata.tool == "send_to_channel" and metadata[:session_id] == "stc-telemetry",
          do: send(test_pid, {:tool_exec, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    SendToChannel.execute(args("telegram"), context(session_id: "stc-telemetry"))
    SendToChannel.execute(args("discord"), context(session_id: "stc-telemetry"))

    assert_receive {:tool_exec, sent}
    assert sent.success == true
    assert sent.channel == "telegram"
    assert sent.text_bytes == byte_size(@text)
    assert sent.outcome == "sent"

    assert_receive {:tool_exec, refused}
    assert refused.success == false
    assert refused.channel == "discord"
    assert refused.outcome == "unsupported_delivery_platform"

    for metadata <- [sent, refused], do: refute(inspect(metadata) =~ "landlord")
  end

  defp args(channel, text \\ @text), do: %{"channel" => channel, "text" => text}

  defp context(overrides \\ []) do
    channels =
      Keyword.get(overrides, :channels, %{
        "telegram" => TelegramAdapter,
        "slack" => TelegramAdapter,
        "companion" => CompanionAdapter
      })

    %{
      agent_name: "main",
      conversation_key: {"companion", "main", :root},
      session_id: Keyword.get(overrides, :session_id, "turn-1"),
      source_trust: :operator,
      jobs_config: [delivery_channels: channels],
      configured_owners: %{"telegram" => "owner-t"}
    }
  end

  defp names(capabilities), do: Enum.map(capabilities, & &1.name)
end
