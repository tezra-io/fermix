defmodule FermixChannelsTest do
  use ExUnit.Case
  doctest FermixChannels

  import ExUnit.CaptureLog

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

  describe "command owner startup warnings" do
    test "logs enabled ingress channels missing a command owner" do
      previous_telegram = Application.get_env(:fermix_channels, :telegram, [])
      Application.put_env(:fermix_channels, :telegram, enabled: true)

      on_exit(fn ->
        Application.put_env(:fermix_channels, :telegram, previous_telegram)
      end)

      log =
        capture_log(fn ->
          FermixChannels.Application.warn_missing_command_owners(%{status: :ready, failures: []})
        end)

      assert log =~ "telegram ingress is enabled but no command owner is configured"
    end

    test "does not log when a single ingress allowlist entry can act as owner" do
      previous_telegram = Application.get_env(:fermix_channels, :telegram, [])
      Application.put_env(:fermix_channels, :telegram, enabled: true, allowed_user_ids: ["111"])

      on_exit(fn ->
        Application.put_env(:fermix_channels, :telegram, previous_telegram)
      end)

      log =
        capture_log(fn ->
          FermixChannels.Application.warn_missing_command_owners(%{status: :ready, failures: []})
        end)

      refute log =~ "telegram ingress is enabled but no command owner is configured"
    end
  end
end
