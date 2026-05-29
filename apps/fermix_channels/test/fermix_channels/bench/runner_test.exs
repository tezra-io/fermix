defmodule FermixChannels.Bench.RunnerTest do
  use ExUnit.Case, async: false

  alias FermixChannels.Bench.Runner

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
    assert scenario.messages_superseded == 0
    assert scenario.wall_time_us > 0
    assert scenario.throughput_messages_per_second > 0
    assert scenario.stages["dispatcher_normalize"].count == 2
    assert scenario.stages["agent_message"].count == 2
    assert scenario.stages["provider_call"].count == 2
  end

  test "surfaces superseded messages in the contention scenario" do
    assert {:ok, report} =
             Runner.run(
               scenarios: ["shared_single_flight_contention"],
               samples: 5,
               warmup: 0,
               output: nil
             )

    scenario = report.scenarios["shared_single_flight_contention"]
    assert scenario.messages_dispatched == 5
    assert scenario.messages_processed < scenario.messages_dispatched

    assert scenario.messages_superseded ==
             scenario.messages_dispatched - scenario.messages_processed

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
    assert scenario.messages_superseded == 0
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

  test "rejects unknown scenarios" do
    assert {:error, {:unknown_scenarios, ["missing"]}} =
             Runner.run(scenarios: ["missing"], samples: 1, warmup: 0, output: nil)
  end
end
