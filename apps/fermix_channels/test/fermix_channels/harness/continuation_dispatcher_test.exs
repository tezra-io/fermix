defmodule FermixChannels.Harness.ContinuationDispatcherTest do
  # async: false — the owner-id preconditions read the global
  # `:fermix_channels` channel config, which each test sets and restores.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias FermixChannels.Channels.Acp
  alias FermixChannels.Channels.Discord
  alias FermixChannels.Channels.Slack
  alias FermixChannels.Gateway
  alias FermixChannels.Gateway.Authorizer
  alias FermixChannels.Gateway.Message
  alias FermixChannels.Gateway.Source
  alias FermixChannels.Harness.ContinuationDispatcher
  alias FermixCore.Acp.Identity
  alias FermixCore.Acp.IdentityStore
  alias FermixCore.Agents.ConversationKey
  alias FermixCore.Agents.TurnRunner
  alias FermixCore.PhoneCalls.Continuation, as: PhoneCallContinuation
  alias FermixTestSupport.SafeRm

  # Published NIP-19 test vectors (see `nostr/key_test.exs`) — never live keys.
  @nsec "nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5"
  @public_hex "7e7e9c42a91bfef19fa929e5fda1b72e0ebc1a4c1141673e2794234d86addf4e"
  @npub "npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg"

  # A reply that names an address the called person could have dictated.
  # Every name and address here is invented.
  @dictated "They said the intake forms are at https://clinic.example/forms."

  # Stands in for the agent a channel hands its turns to: each turn the
  # gateway builds comes back to the test, which plays the turn's reply.
  defmodule TurnSink do
    @moduledoc false
    def handle_message(turn, server) do
      send(server, {:turn, turn})
      :ok
    end
  end

  setup do
    prior = Application.get_env(:fermix_channels, :telegram)
    Application.put_env(:fermix_channels, :telegram, enabled: true, owner_user_id: "999")

    # A scratch FERMIX_HOME: the client-owned arm resolves a durable identity
    # record, and the host's own ~/.fermix must never be read or written because a
    # test dispatched (same discipline as `acp/peer_test.exs`).
    previous_home = System.get_env("FERMIX_HOME")
    home = SafeRm.make_tmp_dir!("harness-continuation-home")
    System.put_env("FERMIX_HOME", home)

    on_exit(fn ->
      case prior do
        nil -> Application.delete_env(:fermix_channels, :telegram)
        value -> Application.put_env(:fermix_channels, :telegram, value)
      end

      case previous_home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      SafeRm.rm_rf!(home)
    end)

    :ok
  end

  describe "dispatch/2" do
    test "re-ingests the notice as the channel owner through the resolved adapter", ctx do
      assert :ok = ContinuationDispatcher.dispatch(notice(), opts(ctx))

      assert_receive {:ingested, [message], ingest_opts}
      assert message.channel == "telegram"
      assert message.chat_id == "123"
      assert message.reply_target == "123"
      assert message.content =~ "[coding run hr_1 finished]"
      # Operator trust comes from the configured owner id, never an escalation.
      assert message.metadata.user_id == "999"
      assert message.metadata.harness_continuation == true
      assert message.metadata.harness_continuation_depth == 1
      assert ingest_opts[:channel] == FermixChannels.Channels.Telegram
    end

    test "the synthesized message authorizes as the owner through the real authorizer", ctx do
      assert :ok = ContinuationDispatcher.dispatch(notice(), opts(ctx))

      assert_receive {:ingested, [message], _opts}

      assert {:ok, authorization} =
               message |> Source.from_message() |> Authorizer.resolve()

      assert authorization.trust == :operator
    end

    test "carries a thread through as the message thread", ctx do
      assert :ok = ContinuationDispatcher.dispatch(notice(%{thread: "77"}), opts(ctx))

      assert_receive {:ingested, [message], _opts}
      assert message.thread_ts == "77"
      assert message.thread_scope == :thread
    end

    # The ledger persists the thread as text, while a Telegram forum topic arrives
    # as an integer: both must key the SAME conversation, or the continuation turn
    # loads none of the request it is meant to continue.
    test "keys the same conversation as the origin turn for an integer thread id", ctx do
      assert :ok = ContinuationDispatcher.dispatch(notice(%{thread: "456"}), opts(ctx))

      assert_receive {:ingested, [message], _opts}
      origin = %{channel: "telegram", chat_id: "123", thread_ts: 456}
      assert ConversationKey.from(message) == ConversationKey.from(origin)
    end

    test "a gateway ingest refusal is reported, never reported as accepted", ctx do
      opts =
        ctx
        |> opts()
        |> Keyword.put(:ingest, fn _messages, _opts -> {:error, {:invalid_message, :content}} end)

      assert ExUnit.CaptureLog.capture_log(fn ->
               assert {:error, {:continuation_ingest_failed, {:invalid_message, :content}}} =
                        ContinuationDispatcher.dispatch(notice(), opts)
             end) =~ "harness continuation ingest failed"
    end

    test "refuses an unknown channel before any spawn", ctx do
      assert {:error, {:unknown_continuation_channel, "nowhere"}} =
               ContinuationDispatcher.dispatch(notice(%{platform: "nowhere"}), opts(ctx))

      refute_receive {:ingested, _messages, _opts}, 100
    end

    test "refuses a remote channel with no explicit owner configured", ctx do
      Application.put_env(:fermix_channels, :telegram, enabled: true)

      assert {:error, {:no_owner_configured, "telegram"}} =
               ContinuationDispatcher.dispatch(notice(), opts(ctx))

      refute_receive {:ingested, _messages, _opts}, 100
    end

    test "refuses when the agent queue is not alive", ctx do
      opts = ctx |> opts() |> Keyword.put(:agent_server, :harness_continuation_absent_queue)

      assert {:error, {:agent_unavailable, :harness_continuation_absent_queue}} =
               ContinuationDispatcher.dispatch(notice(), opts)

      refute_receive {:ingested, _messages, _opts}, 100
    end

    # The Mac app's chat hands its turns to `Companion.Turns`, which ends each
    # one on its wire: a report re-ingested around it starts a turn there that
    # nothing ends.
    test "hands the notice to the agent the channel's own transport uses", ctx do
      opts = ctx |> opts() |> Keyword.delete(:agent)

      assert :ok = ContinuationDispatcher.dispatch(notice(), opts)
      assert_receive {:ingested, [_telegram], telegram_opts}
      assert telegram_opts[:agent] == FermixChannels.Gateway.Queue

      chat = notice(%{platform: "companion", destination: "main"})
      assert :ok = ContinuationDispatcher.dispatch(chat, opts)
      assert_receive {:ingested, [message], chat_opts}
      assert message.channel == "companion"
      assert chat_opts[:agent] == FermixChannels.Companion.Turns
    end

    # `Companion.Turns` shows a report as no turn on the Mac's wire alone: the
    # phone's channel has no owner id to re-enter as, so no report runs there.
    test "refuses the phone's channel, which has no owner to re-enter as", ctx do
      phone = notice(%{platform: "mobile", destination: "main"})

      assert {:error, {:no_owner_configured, "mobile"}} =
               ContinuationDispatcher.dispatch(phone, opts(ctx))

      refute_received {:ingested, _messages, _opts}
    end

    test "refuses a notice with no delivery target", ctx do
      assert {:error, {:invalid_continuation_target, _}} =
               ContinuationDispatcher.dispatch(notice(%{destination: nil}), opts(ctx))
    end

    # The regression half of the client-owned arm: a framework-delivered origin
    # must build the same message it built before this feature existed.
    test "a framework-delivered origin carries no env, no cwd and no acp sentinel", ctx do
      assert :ok = ContinuationDispatcher.dispatch(notice(), opts(ctx))

      assert_receive {:ingested, [message], _opts}
      assert message.session_env == nil
      assert message.request_cwd == nil
      refute Map.has_key?(message.metadata, Acp.turn_opt())
    end

    # The owner's chat is still a live surface where `/stop` reaches the turn, so
    # its continuation keeps host computer use.
    test "an owner-chat continuation stays an attended computer-use origin", ctx do
      assert :ok = ContinuationDispatcher.dispatch(notice(), opts(ctx))

      assert_receive {:ingested, [message], _opts}
      assert TurnRunner.computer_use_origin(message) == :interactive
    end
  end

  # M29 §17.6(c) — the ACP session that launched the run is long gone; the turn
  # env comes from the durable identity record and nothing else.
  describe "dispatch/2 — client-owned origin" do
    test "dispatches with no configured owner and injects the persisted env + launch cwd",
         ctx do
      persist_identity()

      assert :ok = ContinuationDispatcher.dispatch(acp_notice(), opts(ctx))

      assert_receive {:ingested, [message], ingest_opts}
      assert message.channel == "acp"
      assert message.chat_id == "sess-gone"
      # Trust is the transport's, so no sender id is stamped and none is needed.
      refute Map.has_key?(message.metadata, :user_id)
      assert ingest_opts[:channel] == Acp

      assert message.session_env["BUZZ_PRIVATE_KEY"] == @nsec
      assert message.session_env["PATH"] == "/fake/bin:/usr/bin"
      assert Identity.posting_capable?(message.session_env)
      assert message.request_cwd == "/repo/apps/core"
    end

    test "the synthesized message authorizes as the operator through the real authorizer",
         ctx do
      persist_identity()

      assert :ok = ContinuationDispatcher.dispatch(acp_notice(), opts(ctx))
      assert_receive {:ingested, [message], _opts}
      assert {:ok, authorization} = message |> Source.from_message() |> Authorizer.resolve()
      assert authorization.trust == :operator
    end

    # The identity was forgotten (or quarantined, or refused for permissions)
    # between launch and completion. Its own named refusal — never
    # `unknown_continuation_channel`, never `no_owner_configured`, and never the
    # platform term — and the store's own kind survives inside it.
    test "refuses with a named reason when the identity is gone", ctx do
      log =
        capture_log(fn ->
          assert {:error, {:identity_forgotten, @npub, store_reason}} =
                   ContinuationDispatcher.dispatch(acp_notice(), opts(ctx))

          assert elem(store_reason, 0) == :identity_missing
        end)

      assert log =~ "identity"
      refute_receive {:ingested, _messages, _opts}, 100
    end

    # A row whose snapshot names no identity at all cannot be resolved either, and
    # must not crash the dispatcher on the way to saying so.
    test "an origin naming no identity refuses by name rather than raising", ctx do
      origin = %{"cwd" => "/repo", "reply_context" => "x"}

      assert {:error, {:identity_forgotten, :unnamed_identity, {:identity_unnamed, nil}}} =
               ContinuationDispatcher.dispatch(acp_notice(%{client_origin: origin}), opts(ctx))
    end

    test "an unknown channel and a missing owner keep their own distinct refusals", ctx do
      persist_identity()

      assert {:error, {:unknown_continuation_channel, "nowhere"}} =
               ContinuationDispatcher.dispatch(acp_notice(%{platform: "nowhere"}), opts(ctx))

      Application.put_env(:fermix_channels, :telegram, enabled: true)

      assert {:error, {:no_owner_configured, "telegram"}} =
               ContinuationDispatcher.dispatch(notice(), opts(ctx))
    end

    # Deliverable: the ACP wire reply is best-effort-if-alive. A detached turn's
    # closures must be a QUIET, NAMED no-op — the un-fenced path is a
    # `Logger.error` per stream delta, which is an error storm nobody can read.
    test "a dead session's stream/activity closures are a quiet named no-op", ctx do
      persist_identity()

      assert :ok = ContinuationDispatcher.dispatch(acp_notice(), opts(ctx))
      assert_receive {:ingested, [message], _opts}
      assert message.metadata[Acp.turn_opt()] == :detached

      log =
        capture_log(fn ->
          stream = Acp.build_raw_stream_callback(message)
          activity = Acp.build_activity_callback(message)

          assert {:error, :detached_turn} = stream.(%{type: :delta, text: "hi"})
          assert {:error, :detached_turn} = stream.(%{type: :delta, text: "there"})
          assert {:error, :detached_turn} = activity.(%{type: :tool_start, name: "shell"})
        end)

      refute log =~ "[error]"
    end

    # Core reads the detached sentinel as a plain metadata value (it cannot
    # compile-depend on this app), so the cross-app contract is pinned here, on
    # the message the dispatcher really builds: nobody can watch or cancel the
    # turn, so it must fail the computer-use host gate.
    test "the detached turn is an unattended computer-use origin", ctx do
      persist_identity()

      assert :ok = ContinuationDispatcher.dispatch(acp_notice(), opts(ctx))
      assert_receive {:ingested, [message], _opts}
      assert TurnRunner.computer_use_origin(message) == :unattended
    end
  end

  # A phone call's report quotes words the called person said, and a link
  # preview is a fetch of an address they could have dictated (M94 D23).
  # Core's notice asks for none, and the reply path every turn takes carries
  # that to the channel's send. A reply to the owner's own message on the same
  # channel previews as it always did.
  describe "dispatch/2 — a phone call's report previews no link" do
    setup :chat_channels

    test "on Slack its reply unfurls nothing, and an owner's reply is unchanged" do
      stub_posts(:report_previews_slack, %{"ok" => true, "ts" => "1.2"})
      report = call_notice(%{platform: "slack", destination: "C0REPORT1"})

      assert :ok = ContinuationDispatcher.dispatch(report, turn_opts())
      assert %{"unfurl_links" => false, "unfurl_media" => false} = reply_posted()

      owners = owner_message("slack", "C0REPORT1", "U0OWNER1")
      assert :ok = Gateway.ingest([owners], ingest_opts(Slack))
      body = reply_posted()
      refute Map.has_key?(body, "unfurl_links")
      refute Map.has_key?(body, "unfurl_media")
    end

    test "on Discord its reply suppresses embeds, and an owner's reply is unchanged" do
      stub_posts(:report_previews_discord, %{"id" => "40001"})
      report = call_notice(%{platform: "discord", destination: "40017"})

      assert :ok = ContinuationDispatcher.dispatch(report, turn_opts())
      # 4 is Discord's SUPPRESS_EMBEDS message flag.
      assert %{"flags" => 4} = reply_posted()

      owners = owner_message("discord", "40017", "111")
      assert :ok = Gateway.ingest([owners], ingest_opts(Discord))
      refute Map.has_key?(reply_posted(), "flags")
    end
  end

  defp notice(overrides \\ %{}) do
    Map.merge(
      %{
        platform: "telegram",
        destination: "123",
        thread: nil,
        client_origin: nil,
        content: "[coding run hr_1 finished]\ncodex · completed · /repo",
        metadata: %{
          harness_continuation: true,
          harness_run_id: "hr_1",
          harness_continuation_depth: 1
        }
      },
      overrides
    )
  end

  defp acp_notice(overrides \\ %{}) do
    notice(
      Map.merge(
        %{
          platform: "acp",
          destination: "sess-gone",
          client_origin: %{
            "identity" => @public_hex,
            "cwd" => "/repo/apps/core",
            "reply_context" => "[Context] channel=abc\nfix the flake"
          }
        },
        overrides
      )
    )
  end

  # A finished phone call's notice, as core builds it for the chat the call
  # was asked from.
  defp call_notice(target) do
    row = Map.merge(%{id: "pc_1", status: "ended", origin_kind: "chat", thread: nil}, target)
    {:ok, notice} = PhoneCallContinuation.notice(row)
    notice
  end

  # The owner's own message on a chat channel, as its adapter parses it.
  defp owner_message(channel, chat_id, owner) do
    Message.new!(%{
      id: "#{channel}-owner-1",
      content: "Anything new from the clinic?",
      sender: owner,
      channel: channel,
      chat_id: chat_id,
      reply_target: chat_id,
      metadata: %{user_id: owner}
    })
  end

  # The real gateway, with this test as the agent its turns are handed to.
  defp turn_opts, do: [agent: TurnSink, agent_server: self()]

  defp ingest_opts(channel), do: [channel: channel, agent: TurnSink, agent_server: self()]

  # The turn the gateway handed off replies; what its channel posted for it.
  defp reply_posted do
    assert_receive {:turn, turn}
    assert :ok = turn.reply_fn.({:text, @dictated})
    assert_receive {:posted, body}
    body
  end

  defp stub_posts(name, response) do
    test_pid = self()

    Req.Test.stub(name, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:posted, Jason.decode!(body)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(response))
    end)
  end

  # Slack and Discord with an owner to re-enter as, their sends answered by
  # this test.
  defp chat_channels(_ctx) do
    previous = Map.new([:slack, :discord], &{&1, Application.fetch_env(:fermix_channels, &1)})

    Application.put_env(:fermix_channels, :slack,
      enabled: true,
      mode: :webhook,
      bot_token: "xoxb-test-token",
      signing_secret: "slack-signing-secret",
      owner_user_id: "U0OWNER1",
      req_options: [plug: {Req.Test, :report_previews_slack}]
    )

    Application.put_env(:fermix_channels, :discord,
      enabled: true,
      mode: :gateway,
      bot_token: "discord-bot-token",
      bot_user_id: "999",
      owner_user_id: "111",
      req_options: [plug: {Req.Test, :report_previews_discord}]
    )

    on_exit(fn -> Enum.each(previous, &restore_channel/1) end)
    :ok
  end

  defp restore_channel({key, {:ok, value}}), do: Application.put_env(:fermix_channels, key, value)
  defp restore_channel({key, :error}), do: Application.delete_env(:fermix_channels, key)

  defp persist_identity do
    identity =
      Identity.new(%{"BUZZ_PRIVATE_KEY" => @nsec, "PATH" => "/fake/bin:/usr/bin"})

    assert {:ok, :created} = IdentityStore.upsert(identity)
    identity
  end

  # The ingest seam keeps the test off the live gateway; `agent_server` points at
  # this test's own live process so the liveness precondition passes.
  defp opts(_ctx) do
    test_pid = self()

    [
      agent_server: test_pid,
      agent: test_pid,
      ingest: fn messages, ingest_opts ->
        send(test_pid, {:ingested, messages, ingest_opts})
        :ok
      end
    ]
  end
end
