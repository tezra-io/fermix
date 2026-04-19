defmodule FermixChannelsTest do
  use ExUnit.Case
  doctest FermixChannels

  test "greets the world" do
    assert FermixChannels.hello() == :world
  end

  describe "polling channel children" do
    test "starts Telegram poller when enabled and readiness is complete" do
      ready_report = %{status: :ready, failures: []}

      setup_required_report = %{
        status: :setup_required,
        failures: [%{component: "channel:telegram"}]
      }

      assert [{FermixChannels.Telegram.Poller, []}] =
               FermixChannels.Application.polling_children([enabled: true], ready_report)

      assert [] =
               FermixChannels.Application.polling_children([enabled: true], setup_required_report)

      assert [] =
               FermixChannels.Application.polling_children([enabled: false], ready_report)
    end
  end

  describe "subprocess channel children" do
    test "starts Signal listener only when subprocess mode is enabled and readiness is complete" do
      ready_report = %{status: :ready, failures: []}

      setup_required_report = %{
        status: :setup_required,
        failures: [%{component: "channel:signal"}]
      }

      config = [mode: :subprocess, enabled: true]

      assert [{FermixChannels.Signal.Listener, []}] =
               FermixChannels.Application.subprocess_children(config, ready_report)

      assert [] = FermixChannels.Application.subprocess_children(config, setup_required_report)
      assert [] = FermixChannels.Application.subprocess_children([mode: :webhook], ready_report)

      assert [] =
               FermixChannels.Application.subprocess_children(
                 [mode: :subprocess, enabled: false],
                 ready_report
               )
    end
  end
end
