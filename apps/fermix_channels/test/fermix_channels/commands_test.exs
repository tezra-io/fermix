defmodule FermixChannels.CommandsTest do
  use ExUnit.Case, async: false

  alias FermixChannels.Commands
  alias FermixChannels.Commands.Authorization
  alias FermixChannels.Commands.Compact
  alias FermixChannels.Message
  alias FermixCore.Memory.ConversationStore
  alias FermixCore.Sandbox.Config, as: SandboxConfig
  alias FermixCore.Sandbox.PathPolicy

  setup do
    telegram = Application.get_env(:fermix_channels, :telegram, [])

    on_exit(fn ->
      Application.put_env(:fermix_channels, :telegram, telegram)
    end)

    :ok
  end

  describe "parse/2" do
    test "recognizes leading slash commands and strips Telegram bot names" do
      assert {:command, "compact", ["now"], _message} =
               Commands.parse(message("/compact@FermixBot now"), bot_name: "fermixbot")
    end

    test "ignores non-command slash text and leading non-command content" do
      assert {:passthrough, _message} = Commands.parse(message("/Users/sujshe/file.txt"))
      assert {:passthrough, _message} = Commands.parse(message("what does /etc/hosts do?"))
    end

    test "allows leading whitespace before commands" do
      assert {:command, "help", [], _message} = Commands.parse(message("   /help"))
    end
  end

  describe "Authorization.owner_only/3" do
    test "allows cli without channel owner config" do
      assert :ok = Authorization.owner_only(message("/new", channel: "cli"), %{}, %{})
    end

    test "fails closed without owner or stable user id" do
      Application.put_env(:fermix_channels, :telegram, [])

      assert {:error, :unauthorized} =
               Authorization.owner_only(message("/new"), %{user_id: "123"}, %{})

      Application.put_env(:fermix_channels, :telegram, owner_user_id: "123")

      assert {:error, :unauthorized} = Authorization.owner_only(message("/new"), %{}, %{})
    end

    test "allows configured owner and command allowlist ids" do
      Application.put_env(:fermix_channels, :telegram,
        owner_user_id: "123",
        command_allowlist: ["456"]
      )

      assert :ok = Authorization.owner_only(message("/new"), %{user_id: 123}, %{})
      assert :ok = Authorization.owner_only(message("/new"), %{"user_id" => 456}, %{})

      assert {:error, :unauthorized} =
               Authorization.owner_only(message("/new"), %{user_id: "789"}, %{})
    end

    test "uses single ingress allowlist entry as the command owner fallback" do
      Application.put_env(:fermix_channels, :telegram, allowed_user_ids: ["123"])

      assert :ok = Authorization.owner_only(message("/new"), %{user_id: 123}, %{})

      assert {:error, :unauthorized} =
               Authorization.owner_only(message("/new"), %{user_id: "456"}, %{})
    end

    test "does not allow all ingress users to run owner-only commands" do
      Application.put_env(:fermix_channels, :telegram, allowed_user_ids: ["123", "456"])

      assert {:error, :unauthorized} =
               Authorization.owner_only(message("/new"), %{user_id: "123"}, %{})
    end

    test "fails closed for unrecognized channels even if :unknown is configured" do
      unknown = Application.get_env(:fermix_channels, :unknown, [])
      Application.put_env(:fermix_channels, :unknown, owner_user_id: "owner-1")

      on_exit(fn ->
        Application.put_env(:fermix_channels, :unknown, unknown)
      end)

      assert {:error, :unauthorized} =
               Authorization.owner_only(
                 message("/new", channel: "not-a-real-channel"),
                 %{user_id: "owner-1"},
                 %{}
               )
    end
  end

  describe "dispatch/3" do
    test "returns unauthorized after replying to owner-only command failures" do
      Application.put_env(:fermix_channels, :telegram, owner_user_id: "owner-1")
      test_pid = self()

      assert {:error, :unauthorized} =
               Commands.dispatch(
                 Commands.parse(message("/new", metadata: %{user_id: "intruder"})),
                 reply_fn(test_pid),
                 %{conversation_store: self(), conversation_key: {"telegram", "chat-1", :root}}
               )

      assert_receive {:compact_reply, "This command requires owner permissions."}
    end

    test "filters help output to commands authorized for the caller" do
      Application.put_env(:fermix_channels, :telegram, owner_user_id: "owner-1")
      test_pid = self()

      assert :ok =
               Commands.dispatch(
                 Commands.parse(message("/help", metadata: %{user_id: "intruder"})),
                 reply_fn(test_pid),
                 %{conversation_store: self(), conversation_key: {"telegram", "chat-1", :root}}
               )

      assert_receive {:compact_reply, help_text}
      assert help_text =~ "/help - List available commands."
      refute help_text =~ "/compact"
      refute help_text =~ "/new"
    end

    test "shows command aliases in help output for authorized callers" do
      Application.put_env(:fermix_channels, :telegram, owner_user_id: "owner-1")
      test_pid = self()

      assert :ok =
               Commands.dispatch(
                 Commands.parse(message("/help", metadata: %{user_id: "owner-1"})),
                 reply_fn(test_pid),
                 %{conversation_store: self(), conversation_key: {"telegram", "chat-1", :root}}
               )

      assert_receive {:compact_reply, help_text}
      assert help_text =~ "/new (/clear) - Start a fresh conversation session."
    end

    test "owner can inspect sandbox status" do
      {home, _root} = sandbox_fixture!()
      Application.put_env(:fermix_channels, :telegram, owner_user_id: "owner-1")
      test_pid = self()

      assert :ok =
               Commands.dispatch(
                 Commands.parse(message("/sandbox status", metadata: %{user_id: "owner-1"})),
                 reply_fn(test_pid),
                 %{conversation_key: {"telegram", "chat-1", :root}}
               )

      assert_receive {:compact_reply, status}
      assert status =~ "mode: strict"

      FermixTestSupport.SafeRm.rm_rf!(home)
    end

    test "widening sandbox channel commands require same-user confirmation" do
      {home, root} = sandbox_fixture!()
      Application.put_env(:fermix_channels, :telegram, owner_user_id: "owner-1")
      test_pid = self()

      assert :ok =
               Commands.dispatch(
                 Commands.parse(message("/grant path #{root}", metadata: %{user_id: "owner-1"})),
                 reply_fn(test_pid),
                 %{conversation_key: {"telegram", "chat-1", :root}}
               )

      assert_receive {:compact_reply, confirm_text}
      assert confirm_text =~ "/confirm "
      [token] = Regex.run(~r/\/confirm ([A-Z2-7]{8})/, confirm_text, capture: :all_but_first)
      refute PathPolicy.canonical_path(root) in SandboxConfig.current().allowed_roots

      assert :ok =
               Commands.dispatch(
                 Commands.parse(message("/confirm #{token}", metadata: %{user_id: "owner-1"})),
                 reply_fn(test_pid),
                 %{conversation_key: {"telegram", "chat-1", :root}}
               )

      assert_receive {:compact_reply, "Sandbox updated." <> _rest}
      assert PathPolicy.canonical_path(root) in SandboxConfig.current().allowed_roots

      FermixTestSupport.SafeRm.rm_rf!(home)
    end

    test "sandbox command preset updates use confirmation" do
      {home, _root} = sandbox_fixture!()
      Application.put_env(:fermix_channels, :telegram, owner_user_id: "owner-1")
      test_pid = self()

      assert :ok =
               Commands.dispatch(
                 Commands.parse(
                   message("/sandbox commands enable ai_tools", metadata: %{user_id: "owner-1"})
                 ),
                 reply_fn(test_pid),
                 %{conversation_key: {"telegram", "chat-1", :root}}
               )

      assert_receive {:compact_reply, confirm_text}
      assert confirm_text =~ "/confirm "
      assert confirm_text =~ "presets + ai_tools"

      [token] = Regex.run(~r/\/confirm ([A-Z2-7]{8})/, confirm_text, capture: :all_but_first)

      assert :ok =
               Commands.dispatch(
                 Commands.parse(message("/confirm #{token}", metadata: %{user_id: "owner-1"})),
                 reply_fn(test_pid),
                 %{conversation_key: {"telegram", "chat-1", :root}}
               )

      assert_receive {:compact_reply, "Sandbox updated." <> _rest}
      assert "ai_tools" in SandboxConfig.current().commands.presets

      FermixTestSupport.SafeRm.rm_rf!(home)
    end
  end

  describe "Compact.execute/3" do
    test "raises programming errors instead of converting them to user-facing compaction failures" do
      assert_raise KeyError, fn ->
        Compact.execute(message("/compact"), reply_fn(self()), %{})
      end
    end

    test "derives forced compaction budget from the resolved route context window" do
      Req.Test.set_req_test_to_shared()
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:summary_body, body})
        Req.Test.json(conn, summary_response_body("route-sized summary"))
      end)

      store = :"compact_route_budget_store_#{System.unique_integer([:positive])}"
      start_supervised!({ConversationStore, name: store, repo: nil})

      key = {"telegram", "chat-1", :root}

      ConversationStore.add_message(key, "user", String.duplicate("token ", 250_000),
        server: store
      )

      ConversationStore.add_message(key, "assistant", "latest assistant", server: store)

      assert :ok =
               Compact.execute(message("/compact"), reply_fn(test_pid), %{
                 conversation_key: key,
                 conversation_store: store,
                 route: route()
               })

      assert_receive {:summary_body, body}, 5_000
      assert body =~ "Summary token budget: 50000"
    end

    test "does not overwrite messages appended while summary is in flight" do
      Req.Test.set_req_test_to_shared()
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:summary_started, self(), body})

        receive do
          :continue_summary -> :ok
        end

        Req.Test.json(conn, summary_response_body("stale summary"))
      end)

      store = :"compact_stale_store_#{System.unique_integer([:positive])}"
      start_supervised!({ConversationStore, name: store, repo: nil})

      key = {"telegram", "chat-1", :root}
      old_content = String.duplicate("old turn ", 25_000)
      concurrent_content = "assistant reply that landed during compaction"

      ConversationStore.add_message(key, "user", old_content, server: store)
      ConversationStore.add_message(key, "assistant", "old assistant", server: store)

      task =
        Task.async(fn ->
          Compact.execute(message("/compact"), reply_fn(test_pid), %{
            conversation_key: key,
            conversation_store: store,
            route: route(),
            context_window: 100_000
          })
        end)

      assert_receive {:summary_started, summary_pid, _body}, 5_000
      ConversationStore.add_message(key, "assistant", concurrent_content, server: store)
      send(summary_pid, :continue_summary)

      assert :ok = Task.await(task, 5_000)

      assert_receive {:compact_reply,
                      "Conversation changed while compacting; run /compact again."}

      history = ConversationStore.get_history(key, server: store)
      assert Enum.any?(history, &(&1.content == concurrent_content))
      refute Enum.any?(history, &(&1.content =~ "stale summary"))
    end
  end

  defp message(content, opts \\ []) do
    Message.new!(%{
      id: "msg-1",
      content: content,
      sender: "alice",
      channel: Keyword.get(opts, :channel, "telegram"),
      chat_id: "chat-1",
      reply_target: "chat-1",
      metadata: Keyword.get(opts, :metadata, %{})
    })
  end

  defp reply_fn(test_pid) do
    fn
      {:text, text} ->
        send(test_pid, {:compact_reply, text})
        :ok

      text ->
      send(test_pid, {:compact_reply, text})
      :ok
    end
  end

  defp sandbox_fixture! do
    home = FermixTestSupport.SafeRm.make_tmp_dir!("channel-sandbox")
    root = Path.join(home, "project")
    File.mkdir_p!(root)
    previous_home = System.get_env("FERMIX_HOME")
    previous_sandbox = Application.get_env(:fermix_core, :sandbox)

    System.put_env("FERMIX_HOME", home)

    Application.put_env(
      :fermix_core,
      :sandbox,
      SandboxConfig.normalize(
        home: home,
        mode: :strict,
        workspace_root: Path.join(home, "workspace")
      )
    )

    on_exit(fn ->
      case previous_home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      case previous_sandbox do
        nil -> Application.delete_env(:fermix_core, :sandbox)
        value -> Application.put_env(:fermix_core, :sandbox, value)
      end
    end)

    {home, root}
  end

  defp route do
    route_key = %{
      provider: :openai,
      model: "gpt-5.4-mini",
      auth_mode: :api_key,
      base_url: "https://api.openai.com/v1"
    }

    adapter_opts = [
      api_key: "sk-test",
      model: route_key.model,
      base_url: route_key.base_url,
      req_options: [plug: {Req.Test, __MODULE__}]
    ]

    {route_key, adapter_opts}
  end

  defp summary_response_body(summary) do
    %{
      "model" => "gpt-5.4-mini",
      "output" => [
        %{
          "type" => "message",
          "id" => "msg_summary",
          "content" => [%{"type" => "output_text", "text" => summary}]
        }
      ],
      "usage" => %{"input_tokens" => 9, "output_tokens" => 3}
    }
  end
end
