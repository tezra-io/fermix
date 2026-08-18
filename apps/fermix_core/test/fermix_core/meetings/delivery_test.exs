defmodule FermixCore.Meetings.DeliveryTest do
  # async: false — the stub seams below record their calls in one named Agent,
  # the `Jobs.DeliveryTest` precedent for a module-shaped injection seam.
  use ExUnit.Case, async: false

  alias FermixCore.Meetings.Delivery

  @agent :meetings_delivery_test_stub

  defmodule StubChannelSend do
    @agent :meetings_delivery_test_stub

    # Only the platforms the test declares are configured send targets; every
    # other origin platform must fall through to the owner inbox.
    def resolve_adapter(platform, opts) do
      Agent.update(@agent, fn state ->
        %{state | resolve_opts: state.resolve_opts ++ [{platform, opts}]}
      end)

      if platform in Agent.get(@agent, & &1.platforms) do
        {:ok, __MODULE__}
      else
        {:error, {:unsupported_delivery_platform, platform}}
      end
    end

    def with_timeout(timeout_ms, fun) do
      Agent.update(@agent, fn state -> %{state | timeouts: state.timeouts ++ [timeout_ms]} end)
      fun.()
    end

    def send(platform, destination, text, send_opts, opts) do
      call = %{
        platform: platform,
        destination: destination,
        text: text,
        send_opts: send_opts,
        opts: opts
      }

      Agent.get_and_update(@agent, fn state ->
        {next, rest} = next_result(state.results)
        {next, %{state | calls: state.calls ++ [call], results: rest}}
      end)
    end

    defp next_result([]), do: {:ok, []}
    defp next_result([head | rest]), do: {head, rest}
  end

  defmodule StubOwnerInbox do
    @agent :meetings_delivery_test_stub

    def resolve(opts) when is_list(opts) do
      Agent.get_and_update(@agent, fn state ->
        {state.owner_inbox, %{state | owner_calls: state.owner_calls + 1}}
      end)
    end
  end

  @meeting %{
    url: "https://meet.google.com/abc-defg-hij",
    title: "Weekly sync",
    artifact_dir: "/tmp/fermix-test/meetings/mtg_AAAAAAAAAAA",
    duration_ms: 42 * 60_000,
    participants_peak: 5,
    end_reason: :meeting_ended,
    origin_session_id: "telegram:123:root"
  }

  setup do
    start_supervised!(%{
      id: @agent,
      start: {Agent, :start_link, [fn -> initial_state() end, [name: @agent]]}
    })

    :ok
  end

  defp initial_state do
    %{
      platforms: ["telegram", "slack"],
      results: [],
      calls: [],
      resolve_opts: [],
      timeouts: [],
      owner_calls: 0,
      owner_inbox: {:ok, %{platform: "telegram", destination: "owner-1", thread_scope: "root"}}
    }
  end

  defp put(key, value), do: Agent.update(@agent, &Map.put(&1, key, value))
  defp state, do: Agent.get(@agent, & &1)
  defp calls, do: state().calls

  defp deliver(meeting \\ @meeting, text \\ "Notes body", extra_opts \\ []) do
    Delivery.deliver(meeting, text, seams() ++ extra_opts)
  end

  defp seams do
    test_pid = self()

    [
      channel_send: StubChannelSend,
      owner_inbox: StubOwnerInbox,
      sleep_fn: fn ms -> send(test_pid, {:slept, ms}) end
    ]
  end

  describe "origin resolution" do
    test "a root-scoped channel origin sends to that conversation with no thread opts" do
      assert {:ok, :sent} = deliver()

      assert [%{platform: "telegram", destination: "123", send_opts: []}] = calls()
      assert state().owner_calls == 0
    end

    test "a threaded channel origin carries both platforms' thread options" do
      meeting = %{@meeting | origin_session_id: "slack:C42:1712345.6789"}

      assert {:ok, :sent} = deliver(meeting)

      assert [%{platform: "slack", destination: "C42", send_opts: send_opts}] = calls()
      assert send_opts[:thread_ts] == "1712345.6789"
      assert send_opts[:message_thread_id] == "1712345.6789"
    end

    test "an origin platform that is not a configured send target goes to the owner inbox" do
      meeting = %{@meeting | origin_session_id: "matrix:!room:root"}

      assert {:ok, :sent} = deliver(meeting)

      assert [%{platform: "telegram", destination: "owner-1", send_opts: []}] = calls()
      assert state().owner_calls == 1
    end

    test "an unparseable origin session id goes to the owner inbox" do
      meeting = %{@meeting | origin_session_id: "cron_20260817_101500"}

      assert {:ok, :sent} = deliver(meeting)

      assert [%{platform: "telegram", destination: "owner-1"}] = calls()
      assert state().owner_calls == 1
    end

    test "a nil origin goes to the owner inbox without consulting adapter resolution" do
      meeting = %{@meeting | origin_session_id: nil}

      assert {:ok, :sent} = deliver(meeting)

      assert [%{platform: "telegram", destination: "owner-1"}] = calls()
      assert state().resolve_opts == []
      assert state().owner_calls == 1
    end

    test "no owner inbox is a terminal :no_delivery_target and nothing is sent" do
      put(:owner_inbox, :no_delivery_target)
      meeting = %{@meeting | origin_session_id: nil}

      assert {:error, :no_delivery_target} = deliver(meeting)
      assert calls() == []
    end
  end

  describe "retry ladder" do
    test "a transient failure is retried up to three attempts with the fixed backoff" do
      put(:results, [{:error, :timeout}, {:error, {:transport, :closed}}, :ok])

      assert {:ok, :sent} = deliver()
      assert length(calls()) == 3
      assert_received {:slept, 5_000}
      assert_received {:slept, 25_000}
    end

    test "a transient failure that never clears exhausts the bound and reports the last reason" do
      put(:results, [{:error, :timeout}, {:error, :timeout}, {:error, {:http_status, 503}}])

      assert {:error, {:delivery_failed, {:http_status, 503}}} = deliver()
      assert length(calls()) == 3
    end

    test "a non-transient failure fails on the first attempt with no backoff" do
      put(:results, [{:error, {:permanent, :authentication}}, :ok])

      assert {:error, {:delivery_failed, {:permanent, :authentication}}} = deliver()
      assert length(calls()) == 1
      refute_received {:slept, _ms}
    end

    test "each attempt runs under the send watchdog with ChannelSend's own loop disabled" do
      put(:results, [{:error, :timeout}, :ok])

      assert {:ok, :sent} = deliver()
      assert state().timeouts == [60_000, 60_000]
      assert Enum.all?(calls(), &(&1.opts[:delivery_max_attempts] == 1))
    end

    test "a result outside the send contract is terminal, not retried" do
      put(:results, [:sent_probably])

      assert {:error, {:delivery_failed, {:unexpected_delivery_result, :sent_probably}}} =
               deliver()

      assert length(calls()) == 1
    end
  end

  describe "transient?/1" do
    test "timeouts, closed transports and 5xx are weather" do
      assert Delivery.transient?(:timeout)
      assert Delivery.transient?({:timeout, :send})
      assert Delivery.transient?(:delivery_timeout)
      assert Delivery.transient?(:closed)
      assert Delivery.transient?(:transport_closed)
      assert Delivery.transient?({:transport, :econnreset})
      assert Delivery.transient?(%Mint.TransportError{reason: :closed})
      assert Delivery.transient?(%Req.TransportError{reason: :nxdomain})
      assert Delivery.transient?({:http_status, 500})
      assert Delivery.transient?({:http_status, 503, "unavailable"})
    end

    test "4xx, permanent kinds, crashes and unknown shapes are terminal" do
      refute Delivery.transient?({:http_status, 404})
      refute Delivery.transient?({:http_status, 429})
      refute Delivery.transient?({:permanent, :adapter_unavailable})
      refute Delivery.transient?({:delivery_crashed, :worker_crash})
      refute Delivery.transient?({:unsupported_delivery_platform, "matrix"})
      refute Delivery.transient?(%Mint.TransportError{reason: :not_a_transient_reason})
      refute Delivery.transient?(:something_new)
    end
  end

  describe "delivered text" do
    test "header, summary and artifact path in one fixed shape" do
      assert {:ok, :sent} = deliver()

      assert [%{text: text}] = calls()

      assert text ==
               """
               📝 Meeting notes — Weekly sync (42m, 5 participants)
               Notes body

               Transcript & artifacts: /tmp/fermix-test/meetings/mtg_AAAAAAAAAAA\
               """
    end

    test "an untitled meeting is headed by its url" do
      assert {:ok, :sent} = deliver(%{@meeting | title: nil})

      assert [%{text: text}] = calls()
      assert String.starts_with?(text, "📝 Meeting notes — https://meet.google.com/abc-defg-hij (")
    end

    test "a partial capture is labelled on the first line with how far the notes reach" do
      meeting = %{@meeting | end_reason: :sidecar_crashed, duration_ms: 432_000}

      assert {:ok, :sent} = deliver(meeting)

      assert [%{text: text}] = calls()

      assert String.starts_with?(
               text,
               "⚠️ Capture ended early (sidecar_crashed) — notes cover the first 07:12 only.\n📝 "
             )
    end

    test "every partial-capture reason is labelled and no normal ending is" do
      for reason <- [:sidecar_crashed, :rtms_stream_lost, :stt_stream_failed] do
        assert {:ok, :sent} = deliver(%{@meeting | end_reason: reason})
        assert %{text: text} = List.last(calls())
        assert String.starts_with?(text, "⚠️ Capture ended early (#{reason})")
      end

      for reason <- [:meeting_ended, :host_removed, :max_duration, :alone_timeout, nil] do
        assert {:ok, :sent} = deliver(%{@meeting | end_reason: reason})
        assert %{text: text} = List.last(calls())
        assert String.starts_with?(text, "📝 Meeting notes")
      end
    end
  end
end
