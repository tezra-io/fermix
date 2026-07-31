defmodule FermixChannels.Harness.ContinuationDispatcherTest do
  # async: false — the owner-id preconditions read the global
  # `:fermix_channels` channel config, which each test sets and restores.
  use ExUnit.Case, async: false

  alias FermixChannels.Gateway.Authorizer
  alias FermixChannels.Gateway.Source
  alias FermixChannels.Harness.ContinuationDispatcher
  alias FermixCore.Agents.ConversationKey

  setup do
    prior = Application.get_env(:fermix_channels, :telegram)
    Application.put_env(:fermix_channels, :telegram, enabled: true, owner_user_id: "999")

    on_exit(fn ->
      case prior do
        nil -> Application.delete_env(:fermix_channels, :telegram)
        value -> Application.put_env(:fermix_channels, :telegram, value)
      end
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
  end

  defp notice(overrides \\ %{}) do
    Map.merge(
      %{
        platform: "telegram",
        destination: "123",
        thread: nil,
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
