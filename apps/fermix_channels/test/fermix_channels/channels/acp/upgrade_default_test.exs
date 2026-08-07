defmodule FermixChannels.Channels.Acp.UpgradeDefaultTest do
  @moduledoc """
  The ACP surface ships enabled, and upgrading an existing install must not need
  a config edit to get it. A `config.toml` written before M29 carries no
  `[fermix_channels.acp]` section at all, so the boot hydration path
  (`config/runtime.exs` -> `ConfigStore.bootstrap_runtime_config/1`, the single
  entry point that turns the persisted TOML into Application env) has to leave
  the shipped compile-time default intact instead of merging a `false` over it.

  The other direction is the same guarantee read backwards: an operator who
  turned the surface off wrote `enabled = false`, and that still wins.

  The precondition is read from `config/config.exs` with `Config.Reader` — the
  same API the release config-provider chain uses — rather than restated as a
  literal here. That keeps the test honest about which default it is asserting,
  and keeps a `:fermix_channels` app env leaked by another module from deciding
  the outcome.
  """

  use ExUnit.Case, async: false

  alias FermixChannels.Channels.Acp
  alias FermixChannels.Gateway.ChannelRegistry
  alias FermixCore.Setup.ConfigStore
  alias FermixTestSupport.SafeRm

  @ready %{status: :ready}
  @not_ready %{status: :setup_required, failures: []}
  @config_exs Path.expand("../../../../../../config/config.exs", __DIR__)

  # A pre-M29 install: a real channel section, no acp section anywhere.
  @pre_m29_toml """
  [fermix_core.agent]
  name = "fermix"

  [fermix_channels.telegram]
  enabled = true
  owner_user_id = "12345"
  """

  setup do
    previous_home = System.get_env("FERMIX_HOME")
    previous_channels = Application.get_all_env(:fermix_channels)
    previous_core = Application.get_all_env(:fermix_core)

    home = SafeRm.make_tmp_dir!("acp-upgrade-default")
    System.put_env("FERMIX_HOME", home)
    Application.put_env(:fermix_channels, :acp, shipped_acp_default())

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

  test "an upgraded install with no acp section boots with the surface enabled", %{home: home} do
    write_config!(home, @pre_m29_toml)

    assert :ok = ConfigStore.bootstrap_runtime_config(supervised: false)

    assert acp_enabled?()
    assert {Acp.Supervisor, []} in ChannelRegistry.transport_children(@ready)
  end

  test "the transport still waits for readiness on that upgraded install", %{home: home} do
    write_config!(home, @pre_m29_toml)

    assert :ok = ConfigStore.bootstrap_runtime_config(supervised: false)

    refute Enum.any?(ChannelRegistry.transport_children(@not_ready), &acp_child?/1)
  end

  test "an explicit enabled = false survives the upgrade and keeps the surface off", %{home: home} do
    write_config!(home, @pre_m29_toml <> "\n[fermix_channels.acp]\nenabled = false\n")

    assert :ok = ConfigStore.bootstrap_runtime_config(supervised: false)

    refute acp_enabled?()
    refute Enum.any?(ChannelRegistry.transport_children(@ready), &acp_child?/1)
  end

  test "an explicit enabled = true keeps the surface on", %{home: home} do
    write_config!(home, @pre_m29_toml <> "\n[fermix_channels.acp]\nenabled = true\n")

    assert :ok = ConfigStore.bootstrap_runtime_config(supervised: false)

    assert acp_enabled?()
    assert {Acp.Supervisor, []} in ChannelRegistry.transport_children(@ready)
  end

  defp write_config!(home, contents), do: File.write!(Path.join(home, "config.toml"), contents)

  defp acp_enabled? do
    :fermix_channels
    |> Application.get_env(:acp, [])
    |> Keyword.get(:enabled) == true
  end

  defp acp_child?({child, _opts}), do: child == Acp.Supervisor

  # The default a fresh BEAM boots with, straight from the shipped config.
  defp shipped_acp_default do
    assert File.regular?(@config_exs), "config/config.exs not found at #{@config_exs}"

    @config_exs
    |> Config.Reader.read!(env: :prod, target: :host)
    |> Keyword.fetch!(:fermix_channels)
    |> Keyword.fetch!(:acp)
  end

  defp restore_env(app, captured) do
    Enum.each(captured, fn {key, value} -> Application.put_env(app, key, value) end)

    app
    |> Application.get_all_env()
    |> Enum.reject(fn {key, _value} -> Keyword.has_key?(captured, key) end)
    |> Enum.each(fn {key, _value} -> Application.delete_env(app, key) end)
  end
end
