defmodule FermixChannels.Harness.ContinuationDispatcherTest do
  # async: false — the owner-id preconditions read the global
  # `:fermix_channels` channel config, which each test sets and restores.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias FermixChannels.Channels.Acp
  alias FermixChannels.Gateway.Authorizer
  alias FermixChannels.Gateway.Source
  alias FermixChannels.Harness.ContinuationDispatcher
  alias FermixCore.Acp.Identity
  alias FermixCore.Acp.IdentityStore
  alias FermixCore.Agents.ConversationKey
  alias FermixTestSupport.SafeRm

  # Published NIP-19 test vectors (see `nostr/key_test.exs`) — never live keys.
  @nsec "nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5"
  @public_hex "7e7e9c42a91bfef19fa929e5fda1b72e0ebc1a4c1141673e2794234d86addf4e"
  @npub "npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg"

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

      assert_receive {:ingested, [message], ingest_opts}, 1_000
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

      assert_receive {:ingested, [message], _opts}, 1_000

      assert {:ok, authorization} =
               message |> Source.from_message() |> Authorizer.resolve()

      assert authorization.trust == :operator
    end

    test "carries a thread through as the message thread", ctx do
      assert :ok = ContinuationDispatcher.dispatch(notice(%{thread: "77"}), opts(ctx))

      assert_receive {:ingested, [message], _opts}, 1_000
      assert message.thread_ts == "77"
      assert message.thread_scope == :thread
    end

    # The ledger persists the thread as text, while a Telegram forum topic arrives
    # as an integer: both must key the SAME conversation, or the continuation turn
    # loads none of the request it is meant to continue.
    test "keys the same conversation as the origin turn for an integer thread id", ctx do
      assert :ok = ContinuationDispatcher.dispatch(notice(%{thread: "456"}), opts(ctx))

      assert_receive {:ingested, [message], _opts}, 1_000

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

    test "refuses a notice with no delivery target", ctx do
      assert {:error, {:invalid_continuation_target, _}} =
               ContinuationDispatcher.dispatch(notice(%{destination: nil}), opts(ctx))
    end

    # The regression half of the client-owned arm: a framework-delivered origin
    # must build the same message it built before this feature existed.
    test "a framework-delivered origin carries no env, no cwd and no acp sentinel", ctx do
      assert :ok = ContinuationDispatcher.dispatch(notice(), opts(ctx))

      assert_receive {:ingested, [message], _opts}, 1_000
      assert message.session_env == nil
      assert message.request_cwd == nil
      refute Map.has_key?(message.metadata, Acp.turn_opt())
    end
  end

  # M29 §17.6(c) — the ACP session that launched the run is long gone; the turn
  # env comes from the durable identity record and nothing else.
  describe "dispatch/2 — client-owned origin" do
    test "dispatches with no configured owner and injects the persisted env + launch cwd",
         ctx do
      persist_identity()

      assert :ok = ContinuationDispatcher.dispatch(acp_notice(), opts(ctx))

      assert_receive {:ingested, [message], ingest_opts}, 1_000
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
      assert_receive {:ingested, [message], _opts}, 1_000

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
      assert_receive {:ingested, [message], _opts}, 1_000
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
