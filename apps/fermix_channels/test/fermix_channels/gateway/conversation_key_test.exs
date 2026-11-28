defmodule FermixChannels.Gateway.ConversationKeyTest do
  @moduledoc """
  `Gateway.conversation_key/2`: the conversation a message runs in, named
  before ingest by the steps ingest takes, so work ordered by it (the album
  buffer's lanes) and the queue agree.
  """

  # async: false — the ingest cases authorize against the global
  # `:fermix_channels, :telegram` env this module sets.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixChannels.Gateway
  alias FermixChannels.Gateway.Message
  alias FermixCore.Agents.ConversationKey
  alias FermixTestSupport.TelemetryCapture

  # A channel adapter with the two reply builders ingest needs, nothing else.
  defmodule ReplyChannel do
    def build_text_reply(%Message{}), do: fn _text -> :ok end
    def build_media_reply(%Message{}), do: fn _media -> :ok end
  end

  # The phone's adapter as the gateway reads it: its turns join the Mac's chat.
  defmodule MobileChannel do
    defdelegate joined_conversation(message), to: FermixChannels.Channels.Mobile
  end

  defmodule CapturingAgent do
    def handle_message(message, test_pid) do
      send(test_pid, {:agent_message, message})
      :ok
    end
  end

  setup do
    previous = Application.fetch_env(:fermix_channels, :telegram)
    Application.put_env(:fermix_channels, :telegram, owner_user_id: "test-sender")

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:fermix_channels, :telegram, value)
        :error -> Application.delete_env(:fermix_channels, :telegram)
      end
    end)
  end

  defp telegram(attrs \\ %{}) do
    Message.new!(
      Map.merge(
        %{
          id: "m-1",
          content: "the ferry leaves at nine",
          sender: "alice",
          channel: "telegram",
          chat_id: "42",
          reply_target: "42",
          metadata: %{user_id: "test-sender"}
        },
        attrs
      )
    )
  end

  test "a message in no thread: its channel and chat" do
    assert Gateway.conversation_key(ReplyChannel, telegram()) == {:ok, {"telegram", "42", :root}}
  end

  test "a message in a thread: the thread too, one key however its id is spelled" do
    assert Gateway.conversation_key(ReplyChannel, telegram(%{thread_ts: 7})) ==
             {:ok, {"telegram", "42", "7"}}

    assert Gateway.conversation_key(ReplyChannel, telegram(%{thread_ts: "7"})) ==
             {:ok, {"telegram", "42", "7"}}

    assert Gateway.conversation_key(ReplyChannel, telegram(%{thread_ts: "1731.0042"})) ==
             {:ok, {"telegram", "42", "1731.0042"}}
  end

  test "a raw map normalizes as ingest normalizes it, string keys included" do
    raw = %{
      "id" => "m-2",
      "content" => "hi",
      "sender" => "alice",
      "channel" => "whatsapp",
      "chat_id" => "wa-5",
      "reply_target" => "wa-5",
      "thread_ts" => "t-3"
    }

    assert Gateway.conversation_key(ReplyChannel, raw) == {:ok, {"whatsapp", "wa-5", "t-3"}}
  end

  test "a channel whose turns join another transport's names that conversation" do
    phone =
      Message.new!(%{
        id: "p-1",
        content: "on my way",
        sender: "owner",
        channel: "mobile",
        chat_id: "main",
        reply_target: "main"
      })

    assert Gateway.conversation_key(MobileChannel, phone) == {:ok, {"companion", "main", :root}}
  end

  test "a payload cannot name another conversation" do
    message = %{telegram() | conversation_key: {"companion", "main", :root}}

    assert Gateway.conversation_key(ReplyChannel, message) == {:ok, {"telegram", "42", :root}}
  end

  test "a message that does not normalize names no conversation" do
    assert Gateway.conversation_key(ReplyChannel, %{id: "m-3"}) ==
             {:error, {:invalid_message, :content}}

    assert Gateway.conversation_key(
             ReplyChannel,
             Map.delete(Map.from_struct(telegram()), :chat_id)
           ) ==
             {:error, {:invalid_message, :chat_id}}

    assert Gateway.conversation_key(ReplyChannel, %{telegram() | chat_id: nil}) ==
             {:error, {:invalid_message, :chat_id}}

    assert Gateway.conversation_key(ReplyChannel, %{telegram() | channel: nil}) ==
             {:error, {:invalid_message, :channel}}
  end

  test "it emits no telemetry; ingest counts the normalize once" do
    TelemetryCapture.attach([[:fermix, :dispatcher, :normalize]], :emitter)

    assert {:ok, _key} = Gateway.conversation_key(ReplyChannel, telegram())
    assert {:error, _reason} = Gateway.conversation_key(ReplyChannel, %{id: "m-4"})
    refute_received {:telemetry, [:fermix, :dispatcher, :normalize], _measurements, _metadata}

    # The control: the same handler sees ingest's normalize.
    capture_log(fn ->
      assert {:error, {:invalid_message, :content}} =
               Gateway.ingest([%{id: "m-4"}],
                 channel: ReplyChannel,
                 agent: CapturingAgent,
                 agent_server: self()
               )
    end)

    assert_received {:telemetry, [:fermix, :dispatcher, :normalize], _measurements,
                     %{status: :error}}
  end

  test "it is the key the queue gives the turn ingest delivers" do
    for message <- [telegram(), telegram(%{id: "m-5", thread_ts: 7})] do
      assert {:ok, key} = Gateway.conversation_key(ReplyChannel, message)

      assert :ok =
               Gateway.ingest([message],
                 channel: ReplyChannel,
                 agent: CapturingAgent,
                 agent_server: self()
               )

      assert_receive {:agent_message, %{id: id} = delivered}
      assert id == message.id
      assert ConversationKey.from(delivered) == key
    end
  end
end
