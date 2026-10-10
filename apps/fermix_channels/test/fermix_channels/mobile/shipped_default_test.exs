defmodule FermixChannels.Mobile.ShippedDefaultTest do
  @moduledoc """
  The phone channel ships enabled. A `config.toml` with no
  `[fermix_channels.mobile]` section boots with the listener among the transport
  children, and an operator's `enabled = false` still wins, because the boot
  hydration path (`ConfigStore.bootstrap_runtime_config/1`) merges the persisted
  TOML over the compile-time default.

  The default is read from `config/config.exs` with `Config.Reader`, the API the
  release config-provider chain uses, so the test asserts the shipped value and
  not one leaked into app env by another module. The suite itself pins the
  channel off in `config/test.exs`; this module puts the shipped value in app
  env for its own tests and restores the suite's afterwards.
  """

  use ExUnit.Case, async: false

  alias FermixChannels.Gateway.ChannelRegistry
  alias FermixChannels.Mobile.Supervisor, as: MobileSupervisor
  alias FermixCore.Setup.ConfigStore
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

    home = SafeRm.make_tmp_dir!("mobile-shipped-default")
    System.put_env("FERMIX_HOME", home)
    Application.put_env(:fermix_channels, :mobile, shipped_mobile_default(:prod))

    on_exit(fn ->
      restore_env(:fermix_channels, previous_channels)
      restore_env(:fermix_core, previous_core)

      case previous_home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

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

  test "a home with no mobile section boots with the listener started", %{home: home} do
    write_config!(home, @no_mobile_toml)

    assert :ok = ConfigStore.bootstrap_runtime_config(supervised: false)

    assert mobile_enabled?()
    assert {MobileSupervisor, []} in ChannelRegistry.transport_children(@ready)
  end

  test "an explicit enabled = false keeps the listener off", %{home: home} do
    write_config!(home, @no_mobile_toml <> "\n[fermix_channels.mobile]\nenabled = false\n")

    assert :ok = ConfigStore.bootstrap_runtime_config(supervised: false)

    refute mobile_enabled?()
    refute Enum.any?(ChannelRegistry.transport_children(@ready), &mobile_child?/1)
  end

  defp write_config!(home, contents), do: File.write!(Path.join(home, "config.toml"), contents)

  defp mobile_enabled? do
    :fermix_channels
    |> Application.get_env(:mobile, [])
    |> Keyword.get(:enabled) == true
  end

  defp mobile_child?({child, _opts}), do: child == MobileSupervisor

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
