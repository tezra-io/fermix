defmodule FermixCore.PhoneCalls.ConfigStoreTest do
  # `[fermix_core.phone_calls]` through the settings file's loader and persist
  # path. Each test runs in its own temporary FERMIX_HOME against the stub
  # keychain. `apply_snapshot/1` rewrites every section of application
  # environment, so the whole environment of the three applications is put
  # back afterwards, not only this section.
  use ExUnit.Case, async: false

  alias FermixCore.PhoneCalls.Config
  alias FermixCore.Setup.ConfigStore
  alias FermixTestSupport.SecretWriterStub

  # Invented values, in the 555-01XX range NANPA reserves for fiction.
  @caller "+14155550142"
  @apps [:fermix_core, :fermix_channels, :fermix_web]

  setup do
    fermix_home = System.get_env("FERMIX_HOME")
    envs = for app <- @apps, do: {app, Application.get_all_env(app)}

    home =
      Path.join(System.tmp_dir!(), "fermix-phone-calls-#{System.unique_integer([:positive])}")

    SecretWriterStub.reset()
    Application.put_env(:fermix_core, :secret_writer, SecretWriterStub)
    System.put_env("FERMIX_HOME", home)

    on_exit(fn ->
      FermixTestSupport.SafeRm.rm_rf!(home)
      Enum.each(envs, fn {app, env} -> restore_all(app, env) end)
      SecretWriterStub.reset()

      case fermix_home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end
    end)

    %{home: home}
  end

  test "a fresh home loads an empty section, which reads as disabled" do
    assert {:ok, loaded} = ConfigStore.load_runtime_config()
    assert Keyword.fetch!(loaded.fermix_core, :phone_calls) == []
    refute Config.normalize([]).enabled
  end

  # The "Config round-trips" rule: seeded with the shape application
  # environment holds after a boot (the password resolved out of the keychain),
  # saved the way setup saves it, loaded back to the same shape.
  test "save then load round-trips the normalized app-env shape", %{home: home} do
    live =
      Config.to_keyword(%Config{
        enabled: true,
        voice: "cedar",
        caller_number: @caller,
        sip_username: "fermixtrunk01",
        sip_password: "invented-trunk-password"
      })

    Application.put_env(:fermix_core, :phone_calls, live)

    assert ConfigStore.current_snapshot().fermix_core |> Keyword.fetch!(:phone_calls) == live
    assert :ok = ConfigStore.save_snapshot(snapshot(live))

    contents = File.read!(Path.join(home, "config.toml"))
    assert contents =~ "[fermix_core.phone_calls]"
    assert contents =~ "enabled = true"
    assert contents =~ ~s(caller_number = "#{@caller}")
    assert contents =~ ~s(sip_username = "fermixtrunk01")
    assert contents =~ ~s(sip_password = "@keyring")
    refute contents =~ "invented-trunk-password"
    assert SecretWriterStub.get(:phone_calls_sip_password) == {:ok, "invented-trunk-password"}

    # Resolving a secret puts it back at the front of its keyword
    # (`SecretStore`), so the shape is compared as a set and as the section.
    assert {:ok, loaded} = ConfigStore.load_runtime_config()
    section = Keyword.fetch!(loaded.fermix_core, :phone_calls)
    assert Enum.sort(section) == Enum.sort(live)
    assert Config.normalize(section) == Config.normalize(live)

    ConfigStore.apply_snapshot(loaded)
    assert Config.get() == Config.normalize(live)
  end

  test "the default section writes nothing to the file", %{home: home} do
    assert :ok = ConfigStore.save_snapshot(snapshot([]))
    refute File.read!(Path.join(home, "config.toml")) =~ "[fermix_core.phone_calls]"
  end

  test "apply_snapshot replaces the section, so turning it off takes effect" do
    Application.put_env(:fermix_core, :phone_calls, enabled: true, caller_number: @caller)

    ConfigStore.apply_snapshot(snapshot([]))

    assert Application.get_env(:fermix_core, :phone_calls) == []
    refute Config.enabled?()
  end

  test "load refuses an unknown key, naming it", %{home: home} do
    write_config(home, """
    [fermix_core.phone_calls]
    enabled = true
    provider_url = "sips:sip.example.com:5061"
    """)

    assert_raise ArgumentError, ~r/\[fermix_core\.phone_calls\].*provider_url/s, fn ->
      ConfigStore.load_runtime_config()
    end
  end

  test "load refuses an invalid value, naming the key", %{home: home} do
    write_config(home, """
    [fermix_core.phone_calls]
    caller_number = "+14165550142"
    """)

    assert_raise ArgumentError, ~r/\[fermix_core\.phone_calls\].*caller_number/s, fn ->
      ConfigStore.load_runtime_config()
    end
  end

  test "load never copies the local voice section into phone calls", %{home: home} do
    write_config(home, """
    [fermix_core.realtime]
    enabled = true
    engine = "xai_realtime"
    model = "grok-voice-3.0"
    voice = "eve"
    """)

    assert {:ok, loaded} = ConfigStore.load_runtime_config()
    assert Keyword.fetch!(loaded.fermix_core, :phone_calls) == []
  end

  defp snapshot(phone_calls),
    do: %{fermix_core: [phone_calls: phone_calls], fermix_channels: [], fermix_web: []}

  defp write_config(home, contents) do
    File.mkdir_p!(home)
    File.write!(Path.join(home, "config.toml"), contents)
  end

  defp restore_all(app, env) do
    for {key, _value} <- Application.get_all_env(app),
        not Keyword.has_key?(env, key),
        do: Application.delete_env(app, key)

    for {key, value} <- env, do: Application.put_env(app, key, value)
  end
end
