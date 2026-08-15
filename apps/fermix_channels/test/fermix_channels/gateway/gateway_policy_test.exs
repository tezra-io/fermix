defmodule FermixChannels.Gateway.PolicyTest do
  @moduledoc """
  Registry-driven gateway policy (M29 §4/§6.3): the `commands?` command-pipeline
  skip and the optional per-turn callbacks a channel can inject onto the agent
  message (`:stream_spec` raw tier, `:activity_callback`, `:turn_result_fn`).
  """

  use ExUnit.Case, async: false

  alias FermixChannels.Gateway
  alias FermixChannels.Gateway.Commands.Registry, as: CommandRegistry
  alias FermixChannels.Gateway.Commands.Sandbox.Confirmations
  alias FermixChannels.Gateway.Message

  defmodule MobileChannel do
    def build_text_reply(%Message{}), do: fn _text -> :ok end
    def build_media_reply(%Message{}), do: fn _media -> :ok end
    def stream_capability, do: :draft_edit
    def open_draft(_message, text), do: {:ok, {:draft, text}}
    def edit_draft(_message, _handle, _text), do: :ok
    def seal_draft(_message, _handle, _text), do: {:ok, nil}
    def discard_draft(_message, _handle), do: :ok

    def build_activity_callback(%Message{id: id}) do
      test_pid = self()
      fn event -> send(test_pid, {:mobile_activity, id, event}) end
    end

    def build_turn_result(%Message{id: id}) do
      test_pid = self()
      fn event -> send(test_pid, {:mobile_terminal, id, event}) end
    end
  end

  defmodule CapturingAgent do
    def handle_message(message, test_pid) do
      send(test_pid, {:agent_message, message})
      :ok
    end
  end

  # Bare adapter: the two mandatory reply builders and nothing else. Exports no
  # optional callback, so no optional key may appear on the agent message.
  defmodule PlainChannel do
    def build_text_reply(%Message{reply_target: reply_target}) do
      test_pid = self()

      fn text ->
        send(test_pid, {:reply_sent, reply_target, text})
        :ok
      end
    end

    def build_media_reply(%Message{}) do
      fn _media_part -> {:error, :media_unsupported} end
    end
  end

  # Machine-surface adapter: `:raw` stream tier plus the activity/turn-result
  # callbacks an ACP-style peer injects.
  defmodule RawChannel do
    def build_text_reply(%Message{reply_target: reply_target}) do
      test_pid = self()

      fn text ->
        send(test_pid, {:reply_sent, reply_target, text})
        :ok
      end
    end

    def build_media_reply(%Message{}) do
      fn _media_part -> {:error, :media_unsupported} end
    end

    def stream_capability, do: :raw

    def build_raw_stream_callback(%Message{id: id}) do
      test_pid = self()

      fn event ->
        send(test_pid, {:raw_stream, id, event})
        :ok
      end
    end

    def build_activity_callback(%Message{id: id}) do
      test_pid = self()
      fn event -> send(test_pid, {:activity, id, event}) end
    end

    def build_turn_result(%Message{id: id}) do
      test_pid = self()
      fn outcome -> send(test_pid, {:turn_result, id, outcome}) end
    end

    def terminal_error_capability, do: :turn_result
  end

  # Ordinary chat adapter that can also post and delete ephemeral messages — the
  # thought-sweep pair the block-mode spec wires (CHANNEL_LONGFORM_PRESENTATION
  # §5).
  defmodule SweepChannel do
    def build_text_reply(%Message{reply_target: reply_target}) do
      test_pid = self()

      fn text ->
        send(test_pid, {:reply_sent, reply_target, text})
        :ok
      end
    end

    def build_media_reply(%Message{}) do
      fn _media_part -> {:error, :media_unsupported} end
    end

    def send_ephemeral(%Message{}, text), do: {:ok, ["id-" <> text]}

    def delete_message(%Message{}, _id), do: :ok
  end

  setup do
    test_pid = self()
    handler_id = "gateway-policy-#{System.unique_integer([:positive])}"

    # `Commands.dispatch/3` always emits `[:fermix, :command, :dispatch]` — even
    # for a passthrough — so its absence is proof the pipeline never ran. The
    # handler runs in the emitting process; ingest is synchronous, so filtering
    # on the test pid keeps other modules' events out of this mailbox.
    :telemetry.attach_many(
      handler_id,
      [[:fermix, :command, :dispatch], [:fermix, :command, :received]],
      fn event, _measurements, metadata, _config ->
        if self() == test_pid, do: send(test_pid, {:command_telemetry, event, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  describe "commands? registry field" do
    test "no registered command trigger reaches the command pipeline when the channel opts out" do
      register(commands?: false)
      triggers = command_triggers()

      # Whole-surface, not a hand-listed set (M28 lesson): a command added to the
      # registry later joins this loop automatically.
      assert length(triggers) >= 12

      for trigger <- triggers do
        content = "/#{trigger} arg"
        assert :ok = ingest(content, PlainChannel)

        assert_receive {:agent_message, agent_message}
        assert agent_message.content == content
        assert agent_message.channel == "opted_out"

        refute_received {:command_telemetry, _event, _metadata},
                        "/#{trigger} reached the command pipeline"
      end
    end

    test "an entry without the field keeps the command pipeline (the default)" do
      register([])

      assert :ok = ingest("/notacommand arg", PlainChannel)

      assert_receive {:agent_message, agent_message}
      assert agent_message.content == "/notacommand arg"
      assert_received {:command_telemetry, [:fermix, :command, :dispatch], _metadata}
    end
  end

  describe "optional per-turn callbacks" do
    test "a :raw channel gets a plain-map stream spec and both optional callbacks" do
      register(commands?: false)

      assert :ok = ingest("stream please", RawChannel)
      assert_receive {:agent_message, agent_message}

      stream_spec = agent_message.stream_spec
      assert %{mode: :raw, callback: callback} = stream_spec
      assert is_function(callback, 1)
      # Deliberately not a struct — the queue matches the plain map.
      refute Map.has_key?(stream_spec, :__struct__)
      assert Enum.sort(Map.keys(stream_spec)) == [:callback, :mode]

      assert :ok = callback.(%{type: :text_delta, text: "hi"})
      assert_received {:raw_stream, _id, %{type: :text_delta, text: "hi"}}

      assert is_function(agent_message.activity_callback, 1)
      agent_message.activity_callback.({:tool_start, "shell"})
      assert_received {:activity, _id, {:tool_start, "shell"}}

      assert is_function(agent_message.turn_result_fn, 1)
      agent_message.turn_result_fn.({:completed})
      assert_received {:turn_result, _id, {:completed}}
    end

    test "a raw channel never consults the streaming config" do
      register(commands?: false, config_key: :telegram)
      put_telegram(owner_user_id: "owner-1", streaming: "off")

      assert :ok = ingest("stream please", RawChannel)
      assert_receive {:agent_message, agent_message}
      assert %{mode: :raw} = agent_message.stream_spec
    end

    # The queue reads `:terminal_error_owner?` to suppress its canned error text
    # for a channel that renders terminal errors itself from the raw reason.
    test "terminal_error_capability :turn_result stamps the flag; a plain channel gets none" do
      register(commands?: false)

      assert :ok = ingest("hello", RawChannel)
      assert_receive {:agent_message, owning_message}
      assert owning_message.terminal_error_owner? == true

      assert :ok = ingest("hello", PlainChannel)
      assert_receive {:agent_message, plain_message}
      refute Map.has_key?(plain_message, :terminal_error_owner?)
    end

    test "a plain adapter carries none of the optional keys" do
      register(commands?: false)

      assert :ok = ingest("hello", PlainChannel)
      assert_receive {:agent_message, agent_message}

      refute Map.has_key?(agent_message, :stream_spec)
      refute Map.has_key?(agent_message, :activity_callback)
      refute Map.has_key?(agent_message, :turn_result_fn)
    end

    test "block streaming on an ordinary channel is unchanged and gains no new keys" do
      put_telegram(owner_user_id: "owner-1")

      message = message("hello", channel: "telegram", metadata: %{user_id: "owner-1"})

      assert :ok =
               Gateway.ingest([message],
                 channel: PlainChannel,
                 agent: CapturingAgent,
                 agent_server: self()
               )

      assert_receive {:agent_message, agent_message}

      assert %FermixChannels.Gateway.DraftStream.Spec{mode: :block, channel: "telegram"} =
               spec =
               agent_message.stream_spec

      # No ephemeral pair on a channel without the callbacks: it gets no thought
      # stream at all rather than undeletable 💭 messages (decision §9.2).
      assert spec.ephemeral_send == nil
      assert spec.delete == nil

      refute Map.has_key?(agent_message, :activity_callback)
      refute Map.has_key?(agent_message, :turn_result_fn)
    end

    test "a channel with send_ephemeral/delete_message gets both thought-sweep closures" do
      put_telegram(owner_user_id: "owner-1")

      message = message("hello", channel: "telegram", metadata: %{user_id: "owner-1"})

      assert :ok =
               Gateway.ingest([message],
                 channel: SweepChannel,
                 agent: CapturingAgent,
                 agent_server: self()
               )

      assert_receive {:agent_message, agent_message}
      spec = agent_message.stream_spec

      assert is_function(spec.ephemeral_send, 1)
      assert is_function(spec.delete, 1)
      assert {:ok, ["id-💭 thinking"]} = spec.ephemeral_send.("💭 thinking")
      assert :ok = spec.delete.("id-1")
    end
  end

  describe "authenticated mobile ingress" do
    setup do
      register_mobile()
      put_mobile(streaming: "draft")
      :ok
    end

    test "fails closed without explicit transport proof even if metadata is forged" do
      message =
        message("hello",
          channel: "mobile",
          chat_id: "main",
          reply_target: "main",
          metadata: %{
            transport_auth: %{transport: :mobile, authenticated_device_id: "forged"}
          }
        )

      assert :ok =
               Gateway.ingest([message],
                 channel: MobileChannel,
                 agent: CapturingAgent,
                 agent_server: self()
               )

      refute_receive {:agent_message, _message}
    end

    test "authenticated device is operator and receives draft/activity/terminal closures" do
      ingress_context = %{
        transport: :mobile,
        authenticated_device_id: "device-1"
      }

      message =
        message("hello",
          channel: "mobile",
          chat_id: "main",
          reply_target: "main",
          metadata: %{}
        )

      assert :ok =
               Gateway.ingest([message],
                 channel: MobileChannel,
                 agent: CapturingAgent,
                 agent_server: self(),
                 ingress_context: ingress_context
               )

      assert_receive {:agent_message, agent_message}
      assert agent_message.source_trust == :operator
      assert agent_message.chat_id == "main"

      assert %FermixChannels.Gateway.DraftStream.Spec{mode: :draft} =
               agent_message.stream_spec

      assert is_function(agent_message.activity_callback, 1)
      assert is_function(agent_message.turn_result_fn, 1)
      assert is_function(agent_message.approval_fn, 1)

      assert {:ok, token, :new} =
               agent_message.approval_fn.(%{
                 path: "/tmp/mobile-approved-root",
                 reason: "the mobile request needs it",
                 diff: "allowed_roots + /tmp/mobile-approved-root"
               })

      assert {:ok, pending} = Confirmations.take(token)
      assert pending.ingress_context == ingress_context
      refute Map.has_key?(agent_message.metadata, :ingress_context)
    end

    test "proof for another transport cannot authorize mobile" do
      message =
        message("hello", channel: "mobile", chat_id: "main", reply_target: "main")

      assert :ok =
               Gateway.ingest([message],
                 channel: MobileChannel,
                 agent: CapturingAgent,
                 agent_server: self(),
                 ingress_context: %{
                   transport: :acp,
                   authenticated_device_id: "device-1"
                 }
               )

      refute_receive {:agent_message, _message}
    end
  end

  # Every trigger the command surface answers to, discovered from
  # `Commands.Registry.list/0` (the module list `Commands.dispatch/3` looks up
  # through) — name plus each alias.
  defp command_triggers do
    Enum.flat_map(CommandRegistry.list(), fn command ->
      [command.name() | command.aliases()]
    end)
  end

  defp register(overrides) do
    entry =
      Enum.into(overrides, %{
        name: "opted_out",
        config_key: nil,
        adapter: nil,
        remote?: true,
        transport: :gateway,
        child: nil,
        trust: :local_operator
      })

    Application.put_env(:fermix_channels, :channel_registry, [entry])
    on_exit(fn -> Application.delete_env(:fermix_channels, :channel_registry) end)
  end

  # Restores the exact prior value (including "unset"), so a test asserting a
  # config-derived default never leaks an empty keyword list into a later module.
  defp put_telegram(config) do
    previous = Application.fetch_env(:fermix_channels, :telegram)
    Application.put_env(:fermix_channels, :telegram, config)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:fermix_channels, :telegram, value)
        :error -> Application.delete_env(:fermix_channels, :telegram)
      end
    end)
  end

  defp put_mobile(config) do
    previous = Application.fetch_env(:fermix_channels, :mobile)
    Application.put_env(:fermix_channels, :mobile, config)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:fermix_channels, :mobile, value)
        :error -> Application.delete_env(:fermix_channels, :mobile)
      end
    end)
  end

  defp register_mobile do
    entry = %{
      name: "mobile",
      config_key: :mobile,
      adapter: MobileChannel,
      remote?: true,
      transport: :listener,
      child: nil,
      ingress_auth: :paired_device
    }

    Application.put_env(:fermix_channels, :channel_registry, [entry])
    on_exit(fn -> Application.delete_env(:fermix_channels, :channel_registry) end)
  end

  defp ingest(content, channel) do
    Gateway.ingest([message(content, [])],
      channel: channel,
      agent: CapturingAgent,
      agent_server: self()
    )
  end

  defp message(content, overrides) do
    attrs =
      Enum.into(overrides, %{
        id: "policy-#{System.unique_integer([:positive])}",
        content: content,
        sender: "alice",
        channel: "opted_out",
        chat_id: "chat-1",
        reply_target: "chat-1"
      })

    struct!(Message, attrs)
  end
end
