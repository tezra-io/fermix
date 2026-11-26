defmodule FermixChannels.Bench.RunnerTest do
  use ExUnit.Case, async: false

  alias FermixChannels.Bench.Runner

  # The bench's mock provider with one thing changed: the text its turn ends
  # with. A run on it must fail, not count the turn as processed.
  defmodule WrongReplyProvider do
    @behaviour FermixCore.Providers.Adapter

    alias FermixCore.Bench.MockProvider

    @impl true
    def chat(messages, capabilities, opts),
      do: MockProvider.chat(messages, capabilities, wrong_reply(opts))

    @impl true
    def continue(state, results, opts),
      do: MockProvider.continue(state, results, wrong_reply(opts))

    @impl true
    defdelegate to_provider_tools(capabilities), to: MockProvider

    @impl true
    defdelegate parse_tool_calls(response), to: MockProvider

    @impl true
    defdelegate parse_response(response), to: MockProvider

    @impl true
    defdelegate supports_streaming?(), to: MockProvider

    defp wrong_reply(opts), do: Keyword.put(opts, :bench_response, "not the scenario's reply")
  end

  test "exposes stage order in pipeline order" do
    order = Runner.stage_order()

    assert Enum.find_index(order, &(&1 == "dispatcher_normalize")) <
             Enum.find_index(order, &(&1 == "ingress_authorize"))

    assert Enum.find_index(order, &(&1 == "ingress_authorize")) <
             Enum.find_index(order, &(&1 == "agent_mailbox"))
  end

  test "does not list a CLI media scenario" do
    refute "cli_send_media" in Runner.list_scenarios()
  end

  test "runs a shared scenario and returns stage stats" do
    assert {:ok, report} =
             Runner.run(
               scenarios: ["shared_text_minimal"],
               samples: 2,
               warmup: 1,
               output: nil
             )

    scenario = report.scenarios["shared_text_minimal"]
    assert scenario.messages_dispatched == 2
    assert scenario.messages_processed == 2
    assert scenario.wall_time_us > 0
    assert scenario.throughput_messages_per_second > 0
    assert scenario.stages["dispatcher_normalize"].count == 2
    assert scenario.stages["agent_message"].count == 2
    assert scenario.stages["provider_call"].count == 2
  end

  test "processes all FIFO messages in the contention scenario" do
    assert {:ok, report} =
             Runner.run(
               scenarios: ["shared_fifo_contention"],
               samples: 5,
               warmup: 0,
               output: nil
             )

    scenario = report.scenarios["shared_fifo_contention"]
    assert scenario.messages_dispatched == 5
    assert scenario.messages_processed == scenario.messages_dispatched
    assert scenario.stages["dispatcher_normalize"].count == 5
    assert scenario.stages["agent_message"].count == scenario.messages_processed
  end

  test "reports throughput for the multi-conversation scenario" do
    assert {:ok, report} =
             Runner.run(
               scenarios: ["shared_multi_conv_throughput"],
               samples: 101,
               warmup: 0,
               output: nil
             )

    scenario = report.scenarios["shared_multi_conv_throughput"]
    assert scenario.messages_dispatched == 101
    assert scenario.messages_processed == 101
    assert scenario.wall_time_us > 0
    assert scenario.throughput_messages_per_second > 0
    assert scenario.stages["agent_message"].count == 101
  end

  test "reports long-history setup work separately from measured samples" do
    assert {:ok, report} =
             Runner.run(
               scenarios: ["shared_text_long_history"],
               samples: 1,
               warmup: 1,
               output: nil
             )

    scenario = report.scenarios["shared_text_long_history"]
    assert scenario.setup.history_conversations_seeded == 2
    assert scenario.setup.history_messages_seeded == 200
    assert scenario.messages_processed == 1
    assert scenario.stages["history_fetch"].count == 1
  end

  test "runs cold-start samples with a fresh agent per sample" do
    assert {:ok, report} =
             Runner.run(
               scenarios: ["shared_cold_start"],
               samples: 2,
               warmup: 0,
               output: nil
             )

    scenario = report.scenarios["shared_cold_start"]
    assert scenario.messages_dispatched == 2
    assert scenario.messages_processed == 2
    assert scenario.setup.environments_started == 2
  end

  test "runs adapter scenarios and reports adapter stages" do
    assert {:ok, report} =
             Runner.run(
               scenarios: ["telegram_send_short_text"],
               samples: 1,
               warmup: 0,
               output: nil
             )

    scenario = report.scenarios["telegram_send_short_text"]
    assert scenario.messages_dispatched == 1
    assert scenario.messages_processed == 1
    assert scenario.stages["channel_render"].count == 1
    assert scenario.stages["channel_message"].count == 1
  end

  test "runs channel E2E smoke scenarios through dispatcher and adapter reply" do
    assert {:ok, report} =
             Runner.run(
               scenarios: ["telegram_e2e_text"],
               samples: 1,
               warmup: 0,
               output: nil
             )

    scenario = report.scenarios["telegram_e2e_text"]
    assert scenario.messages_dispatched == 1
    assert scenario.messages_processed == 1
    assert scenario.stages["dispatcher_normalize"].count == 1
    assert scenario.stages["agent_message"].count == 1
    assert scenario.stages["channel_message"].count >= 1
  end

  # MILESTONE_54 §17: the iMessage adapter against the bench's fake helper.
  test "runs every iMessage adapter scenario through the fake helper" do
    scenarios = [
      "imessage_parse_inbound",
      "imessage_send_short_text",
      "imessage_send_long_text_split",
      "imessage_send_media",
      "imessage_e2e_text"
    ]

    assert Enum.all?(scenarios, &(&1 in Runner.list_scenarios()))

    assert {:ok, report} = Runner.run(scenarios: scenarios, samples: 1, warmup: 0, output: nil)

    for name <- scenarios do
      assert report.scenarios[name].messages_processed == 1, name
    end

    assert report.scenarios["imessage_send_long_text_split"].stages["channel_message"].count > 1
    assert report.scenarios["imessage_e2e_text"].stages["agent_message"].count == 1
  end

  test "runs webhook idempotency smoke scenario" do
    assert {:ok, report} =
             Runner.run(
               scenarios: ["webhook_ingress_idempotency"],
               samples: 2,
               warmup: 0,
               output: nil
             )

    scenario = report.scenarios["webhook_ingress_idempotency"]
    assert scenario.messages_dispatched == 2
    assert scenario.messages_processed == 2
    assert scenario.stages["idempotency_check"].count == 2
  end

  test "fails a run whose turn replies with anything but its scenario's reply" do
    error =
      assert_raise RuntimeError, fn ->
        Runner.run(
          scenarios: ["shared_text_minimal"],
          samples: 2,
          warmup: 0,
          output: nil,
          provider: WrongReplyProvider
        )
      end

    assert error.message =~ "shared_text_minimal"
    assert error.message =~ ~s({:text, "not the scenario's reply"})
    assert error.message =~ ~s({:text, "bench final"})
  end

  test "fails a run whose parallel turns reply with anything but their scenario's reply" do
    assert_raise RuntimeError, ~r/shared_multi_conv_throughput.*not the scenario's reply/s, fn ->
      Runner.run(
        scenarios: ["shared_multi_conv_throughput"],
        samples: 3,
        warmup: 0,
        output: nil,
        provider: WrongReplyProvider
      )
    end
  end

  test "fails a channel E2E run whose turn replies with anything but its scenario's reply" do
    assert_raise RuntimeError, ~r/telegram_e2e_text.*not the scenario's reply/s, fn ->
      Runner.run(
        scenarios: ["telegram_e2e_text"],
        samples: 1,
        warmup: 0,
        output: nil,
        provider: WrongReplyProvider
      )
    end
  end

  test "accepts the iteration-cap reply as the max-iteration scenario's own" do
    assert {:ok, report} =
             Runner.run(
               scenarios: ["shared_text_max_iter"],
               samples: 1,
               warmup: 0,
               output: nil
             )

    assert report.scenarios["shared_text_max_iter"].messages_processed == 1
  end

  # A sample's identity (a webhook event id, the media a send claims) must not
  # repeat across the warmup, the measured samples or a second pass in the same
  # VM, as `--runs` makes: a repeat is refused, or skipped as already sent.
  test "gives every webhook sample its own event id across the warmup and every pass" do
    for _pass <- 1..2 do
      assert {:ok, report} =
               Runner.run(
                 scenarios: ["webhook_ingress_idempotency"],
                 samples: 2,
                 warmup: 2,
                 output: nil
               )

      assert stage_count(report, "webhook_ingress_idempotency", "idempotency_check") == 2
    end
  end

  test "sends every media sample across the warmup and every pass" do
    for _pass <- 1..2 do
      assert {:ok, report} =
               Runner.run(scenarios: ["telegram_send_media"], samples: 2, warmup: 2, output: nil)

      assert stage_count(report, "telegram_send_media", "channel_message") == 2
    end
  end

  test "rejects unknown scenarios" do
    assert {:error, {:unknown_scenarios, ["missing"]}} =
             Runner.run(scenarios: ["missing"], samples: 1, warmup: 0, output: nil)
  end

  defp stage_count(report, scenario, stage) do
    case report.scenarios[scenario].stages[stage] do
      nil -> 0
      stats -> stats.count
    end
  end
end
