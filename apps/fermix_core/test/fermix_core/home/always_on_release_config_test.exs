defmodule FermixCore.Home.AlwaysOnReleaseConfigTest do
  @moduledoc """
  Where the Always On switch lives: `[fermix_core.always_on] enabled` in the
  home's settings file. The engine's boot reads it into application
  environment, every settings write carries it through, and no build's
  compile-time configuration pins it, so in a `:prod` build only the file
  turns Always On on.

  async: false: every case runs in its own `FERMIX_HOME` and writes
  application environment through the settings loader, both global to the
  VM; the whole environment of the three apps a load writes is restored on
  exit.
  """

  use ExUnit.Case, async: false

  alias FermixCore.Home.AlwaysOnRelease
  alias FermixCore.Management.Settings
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.RestartState
  alias FermixCore.Setup.Wizard
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.SecretWriterStub

  # Stands in for `McpSupervisor`: an MCP write reloads nothing here.
  defmodule ReloadNothing do
    @moduledoc false
    def reload, do: {:ok, %{started: [], stopped: [], unchanged: [], failed: []}}
  end

  @apps [:fermix_core, :fermix_channels, :fermix_web]
  @config_exs Path.expand("../../../../../config/config.exs", __DIR__)
  @section "[fermix_core.always_on]\nenabled = true"

  setup do
    home = System.get_env("FERMIX_HOME")
    envs = Map.new(@apps, &{&1, Application.get_all_env(&1)})
    Application.put_env(:fermix_core, :secret_writer, SecretWriterStub)
    tmp = SafeRm.make_tmp_dir!("always_on_release_config")
    System.put_env("FERMIX_HOME", tmp)
    :ok = RestartState.record_persisted_baseline()

    on_exit(fn ->
      Enum.each(envs, fn {app, env} -> restore_env(app, env) end)
      if home, do: System.put_env("FERMIX_HOME", home), else: System.delete_env("FERMIX_HOME")
      SafeRm.rm_rf!(tmp)
      :ok = RestartState.record_persisted_baseline()
    end)

    %{home: tmp, config: Path.join(tmp, "config.toml")}
  end

  test "a fresh home has no switch, so a prod build offers no Always On", ctx do
    refute File.exists?(ctx.config)

    assert {:ok, loaded} = ConfigStore.load_runtime_config()
    assert Keyword.fetch!(loaded.fermix_core, :always_on) == []
    assert :ok = ConfigStore.apply_snapshot(loaded, supervised: false)

    assert Application.get_env(:fermix_core, :always_on) == []
    refute AlwaysOnRelease.available?(:prod, Application.get_env(:fermix_core, :always_on))
    assert AlwaysOnRelease.available_in(ctx.home, :prod) == {:ok, false}
  end

  test "the boot accepts the section and puts the switch where the engine reads it", ctx do
    File.write!(ctx.config, ~s([fermix_core.engine]\nrole = "primary"\n\n#{@section}\n))

    assert {:ok, loaded} = ConfigStore.load_runtime_config()
    assert Keyword.fetch!(loaded.fermix_core, :always_on) == [enabled: true]
    assert :ok = ConfigStore.apply_snapshot(loaded, supervised: false)

    assert Application.get_env(:fermix_core, :always_on) == [enabled: true]
    assert AlwaysOnRelease.available?(:prod, Application.get_env(:fermix_core, :always_on))
    # A release boot restates it, so sys.config cannot undo it.
    assert Keyword.fetch!(ConfigStore.hydrated_environment(), :always_on) == [enabled: true]
    # The engine and a process with no engine read the one file.
    assert AlwaysOnRelease.available_in(ctx.home, :prod) == {:ok, true}
  end

  test "a bad switch stops the load by name, as every section does", ctx do
    File.write!(ctx.config, "[fermix_core.always_on]\nenabled = 1\n")

    assert_raise ArgumentError, ~r/\[fermix_core.always_on\] enabled takes true or false/, fn ->
      ConfigStore.load_runtime_config()
    end
  end

  # The Config round-trips rule: seeded with the shape application
  # environment holds, as every setup save starts from the live snapshot.
  test "a settings save keeps the switch: the app-env shape round-trips the file", ctx do
    Application.put_env(:fermix_core, :always_on, enabled: true)

    assert :ok = ConfigStore.save_snapshot(ConfigStore.current_snapshot())
    contents = File.read!(ctx.config)
    assert contents =~ @section <> "\n"

    assert {:ok, loaded} = ConfigStore.load_runtime_config()
    assert Keyword.fetch!(loaded.fermix_core, :always_on) == [enabled: true]
    assert :ok = ConfigStore.apply_snapshot(loaded, supervised: false)
    assert Application.get_env(:fermix_core, :always_on) == [enabled: true]

    # A second save from the live snapshot is a fixed point.
    assert :ok = ConfigStore.save_snapshot(ConfigStore.current_snapshot())
    assert File.read!(ctx.config) == contents
  end

  test "a save through the settings door, the setup page's and the apps', keeps the switch",
       ctx do
    File.write!(ctx.config, @section <> "\n")
    boot!()

    assert {:ok, _result} = Settings.apply("snapshots", %{"snapshots_interval_hours" => 12})

    contents = File.read!(ctx.config)
    assert contents =~ "interval_hours = 12"
    assert contents =~ @section <> "\n"
    assert AlwaysOnRelease.available_in(ctx.home, :prod) == {:ok, true}
  end

  # The setup page's first save is usually the model key: the wizard writes
  # the live snapshot back, so the switch the boot read must come back with
  # it, and the next boot must read it again. Its own profile keeps the
  # stub keychain's item apart from every other case's.
  test "the setup page's save of a model key keeps the switch, across a boot", ctx do
    profile = "aos-switch-#{System.unique_integer([:positive])}"
    on_exit(fn -> SecretWriterStub.delete(:openai_api_key, profile: profile) end)
    File.write!(ctx.config, ~s([fermix_core]\nprofile = "#{profile}"\n\n#{@section}\n))
    boot!()

    assert {:ok, _report} =
             Wizard.save_answers(Wizard.report().wizard, openai_api_key: "sk-invented-switch")

    contents = File.read!(ctx.config)
    assert contents =~ ~s(api_key = "@keyring")
    assert contents =~ @section <> "\n"

    Application.delete_env(:fermix_core, :always_on)
    boot!()
    assert Application.get_env(:fermix_core, :always_on) == [enabled: true]
  end

  test "an MCP server write re-renders the file and keeps the switch", ctx do
    File.write!(ctx.config, """
    #{@section}

    [mcp.servers.files]
    command = "npx"
    """)

    :ok = RestartState.record_persisted_baseline()

    assert :ok =
             ConfigStore.put_mcp_server("files", %{"enabled" => false},
               mcp_supervisor: ReloadNothing
             )

    contents = File.read!(ctx.config)
    assert contents =~ "[mcp.servers.files]"
    assert contents =~ @section <> "\n"
  end

  test "the listener port write re-renders the file and keeps the switch", ctx do
    File.write!(ctx.config, @section <> "\n")

    assert :ok = ConfigStore.put_web_port(ctx.home, 4_871)

    contents = File.read!(ctx.config)
    assert contents =~ "port = 4871"
    assert contents =~ @section <> "\n"
  end

  # The posture the suite runs in: a test build serves Always On whatever
  # the switch says, so no case here depends on it.
  test "this test build's engine offers Always On with the switch off or on" do
    for config <- [[], [enabled: false], [enabled: true]] do
      Application.put_env(:fermix_core, :always_on, config)
      assert AlwaysOnRelease.available?()
      assert AlwaysOnRelease.available?() == AlwaysOnRelease.available?(Mix.env(), config)
    end
  end

  # The feature-flag rule's second half: a pin in the compile-time chain
  # would turn Always On on (or off) for every home of that build.
  test "no build's compile-time configuration pins the switch" do
    for env <- [:dev, :test, :prod] do
      compiled = Config.Reader.read!(@config_exs, env: env, target: :host)

      refute compiled |> Keyword.get(:fermix_core, []) |> Keyword.has_key?(:always_on),
             inspect(env)
    end
  end

  # What an engine's boot does with the file: load it, apply it, and take it
  # as the baseline the next write compares against.
  defp boot! do
    assert {:ok, loaded} = ConfigStore.load_runtime_config()
    assert :ok = ConfigStore.apply_snapshot(loaded, supervised: false)
    :ok = RestartState.record_persisted_baseline()
  end

  defp restore_env(app, env) do
    for {key, _value} <- Application.get_all_env(app),
        not Keyword.has_key?(env, key),
        do: Application.delete_env(app, key)

    Enum.each(env, fn {key, value} -> Application.put_env(app, key, value) end)
  end
end
