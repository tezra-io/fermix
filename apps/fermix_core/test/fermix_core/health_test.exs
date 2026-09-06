defmodule FermixCore.HealthTest do
  use ExUnit.Case, async: false

  alias FermixCore.BuildInfo
  alias FermixCore.Health
  alias FermixCore.Setup.ConfigStore

  setup do
    providers = Application.get_env(:fermix_core, :providers)
    realtime = Application.get_env(:fermix_core, :realtime)
    telegram = Application.get_env(:fermix_channels, :telegram)
    whatsapp = Application.get_env(:fermix_channels, :whatsapp)
    discord = Application.get_env(:fermix_channels, :discord)
    slack = Application.get_env(:fermix_channels, :slack)
    signal = Application.get_env(:fermix_channels, :signal)
    acp = Application.get_env(:fermix_channels, :acp)
    fermix_home = System.get_env("FERMIX_HOME")

    on_exit(fn ->
      restore_env(:fermix_core, :providers, providers)
      restore_env(:fermix_core, :realtime, realtime)
      restore_env(:fermix_channels, :telegram, telegram)
      restore_env(:fermix_channels, :whatsapp, whatsapp)
      restore_env(:fermix_channels, :discord, discord)
      restore_env(:fermix_channels, :slack, slack)
      restore_env(:fermix_channels, :signal, signal)
      restore_env(:fermix_channels, :acp, acp)

      case fermix_home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end
    end)

    :ok
  end

  test "reports config, provider, channel, and memory status and marks missing long-running channels degraded" do
    tmp_home = Path.join(System.tmp_dir!(), "fermix-health-#{System.unique_integer([:positive])}")
    System.put_env("FERMIX_HOME", tmp_home)

    Application.put_env(:fermix_core, :providers,
      openai: [auth_mode: :api_key, api_key: "sk-test-123"]
    )

    Application.put_env(:fermix_core, :realtime, enabled: false)

    Application.put_env(:fermix_channels, :telegram,
      enabled: true,
      mode: :webhook,
      bot_token: "bot"
    )

    Application.put_env(:fermix_channels, :whatsapp, enabled: false, mode: :webhook)
    Application.put_env(:fermix_channels, :discord, enabled: false, mode: :gateway)
    Application.put_env(:fermix_channels, :slack, enabled: false, mode: :webhook)

    Application.put_env(:fermix_channels, :signal,
      enabled: true,
      mode: :subprocess,
      account: "+15550001111"
    )

    report =
      Health.report(
        boot_report: %{
          status: :ready,
          failures: [],
          config_path: ConfigStore.path(),
          restart_required?: false
        }
      )

    assert report.status == :degraded
    assert report.version == BuildInfo.product_version()
    assert report.config.path == Path.join(tmp_home, "config.toml")
    assert report.config.home == tmp_home

    assert report.config.workspace == %{
             workspace: Path.join(tmp_home, "workspace"),
             grants: Path.join(tmp_home, "grants"),
             bootstrap: Path.join(tmp_home, "bootstrap"),
             skills: Path.join(tmp_home, "skills"),
             plugins: Path.join(tmp_home, "plugins"),
             browser: Path.join(tmp_home, "browser"),
             journals: Path.join(tmp_home, "journals"),
             realtime: Path.join(tmp_home, "realtime"),
             mobile: Path.join(tmp_home, "mobile"),
             traces: Path.join(tmp_home, "traces"),
             logs: Path.join(tmp_home, "logs")
           }

    assert [%{name: "openai", status: :ready, auth_mode: :api_key, primary: true}] =
             report.providers

    # A stale `mode: :webhook` must NOT suppress the liveness answer: the
    # registry starts the poller regardless, so a dead poller is degraded.
    assert Enum.any?(report.channels, fn channel ->
             channel.name == "telegram" and channel.status == :degraded and
               channel.mode == :webhook and channel.process_alive == false
           end)

    assert Enum.any?(report.channels, fn channel ->
             channel.name == "signal" and channel.status == :degraded and
               channel.mode == :subprocess and channel.process_alive == false
           end)

    assert report.memory.conversation_store == :ready
    assert report.memory.store == :ready

    assert report.realtime == %{
             enabled: false,
             status: :disabled,
             provider: nil,
             model: nil,
             socket_path: nil,
             socket_alive: nil,
             active_sessions: 0,
             active_clients: 0,
             companion_connected?: false
           }
  end

  test "reports realtime degraded when enabled and expected socket process is absent" do
    tmp_home = Path.join(System.tmp_dir!(), "fermix-health-#{System.unique_integer([:positive])}")
    System.put_env("FERMIX_HOME", tmp_home)

    Application.put_env(:fermix_core, :realtime,
      enabled: true,
      provider: "openai",
      model: "gpt-realtime-2"
    )

    report =
      Health.report(
        boot_report: %{
          status: :ready,
          failures: [],
          config_path: ConfigStore.path(),
          restart_required?: false
        },
        process_resolver: fn _name -> nil end
      )

    assert report.status == :degraded
    assert report.realtime.enabled == true
    assert report.realtime.status == :degraded
    assert report.realtime.socket_path == Path.join(tmp_home, "realtime.sock")
    assert report.realtime.socket_alive == false
  end

  # The ACP surface is a transport like any other channel, so /health lists it
  # (M29 §9 item 7): disabled when off, degraded when enabled with no listener.
  test "lists the acp transport and marks it degraded when its listener is absent" do
    tmp_home = Path.join(System.tmp_dir!(), "fermix-health-#{System.unique_integer([:positive])}")
    System.put_env("FERMIX_HOME", tmp_home)

    Application.put_env(:fermix_core, :realtime, enabled: false)
    Application.put_env(:fermix_channels, :acp, enabled: false, mode: :gateway)

    disabled = health_report(fn _name -> nil end)

    assert %{name: "acp", status: :disabled, enabled: false, process_alive: nil} =
             channel(disabled, "acp")

    Application.put_env(:fermix_channels, :acp, enabled: true, mode: :gateway)

    degraded = health_report(fn _name -> nil end)

    assert %{name: "acp", status: :degraded, enabled: true, process_alive: false} =
             channel(degraded, "acp")

    ready = health_report(fn _name -> self() end)

    assert %{name: "acp", status: :ready, enabled: true, process_alive: true} =
             channel(ready, "acp")
  end

  defp health_report(process_resolver, opts \\ []) do
    Health.report(
      [
        boot_report: %{
          status: :ready,
          failures: [],
          config_path: ConfigStore.path(),
          restart_required?: false
        },
        process_resolver: process_resolver
      ] ++ opts
    )
  end

  describe "channel transport health" do
    test "reports telegram alive when the poller runs under a legacy webhook config" do
      Application.put_env(:fermix_channels, :telegram, enabled: true, mode: :webhook)
      on_exit(fn -> Application.delete_env(:fermix_channels, :telegram) end)

      report = health_report(fn _name -> self() end, transport_health: fn _key -> nil end)

      assert %{name: "telegram", status: :ready, mode: :webhook, process_alive: true} =
               channel(report, "telegram")
    end

    test "surfaces the poller's degraded transport while its process is alive" do
      Application.put_env(:fermix_channels, :telegram, enabled: true, mode: :webhook)
      on_exit(fn -> Application.delete_env(:fermix_channels, :telegram) end)

      degraded = %{status: :degraded, consecutive_failures: 312, since: DateTime.utc_now()}

      report = health_report(fn _name -> self() end, transport_health: fn _key -> degraded end)

      # The 27,394-failure outage ran with the poller process alive the whole
      # time. Liveness alone can never catch it; the published posture must.
      assert %{name: "telegram", status: :degraded, process_alive: true, transport: ^degraded} =
               channel(report, "telegram")
    end

    test "webhook-only channels report no transport child rather than a broken one" do
      Application.put_env(:fermix_channels, :slack, enabled: true, mode: :webhook)
      on_exit(fn -> Application.delete_env(:fermix_channels, :slack) end)

      report = health_report(fn _name -> nil end)

      assert %{name: "slack", status: :ready, process_alive: nil, transport: nil} =
               channel(report, "slack")
    end

    test "probes the acp transport through its endpoint, not its supervisor" do
      previous = Application.get_env(:fermix_channels, :acp)
      Application.put_env(:fermix_channels, :acp, enabled: true, mode: :gateway)
      on_exit(fn -> restore_env(:fermix_channels, :acp, previous) end)

      probed =
        health_report(fn name -> if name == FermixChannels.Channels.Acp.Endpoint, do: self() end)

      # An Endpoint that cannot bind returns :ignore and its Supervisor starts
      # around it, so keying on the Supervisor would report a bound socket that
      # does not exist.
      assert %{name: "acp", status: :ready, process_alive: true} = channel(probed, "acp")
    end
  end

  defp channel(report, name), do: Enum.find(report.channels, &(&1.name == name))

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  # M12 §2.3-9: one entry per configured provider (plus the primary), with
  # honest auth modes — never a hardcoded single "openai" card.
  test "reports every configured provider with the primary flagged" do
    tmp_home = Path.join(System.tmp_dir!(), "fermix-health-#{System.unique_integer([:positive])}")
    System.put_env("FERMIX_HOME", tmp_home)

    Application.put_env(:fermix_core, :providers,
      openai: [api_key: "sk-test-123"],
      anthropic: [api_key: "sk-ant-test", primary: true]
    )

    Application.put_env(:fermix_core, :realtime, enabled: false)
    Application.put_env(:fermix_channels, :telegram, enabled: false)
    Application.put_env(:fermix_channels, :whatsapp, enabled: false)
    Application.put_env(:fermix_channels, :discord, enabled: false)
    Application.put_env(:fermix_channels, :slack, enabled: false)
    Application.put_env(:fermix_channels, :signal, enabled: false)

    report =
      Health.report(
        boot_report: %{
          status: :ready,
          failures: [],
          config_path: ConfigStore.path(),
          restart_required?: false
        }
      )

    assert [
             %{name: "openai", auth_mode: :api_key, primary: false},
             %{name: "anthropic", auth_mode: :api_key, primary: true}
           ] = report.providers
  end

  # Restart truth has one owner. Reading it from the boot report would leave an
  # out-of-process settings write invisible until someone happened to save.
  test "restart_required? and restart_reasons come from the restart state" do
    report =
      Health.report(
        boot_report: %{
          status: :ready,
          failures: [],
          config_path: ConfigStore.path(),
          restart_required?: false
        },
        restart: %{
          required: true,
          reasons: [
            %{section: "providers", sentence: "Provider settings changed."},
            %{section: "realtime", sentence: "Voice settings changed."}
          ]
        }
      )

    assert report.restart_required?
    assert report.restart_reasons == ["providers", "realtime"]
  end

  # The nested combination the gating split creates, decided rather than left to
  # emerge: an advisory failure is by definition not a reason to call the daemon
  # unhealthy, and escalating it would rebuild the any-failure-is-setup_required
  # behaviour the split exists to remove.
  test "an advisory channel failure does not escalate the top-level verdict" do
    Application.put_env(:fermix_channels, :telegram, enabled: true, mode: :webhook)

    report =
      Health.report(
        boot_report: %{
          status: :ready,
          failures: [
            %{
              component: "channel:telegram",
              action: "Set the Telegram bot token.",
              gating: false,
              pane: "channels",
              detail_key: "channel:telegram"
            }
          ],
          config_path: ConfigStore.path(),
          restart_required?: false
        },
        restart: %{required: false, reasons: []}
      )

    assert report.status == :ready

    assert Enum.any?(report.channels, fn channel ->
             channel.name == "telegram" and channel.status == :setup_required
           end)
  end
end
