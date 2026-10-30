defmodule FermixChannels.Gateway.Commands.InCallApprovalTest do
  @moduledoc """
  Every confirm and deny surface answering a call that waits in its own
  process for the owner (M84: a sign-in, `AccessGate.ask_in_call/3`).

  Each surface ends in the typed `/confirm` or `/deny` `Commands.Sandbox`
  runs: the command itself, a chat's Approve and Deny buttons
  (`ApprovalButton`, Telegram and Discord), the Mac app's and the phone's card
  (`Companion.Output.approval/1`'s routes) and the owner's own inbox. These
  drive the real channel store and the application's gate store, so the module
  is not async.
  """
  use ExUnit.Case, async: false

  alias FermixChannels.Channels.Discord
  alias FermixChannels.Channels.Telegram
  alias FermixChannels.Companion.Output
  alias FermixChannels.Gateway.Authorizer
  alias FermixChannels.Gateway.Commands
  alias FermixChannels.Gateway.Commands.Sandbox, as: SandboxCommand
  alias FermixChannels.Gateway.Commands.Sandbox.Confirmations
  alias FermixChannels.Gateway.Message
  alias FermixChannels.Gateway.OwnerInboxApproval
  alias FermixChannels.Gateway.Queue
  alias FermixChannels.Gateway.Source
  alias FermixChannels.Mobile.DeviceStore
  alias FermixCore.Capabilities.AccessGate
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Memory.ConversationStore
  alias FermixCore.Timeouts

  @owner "111"
  @prompt "Sign in to github.com as alice@example.com?"
  @confirm_expired "Confirmed, but that request expired or was already handled"
  @deny_expired "That request expired or was already handled."
  # A waiting call's deny says only that; its turn tells the owner the outcome.
  @denied "Denied."
  @parked_denied "Not sent: the command was not approved."

  # An owner-inbox adapter. It is called from the waiting call's process, so it
  # reports to the test by the name the test registers.
  defmodule InboxAdapter do
    def build_text_reply(_message), do: fn _text -> :ok end
    def build_media_reply(_message), do: fn _part -> :ok end

    def send_approval(_message, text, token) do
      send(FermixChannels.Gateway.Commands.InCallApprovalTest, {:inbox_prompt, text, token})
      :ok
    end
  end

  # `MainAgent.checkout_turn_state/2` for the Queue: the turn state carries the
  # test pid the runner reports to.
  defmodule StubAgent do
    use GenServer

    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)

    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def handle_call({:checkout_turn_state, _msg}, _from, test_pid),
      do: {:reply, {:ok, %{test_pid: test_pid}, :hit}, test_pid}
  end

  # A turn whose one tool call asks the owner, as `Browser.SignIn` does: the
  # context is the one `TurnRunner` builds from the gateway's message.
  defmodule AskingRunner do
    def run(msg, turn_state, deliver) do
      context = %{
        source_trust: :operator,
        computer_use_origin: :interactive,
        session_id: "in-call-turn-#{System.unique_integer([:positive])}",
        reply_fn: deliver,
        approval_fn: msg.approval_fn
      }

      send(turn_state.test_pid, {:turn_waiting, self()})
      result = AccessGate.ask_in_call(msg.content, context, Timeouts.sign_in_approval())
      send(turn_state.test_pid, {:turn_result, result})
      {:ok, "signed in", 0}
    end

    def commit(_msg, _turn_state, _response, _context_tokens), do: :ok
    def error_reply(_reason), do: "error reply"
  end

  # `/stop`'s other two participants (`stop_all/1` is a `:stop_all` call).
  defmodule NothingRunning do
    use GenServer

    def start_link(counts), do: GenServer.start_link(__MODULE__, counts)

    @impl true
    def init(counts), do: {:ok, counts}

    @impl true
    def handle_call(:stop_all, _from, counts), do: {:reply, counts, counts}
  end

  setup do
    previous_telegram = Application.get_env(:fermix_channels, :telegram, [])
    previous_discord = Application.get_env(:fermix_channels, :discord)

    Application.put_env(:fermix_channels, :telegram,
      owner_user_id: @owner,
      allowed_user_ids: [@owner],
      command_allowlist: []
    )

    Application.put_env(:fermix_channels, :discord,
      owner_user_id: @owner,
      allowed_user_ids: [@owner],
      command_allowlist: []
    )

    Process.register(self(), __MODULE__)

    on_exit(fn ->
      Application.put_env(:fermix_channels, :telegram, previous_telegram)
      restore(:discord, previous_discord)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:fermix_channels, key)
  defp restore(key, value), do: Application.put_env(:fermix_channels, key, value)

  defp chat_origin(channel \\ "telegram", chat_id \\ "123", user_id \\ @owner) do
    %{channel: channel, chat_id: chat_id, thread_ts: nil, user_id: user_id, resume: nil}
  end

  # The context a sign-in's call carries on a chat turn, its approval closure
  # the one `Gateway.build_approval_fn/2` builds for that chat.
  defp turn_context(origin) do
    test_pid = self()

    %{
      source_trust: :operator,
      computer_use_origin: :interactive,
      session_id: "in-call-#{System.unique_integer([:positive])}",
      conversation_key: {origin.channel, origin.chat_id, :root},
      reply_fn: fn part -> send(test_pid, {:owner_prompt, part}) end,
      approval_fn: fn request -> SandboxCommand.store_pending_grant(request, origin) end
    }
  end

  defp wait_in_call(context) do
    task =
      Task.async(fn ->
        AccessGate.ask_in_call(@prompt, context, Timeouts.sign_in_approval())
      end)

    assert_receive {:owner_prompt, {:approval_prompt, text, token}}
    {task, token, intent(token), text}
  end

  defp intent(token) do
    assert {:ok, %{mutation: {:access_sensitive, id}}} = Confirmations.peek(token)
    id
  end

  defp result(task), do: Task.await(task, 10_000)

  defp telegram(content, chat_id \\ "123") do
    Message.new!(%{
      id: "msg-#{System.unique_integer([:positive])}",
      content: content,
      sender: "alice",
      channel: "telegram",
      chat_id: chat_id,
      reply_target: chat_id,
      metadata: %{user_id: @owner}
    })
  end

  defp app_message(channel, content) do
    Message.new!(%{
      id: "msg-#{System.unique_integer([:positive])}",
      content: content,
      sender: channel,
      channel: channel,
      chat_id: "main",
      reply_target: "main",
      metadata: %{}
    })
  end

  defp dispatch(message, context \\ %{}, ingress_context \\ nil) do
    test_pid = self()
    reply_fn = fn {:text, text} -> send(test_pid, {:command_reply, text}) end

    Commands.dispatch(
      Commands.parse(message),
      reply_fn,
      Map.put(context, :authorization, authorization(message, ingress_context))
    )
  end

  defp authorization(message, ingress_context) do
    {:ok, authorization} =
      message |> Map.from_struct() |> Source.from_message(ingress_context) |> Authorizer.resolve()

    authorization
  end

  describe "the confirm" do
    # On the Mac app and the phone a `/confirm` is a client request; one that
    # answers a waiting call replies at once, so it is never deferred.
    test "/confirm answers the waiting call at once and says only that it was approved" do
      {task, token, _id, text} = wait_in_call(turn_context(chat_origin()))
      assert text =~ "/confirm #{token}"
      assert text =~ "Fermix goes ahead only once you confirm."

      test_pid = self()
      defer = fn -> send(test_pid, :command_deferred) end

      assert :ok = dispatch(telegram("/confirm #{token}"), %{defer_command_fn: defer})
      assert_receive {:command_reply, "Approved."}
      assert result(task) == {:ok, :confirmed}
      refute_received :command_deferred
      refute_received {:command_reply, _}
    end

    test "a chat's Approve button answers it" do
      {task, token, _id, _text} = wait_in_call(turn_context(chat_origin()))

      {:ok, [tap]} = Telegram.parse_update(callback("grant:" <> token))
      assert :ok = dispatch(tap)
      assert_receive {:command_reply, "Approved."}
      assert result(task) == {:ok, :confirmed}
    end

    test "a confirm after the wait ended keeps the sentence for a request that is gone" do
      {task, token, id, _text} = wait_in_call(turn_context(chat_origin()))
      send(task.pid, {:access_timeout, id})
      assert result(task) == {:error, :unanswered}

      assert :ok = dispatch(telegram("/confirm #{token}"))
      assert_receive {:command_reply, reply}
      assert reply =~ @confirm_expired
    end
  end

  describe "every deny path reaches the waiting call" do
    test "the typed /deny" do
      {task, token, _id, _text} = wait_in_call(turn_context(chat_origin()))

      assert :ok = dispatch(telegram("/deny #{token}"))
      assert_receive {:command_reply, @denied}
      assert result(task) == {:error, :denied}
    end

    test "Telegram's Deny button" do
      {task, token, _id, _text} = wait_in_call(turn_context(chat_origin()))

      {:ok, [tap]} = Telegram.parse_update(callback("deny:" <> token))
      assert tap.content == "/deny #{token}"
      assert :ok = dispatch(tap)
      assert_receive {:command_reply, @denied}
      assert result(task) == {:error, :denied}
    end

    test "Discord's Deny button" do
      origin = chat_origin("discord", "dm-channel-1")
      {task, token, _id, _text} = wait_in_call(turn_context(origin))

      assert {:ok, %{message: tap}} = Discord.parse_interaction(interaction("deny:" <> token))
      assert tap.content == "/deny #{token}"
      assert :ok = dispatch(tap)
      assert_receive {:command_reply, @denied}
      assert result(task) == {:error, :denied}
    end

    test "the Mac app's card" do
      origin =
        Map.put(chat_origin("companion", "main", nil), :ingress_context, %{transport: :companion})

      {task, token, _id, text} = wait_in_call(turn_context(origin))
      card = Output.approval(%{kind: :sandbox, text: text, token: token})

      assert :ok = dispatch(app_message("companion", card["deny_command"]))
      assert_receive {:command_reply, @denied}
      assert result(task) == {:error, :denied}
    end

    test "the phone's card, which can approve too" do
      device = pair_device!()
      ingress = %{transport: :mobile, authenticated_device_id: device}
      origin = Map.put(chat_origin("mobile", "main", nil), :ingress_context, ingress)

      for {route, answer, reply} <- [
            {"deny_command", {:error, :denied}, @denied},
            {"approve_command", {:ok, :confirmed}, "Approved."}
          ] do
        {task, token, _id, text} = wait_in_call(turn_context(origin))
        card = Output.approval(%{kind: :sandbox, text: text, token: token})

        assert :ok = dispatch(app_message("mobile", card[route]), %{}, ingress)
        assert_receive {:command_reply, ^reply}
        assert result(task) == answer
      end
    end

    # A turn on a channel with no slash commands (ACP) asks in the owner's DM.
    test "the owner's own inbox" do
      inbox = [
        jobs_config: [],
        configured_owners: %{"telegram" => @owner},
        adapter: InboxAdapter
      ]

      context =
        chat_origin("acp", "session-1", nil)
        |> turn_context()
        |> Map.delete(:approval_fn)
        |> Map.put(:owner_inbox_approval_fn, &OwnerInboxApproval.request(&1, inbox))

      task =
        Task.async(fn ->
          AccessGate.ask_in_call(@prompt, context, Timeouts.sign_in_approval())
        end)

      assert_receive {:inbox_prompt, text, token}
      assert text =~ @prompt
      assert text =~ "Fermix goes ahead only once you confirm."
      refute text =~ "runs exactly this command"

      assert :ok = dispatch(telegram("/deny #{token}", @owner))
      assert_receive {:command_reply, @denied}
      assert result(task) == {:error, :denied}
    end

    test "a deny after the wait ended says the request is gone" do
      {task, token, id, _text} = wait_in_call(turn_context(chat_origin()))
      send(task.pid, {:access_timeout, id})
      assert result(task) == {:error, :unanswered}

      assert :ok = dispatch(telegram("/deny #{token}"))
      assert_receive {:command_reply, @deny_expired}
    end

    # D3 for a parked call: the deny now drops its gate record too, so nothing
    # of it can be run under that record afterwards.
    test "a parked call's /deny drops its gate record" do
      registry = :"in_call_caps_#{System.unique_integer([:positive])}"
      start_supervised!({CapabilityRegistry, name: registry})
      :ok = CapabilityRegistry.register(registry, flagged_capability())

      context =
        chat_origin()
        |> turn_context()
        |> Map.merge(%{
          capability_registry: registry,
          chat_type: "private",
          outside_sources: MapSet.new([{:tool, "web_fetch"}])
        })

      {:ok, capability} = CapabilityRegistry.find(registry, "tesla_unlock_doors")
      assert {:ok, %{success: false}} = Capability.execute(capability, %{"vin" => "5YJ"}, context)
      assert_receive {:owner_prompt, {:approval_prompt, _text, token}}
      id = intent(token)

      assert :ok = dispatch(telegram("/deny #{token}"))
      assert_receive {:command_reply, @parked_denied}
      assert {:error, "that request expired or was already handled"} = AccessGate.confirm(id)
      refute_received {:unlocked, _args}
    end
  end

  # The turn a sign-in waits in is a Queue turn task; `/stop` kills it at
  # ingress while it waits, and `/confirm` answers it there while it runs.
  describe "a running turn" do
    setup do
      supervisor = start_supervised!(Task.Supervisor)
      agent = start_supervised!({StubAgent, self()})

      store =
        start_supervised!(
          {ConversationStore,
           name: :"in_call_cs_#{System.unique_integer([:positive])}", max_messages: 32, repo: nil}
        )

      queue =
        start_supervised!(
          {Queue,
           name: :"in_call_queue_#{System.unique_integer([:positive])}",
           main_agent: agent,
           turn_runner: AskingRunner,
           task_supervisor: supervisor,
           conversation_store: store}
        )

      %{queue: queue}
    end

    defp start_turn(queue) do
      origin = chat_origin()
      test_pid = self()

      Queue.enqueue(queue, %{
        content: @prompt,
        sender: "alice",
        channel: "telegram",
        chat_id: "123",
        source_trust: :operator,
        reply_fn: fn part -> send(test_pid, {:turn_reply, part}) end,
        approval_fn: fn request -> SandboxCommand.store_pending_grant(request, origin) end
      })

      assert_receive {:turn_waiting, turn}, 10_000
      assert_receive {:turn_reply, {:approval_prompt, _text, token}}, 10_000
      {turn, token}
    end

    test "/confirm at ingress answers the call while its turn runs", %{queue: queue} do
      {_turn, token} = start_turn(queue)
      assert %{active_requests: 1} = Queue.status(queue)

      assert :ok = dispatch(telegram("/confirm #{token}"))
      assert_receive {:command_reply, "Approved."}
      assert_receive {:turn_result, {:ok, :confirmed}}
      assert_receive {:turn_reply, {:text, "signed in"}}, 10_000
    end

    test "/stop kills the turn mid-wait; its record goes, and a late answer finds nothing", %{
      queue: queue
    } do
      {turn, token} = start_turn(queue)
      id = intent(token)
      watch = Process.monitor(turn)
      {:ok, work} = NothingRunning.start_link(%{cancelled: 0})

      assert :ok =
               dispatch(telegram("/stop"), %{
                 agent_server: queue,
                 work_registry: work,
                 harness_manager: work
               })

      assert_receive {:command_reply, stopped}
      assert stopped =~ "cancelled 1 active turn"
      assert_receive {:DOWN, ^watch, :process, ^turn, :shutdown}
      refute_received {:turn_result, _result}

      assert :ok = dispatch(telegram("/confirm #{token}"))
      assert_receive {:command_reply, reply}
      assert reply =~ @confirm_expired
      assert {:error, :not_found} = AccessGate.deny(id)
      refute_received {:turn_result, _result}
    end
  end

  def unlock(args, _context) do
    send(__MODULE__, {:unlocked, args})
    {:ok, %{success: true, output: ~s({"result":true}), error: nil}}
  end

  defp flagged_capability do
    Capability.new(%{
      name: "tesla_unlock_doors",
      description: "Unlock the car's doors.",
      parameters: %{"type" => "object"},
      kind: :mcp,
      executor: {__MODULE__, :unlock, []},
      policy_class: :external_api,
      metadata: %{access_sensitive?: true, plugin_owned?: true, plugin: "tesla"}
    })
  end

  defp callback(data) do
    %{
      "callback_query" => %{
        "id" => "cbq-#{System.unique_integer([:positive])}",
        "data" => data,
        "from" => %{"id" => String.to_integer(@owner), "username" => "alice"},
        "message" => %{"message_id" => 55, "chat" => %{"id" => 123, "type" => "private"}}
      }
    }
  end

  defp interaction(custom_id) do
    %{
      "t" => "INTERACTION_CREATE",
      "d" => %{
        "id" => "interaction-#{System.unique_integer([:positive])}",
        "token" => "interaction-token-1",
        "type" => 3,
        "channel_id" => "dm-channel-1",
        "user" => %{"id" => @owner, "username" => "alice"},
        "data" => %{"custom_id" => custom_id, "component_type" => 2}
      }
    }
  end

  # A device paired in a throwaway trust store, under the name the authorizer
  # asks: a paired device is authorized only while the store holds it.
  defp pair_device! do
    root = FermixTestSupport.SafeRm.make_tmp_dir!("in-call-device")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(root) end)
    start_supervised!({DeviceStore, root: root, name: DeviceStore})
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    id =
      [{a, 8}, {b, 4}, {c, 4}, {d, 4}, {e, 12}]
      |> Enum.map_join("-", fn {part, width} ->
        part |> Integer.to_string(16) |> String.pad_leading(width, "0") |> String.downcase()
      end)

    {:ok, _device} =
      DeviceStore.add(DeviceStore, %{
        device_id: id,
        name: "iPhone",
        model: "iPhone17,1",
        noise_pk: :crypto.strong_rand_bytes(32),
        created_at: ~U[2026-10-29 09:00:00Z],
        apns_key_salt: :crypto.strong_rand_bytes(32)
      })

    id
  end
end
