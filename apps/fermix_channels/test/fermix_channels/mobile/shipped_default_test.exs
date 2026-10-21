defmodule FermixChannels.Mobile.ShippedDefaultTest do
  @moduledoc """
  The phone channel ships enabled, and its local-network announcement ships
  off. A `config.toml` with no `[fermix_channels.mobile]` section boots with the
  listener among the transport children and no announcement, and an operator's
  `enabled = false` or `advertise_mdns = true` still wins, because the boot
  hydration path (`ConfigStore.bootstrap_runtime_config/1`) merges the persisted
  TOML over the compile-time default.

  The default is read from `config/config.exs` with `Config.Reader`, the API the
  release config-provider chain uses, so the test asserts the shipped value and
  not one leaked into app env by another module. The suite itself pins the
  channel off in `config/test.exs`; this module puts the shipped value in app
  env for its own tests and restores the suite's afterwards, with every other
  key the hydration writes (`:fermix_core`, `:fermix_web`) and the settings
  baseline it records.
  """

  use ExUnit.Case, async: false

  alias FermixChannels.Gateway.ChannelRegistry
  alias FermixChannels.Mobile.Iroh
  alias FermixChannels.Mobile.Supervisor, as: MobileSupervisor
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.RestartState
  alias FermixTestSupport.SafeRm

  @ready %{status: :ready}
  @config_exs Path.expand("../../../../../config/config.exs", __DIR__)

  # An install that never wrote a phone section.
  @no_mobile_toml """
  [fermix_core.agent]
  name = "fermix"
  """

  setup do
    previous_home = System.get_env("FERMIX_HOME")
    previous_channels = Application.get_all_env(:fermix_channels)
    previous_core = Application.get_all_env(:fermix_core)
    previous_web = Application.get_all_env(:fermix_web)

    home = SafeRm.make_tmp_dir!("mobile-shipped-default")
    System.put_env("FERMIX_HOME", home)
    Application.put_env(:fermix_channels, :mobile, shipped_mobile_default(:prod))

    on_exit(fn ->
      restore_env(:fermix_channels, previous_channels)
      restore_env(:fermix_core, previous_core)
      restore_env(:fermix_web, previous_web)

      case previous_home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      # The hydration recorded this test's file as the settings baseline; the
      # suite's own home is the one the rest of the run compares against.
      :ok = RestartState.record_persisted_baseline()
      SafeRm.rm_rf!(home)
    end)

    {:ok, home: home}
  end

  test "dev and prod builds ship the phone channel enabled" do
    for env <- [:dev, :prod] do
      assert Keyword.fetch!(shipped_mobile_default(env), :enabled) == true,
             "config/config.exs ships [fermix_channels.mobile] off for #{env}"
    end
  end

  test "dev and prod builds ship the local-network announcement off" do
    for env <- [:dev, :prod] do
      assert Keyword.fetch!(shipped_mobile_default(env), :advertise_mdns) == false,
             "config/config.exs ships [fermix_channels.mobile] advertise_mdns on for #{env}"
    end
  end

  test "a home with no mobile section boots with the listener started", %{home: home} do
    write_config!(home, @no_mobile_toml)

    assert :ok = ConfigStore.bootstrap_runtime_config(supervised: false)

    assert mobile_enabled?()
    assert {MobileSupervisor, []} in ChannelRegistry.transport_children(@ready)
    assert boot_switch().()
  end

  test "an explicit enabled = false keeps the listener off", %{home: home} do
    write_config!(home, @no_mobile_toml <> "\n[fermix_channels.mobile]\nenabled = false\n")

    assert :ok = ConfigStore.bootstrap_runtime_config(supervised: false)

    refute mobile_enabled?()
    # The subtree stays registered so the switch can turn it on live; its own
    # start reads the switch and starts nothing while it is off.
    assert {MobileSupervisor, []} in ChannelRegistry.transport_children(@ready)
    refute boot_switch().()
  end

  test "a home with no mobile section hydrates with the announcement off", %{home: home} do
    write_config!(home, @no_mobile_toml)

    assert :ok = ConfigStore.bootstrap_runtime_config(supervised: false)

    assert Keyword.fetch!(mobile_config(), :advertise_mdns) == false
  end

  # Remote reach (M62 D4) is on unless the operator turns it off: the code
  # holds the default, so the shipped config names no `iroh` key at all.
  test "a home with no mobile section hydrates with remote reach on", %{home: home} do
    refute Keyword.has_key?(shipped_mobile_default(:prod), :iroh)
    write_config!(home, @no_mobile_toml)

    assert :ok = ConfigStore.bootstrap_runtime_config(supervised: false)

    assert Iroh.switch_on?()
  end

  test "an explicit iroh = false turns remote reach off", %{home: home} do
    write_config!(home, @no_mobile_toml <> "\n[fermix_channels.mobile]\niroh = false\n")

    assert :ok = ConfigStore.bootstrap_runtime_config(supervised: false)

    refute Iroh.switch_on?()
    assert mobile_enabled?()
  end

  test "an explicit advertise_mdns = true turns the announcement on", %{home: home} do
    write_config!(home, @no_mobile_toml <> "\n[fermix_channels.mobile]\nadvertise_mdns = true\n")

    assert :ok = ConfigStore.bootstrap_runtime_config(supervised: false)

    assert Keyword.fetch!(mobile_config(), :advertise_mdns) == true
    assert mobile_enabled?()
  end

  defp write_config!(home, contents), do: File.write!(Path.join(home, "config.toml"), contents)

  defp mobile_enabled?, do: Keyword.get(mobile_config(), :enabled) == true

  defp mobile_config, do: Application.get_env(:fermix_channels, :mobile, [])

  defp boot_switch do
    {MobileSupervisor, opts} = MobileSupervisor.boot_child("shipped-default-epoch")
    Keyword.fetch!(opts, :switch)
  end

  # The phone block a fresh BEAM of `env` boots with, straight from the shipped config.
  defp shipped_mobile_default(env) do
    assert File.regular?(@config_exs), "config/config.exs not found at #{@config_exs}"

    @config_exs
    |> Config.Reader.read!(env: env, target: :host)
    |> Keyword.fetch!(:fermix_channels)
    |> Keyword.fetch!(:mobile)
  end

  defp restore_env(app, captured) do
    Enum.each(captured, fn {key, value} -> Application.put_env(app, key, value) end)

    app
    |> Application.get_all_env()
    |> Enum.reject(fn {key, _value} -> Keyword.has_key?(captured, key) end)
    |> Enum.each(fn {key, _value} -> Application.delete_env(app, key) end)
  end
end
