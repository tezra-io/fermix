defmodule FermixCore.HealthTest do
  use ExUnit.Case, async: false

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
    fermix_home = System.get_env("FERMIX_HOME")

    on_exit(fn ->
      restore_env(:fermix_core, :providers, providers)
      restore_env(:fermix_core, :realtime, realtime)
      restore_env(:fermix_channels, :telegram, telegram)
      restore_env(:fermix_channels, :whatsapp, whatsapp)
      restore_env(:fermix_channels, :discord, discord)
      restore_env(:fermix_channels, :slack, slack)
      restore_env(:fermix_channels, :signal, signal)

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
    assert report.version == to_string(Application.spec(:fermix_core, :vsn))
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
             traces: Path.join(tmp_home, "traces"),
             logs: Path.join(tmp_home, "logs")
           }

    assert [%{name: "openai", status: :ready, auth_mode: :api_key, primary: true}] =
             report.providers

    assert Enum.any?(report.channels, fn channel ->
             channel.name == "telegram" and channel.status == :ready and
               channel.mode == :webhook and channel.process_alive == nil
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
end
