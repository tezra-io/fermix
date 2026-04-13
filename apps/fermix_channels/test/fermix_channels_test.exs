defmodule FermixChannelsTest do
  use ExUnit.Case
  doctest FermixChannels

  test "greets the world" do
    assert FermixChannels.hello() == :world
  end

  describe "polling channel children" do
    test "starts Telegram polling only when polling is enabled and readiness is complete" do
      ready_report = %{status: :ready, failures: []}

      setup_required_report = %{
        status: :setup_required,
        failures: [%{component: "channel:telegram"}]
      }

      config = [mode: :polling, enabled: true]

      assert [{FermixChannels.Telegram.Poller, []}] =
               FermixChannels.Application.polling_children(config, ready_report)

      assert [] = FermixChannels.Application.polling_children(config, setup_required_report)
      assert [] = FermixChannels.Application.polling_children([mode: :webhook], ready_report)

      assert [] =
               FermixChannels.Application.polling_children(
                 [mode: :polling, enabled: false],
                 ready_report
               )
    end
  end
end
