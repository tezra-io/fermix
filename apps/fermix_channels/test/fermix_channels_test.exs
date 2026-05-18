defmodule FermixChannelsTest do
  use ExUnit.Case
  doctest FermixChannels

  import ExUnit.CaptureLog

  test "greets the world" do
    assert FermixChannels.hello() == :world
  end

  describe "polling channel children" do
    test "starts Telegram poller only when enabled, readiness ready, and ingress authorized" do
      ready_report = %{status: :ready, failures: []}

      setup_required_report = %{
        status: :setup_required,
        failures: [%{component: "channel:telegram"}]
      }

      previous = Application.get_env(:fermix_channels, :telegram, [])
      Application.put_env(:fermix_channels, :telegram, enabled: true, owner_user_id: "111")
      on_exit(fn -> Application.put_env(:fermix_channels, :telegram, previous) end)

      assert [{FermixChannels.Telegram.Poller, []}] =
               FermixChannels.Application.polling_children([enabled: true], ready_report)

      assert [] =
               FermixChannels.Application.polling_children([enabled: true], setup_required_report)

      assert [] =
               FermixChannels.Application.polling_children([enabled: false], ready_report)
    end

    test "refuses to start Telegram poller when ingress allowlist is empty (F-02)" do
      ready_report = %{status: :ready, failures: []}

      previous = Application.get_env(:fermix_channels, :telegram, [])
      Application.put_env(:fermix_channels, :telegram, enabled: true)
      on_exit(fn -> Application.put_env(:fermix_channels, :telegram, previous) end)

      assert [] =
               FermixChannels.Application.polling_children([enabled: true], ready_report)
    end
  end

  describe "subprocess channel children" do
    test "starts Signal listener only when subprocess mode is enabled, ready, and authorized" do
      ready_report = %{status: :ready, failures: []}

      setup_required_report = %{
        status: :setup_required,
        failures: [%{component: "channel:signal"}]
      }

      config = [mode: :subprocess, enabled: true]

      previous = Application.get_env(:fermix_channels, :signal, [])
      Application.put_env(:fermix_channels, :signal, enabled: true, owner_user_id: "+1234")
      on_exit(fn -> Application.put_env(:fermix_channels, :signal, previous) end)

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

    test "refuses to start Signal listener when ingress allowlist is empty (F-02)" do
      ready_report = %{status: :ready, failures: []}

      previous = Application.get_env(:fermix_channels, :signal, [])
      Application.put_env(:fermix_channels, :signal, enabled: true, mode: :subprocess)
      on_exit(fn -> Application.put_env(:fermix_channels, :signal, previous) end)

      assert [] =
               FermixChannels.Application.subprocess_children(
                 [mode: :subprocess, enabled: true],
                 ready_report
               )
    end
  end

  describe "missing-ingress-authorization startup logs" do
    test "logs enabled ingress channels with no owner or allowlist" do
      previous_telegram = Application.get_env(:fermix_channels, :telegram, [])
      Application.put_env(:fermix_channels, :telegram, enabled: true)

      on_exit(fn ->
        Application.put_env(:fermix_channels, :telegram, previous_telegram)
      end)

      log =
        capture_log(fn ->
          FermixChannels.Application.log_missing_ingress_authorization(%{
            status: :ready,
            failures: []
          })
        end)

      assert log =~
               "telegram ingress is enabled but no owner_user_id or allowed_*_ids list is set"
    end

    test "does not log when a single ingress allowlist entry can act as owner" do
      previous_telegram = Application.get_env(:fermix_channels, :telegram, [])
      Application.put_env(:fermix_channels, :telegram, enabled: true, allowed_user_ids: ["111"])

      on_exit(fn ->
        Application.put_env(:fermix_channels, :telegram, previous_telegram)
      end)

      log =
        capture_log(fn ->
          FermixChannels.Application.log_missing_ingress_authorization(%{
            status: :ready,
            failures: []
          })
        end)

      refute log =~
               "telegram ingress is enabled but no owner_user_id or allowed_*_ids list is set"
    end
  end
end
