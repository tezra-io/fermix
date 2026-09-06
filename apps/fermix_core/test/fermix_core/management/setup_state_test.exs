defmodule FermixCore.Management.SetupStateTest do
  @moduledoc """
  The `setup.state.get` projection (M34 native setup §7.3).

  Sources are injected, never rendered results, so the projection under test is
  the daemon's own. Application environment is established in `setup` and
  restored in `on_exit`: every field here is derived from global state.
  """

  use ExUnit.Case, async: false

  alias FermixCore.Management.SetupState
  alias FermixCore.Providers.Descriptor
  alias FermixCore.Readiness
  alias FermixCore.Setup.SecretWriter
  alias FermixTestSupport.CountingSecretWriter
  alias FermixTestSupport.SafeRm

  @core_keys [:providers, :personalization, :profile, :realtime, :computer_use, :computer_history]

  setup do
    core = Map.new(@core_keys, fn key -> {key, Application.get_env(:fermix_core, key)} end)
    telegram = Application.get_env(:fermix_channels, :telegram)

    on_exit(fn ->
      Enum.each(core, fn {key, value} -> restore(:fermix_core, key, value) end)
      restore(:fermix_channels, :telegram, telegram)
    end)

    :ok
  end

  test "answers every field the contract requires, and nothing more" do
    report = SetupState.report(sources())

    assert Enum.sort(Map.keys(report)) == [
             "channels",
             "coexistence",
             "features",
             "personalization",
             "profile",
             "providers",
             "readiness",
             "restart"
           ]
  end

  test "a readiness failure carries the fields a surface routes on" do
    report = SetupState.report(sources())

    assert [failure] = report["readiness"]["failures"]
    assert failure["component"] == "provider:anthropic"
    assert failure["gating"] == true
    assert failure["pane"] == "providers"
    assert failure["detail_key"] == "provider:missing_credentials:anthropic"
  end

  # The app never composes a restart sentence; it renders the daemon's.
  test "a restart reason carries the daemon's own sentence" do
    report = SetupState.report(sources())

    assert report["restart"]["required"] == true
    assert [%{"section" => "providers", "sentence" => sentence}] = report["restart"]["reasons"]
    assert sentence == "Provider settings changed."
  end

  test "one provider row per descriptor, in descriptor order" do
    report = SetupState.report(sources())

    ids = Enum.map(report["providers"], & &1["id"])
    assert ids == Enum.map(Descriptor.ids(), &Atom.to_string/1)
  end

  test "a provider row publishes every field the contract requires" do
    report = SetupState.report(sources())
    [row | _rest] = report["providers"]

    assert Enum.sort(Map.keys(row)) == [
             "account_label",
             "auth_mode",
             "auth_modes",
             "configured",
             "default_model",
             "fast",
             "id",
             "label",
             "present_key",
             "primary",
             "reasoning_effort",
             "token_state"
           ]
  end

  test "a provider with no configured auth mode falls back to its descriptor default" do
    Application.put_env(:fermix_core, :providers, [])

    report = SetupState.report(sources())
    row = Enum.find(report["providers"], &(&1["id"] == "anthropic"))

    assert row["auth_modes"] == ["api_key", "oauth"]
    assert row["auth_mode"] == "api_key"
  end

  # Presence is "a sentinel or a plaintext value sits at the path", never "the
  # keychain holds an item": a key stored without its sentinel is never read
  # back, so calling it present would describe a credential nothing can use.
  test "present_key follows the sentinel at the provider's own path" do
    Application.put_env(:fermix_core, :providers, openai: [api_key: SecretWriter.sentinel()])

    report = SetupState.report(sources())
    openai = Enum.find(report["providers"], &(&1["id"] == "openai"))
    anthropic = Enum.find(report["providers"], &(&1["id"] == "anthropic"))

    assert openai["present_key"] == true
    assert anthropic["present_key"] == false
  end

  test "one channel row per readiness channel, and a disabled one has no status or mode" do
    Application.put_env(:fermix_channels, :telegram, enabled: false)

    report = SetupState.report(sources())

    assert Enum.map(report["channels"], & &1["name"]) ==
             Enum.map(Readiness.channels(), &Atom.to_string/1)

    telegram = Enum.find(report["channels"], &(&1["name"] == "telegram"))
    assert telegram["enabled"] == false
    assert telegram["status"] == nil
    assert telegram["mode"] == nil
  end

  test "an enabled channel with no credentials reports setup_required" do
    Application.put_env(:fermix_channels, :telegram, enabled: true, mode: :polling)

    report = SetupState.report(sources())
    telegram = Enum.find(report["channels"], &(&1["name"] == "telegram"))

    assert telegram["enabled"] == true
    assert telegram["configured"] == false
    assert telegram["status"] == "setup_required"
    assert telegram["mode"] == "polling"
  end

  test "personalization reports presence only, never a value" do
    Application.put_env(:fermix_core, :personalization, user_name: "Sam", timezone: "")

    report = SetupState.report(sources())

    assert report["personalization"] == %{
             "present" => %{
               "user_name" => true,
               "timezone" => false,
               "communication_style" => false
             }
           }
  end

  test "computer history reports enabled, installed and ready separately" do
    report = SetupState.report(sources())

    assert report["features"]["computer_history"] == %{
             "enabled" => false,
             "installed" => false,
             "ready" => false
           }
  end

  test "coexistence carries the unit scope and the config state word" do
    report = SetupState.report(sources())

    assert report["coexistence"]["legacy_service_unit"] == %{
             "present" => true,
             "scope" => "user",
             "path" => "/tmp/unit.plist"
           }

    assert report["coexistence"]["config_state"] == "clear"
    assert report["coexistence"]["secret_acl_restricted"] == %{"present" => false, "keys" => []}
  end

  test "an unreadable settings file is a state, not a crash" do
    report =
      SetupState.report(
        Keyword.put(sources(), :config_state, fn -> {:config_unreadable, "line 14"} end)
      )

    assert report["coexistence"]["config_state"] == "config_unreadable"
  end

  # The result crosses the socket and is logged and exported, so no credential
  # may appear anywhere in it, at any depth.
  test "no secret value appears anywhere in the result" do
    Application.put_env(:fermix_core, :providers, openai: [api_key: "sk-live-should-never-leak"])

    encoded = Jason.encode!(SetupState.report(sources()))

    refute encoded =~ "sk-live-should-never-leak"
  end

  # The polled read must take no keychain subprocess at all: on the exact
  # population `secret_acl_restricted` names, a read raises the macOS allow
  # dialog, so a probe on this path would prompt once per stored secret every
  # time a setup surface refreshed. No source is injected here — injecting one
  # is what hid this from the suite in the first place.
  describe "the polled read against the real sources" do
    setup do
      home = System.get_env("FERMIX_HOME")
      writer = Application.get_env(:fermix_core, :secret_writer)
      tmp = SafeRm.make_tmp_dir!("setup_state_no_shell_out")

      File.write!(Path.join(tmp, "config.toml"), """
      [fermix_core.providers.openai]
      api_key = "@keyring"

      [fermix_core.tools]
      tavily_api_key = "@keyring"

      [fermix_channels.telegram]
      bot_token = "@keyring"
      """)

      System.put_env("FERMIX_HOME", tmp)
      Application.put_env(:fermix_core, :secret_writer, CountingSecretWriter)
      CountingSecretWriter.watch()

      on_exit(fn ->
        CountingSecretWriter.unwatch()
        restore(:fermix_core, :secret_writer, writer)

        case home do
          nil -> System.delete_env("FERMIX_HOME")
          value -> System.put_env("FERMIX_HOME", value)
        end

        SafeRm.rm_rf!(tmp)
      end)

      :ok
    end

    test "reads no stored secret" do
      _report = SetupState.report()

      refute_received {:secret_writer_get, _key}
    end

    test "publishes the ACL measurement as not measured until Doctor has run" do
      report = SetupState.report()

      assert report["coexistence"]["secret_acl_restricted"] == %{"present" => nil, "keys" => []}
    end
  end

  defp sources do
    [
      readiness: fn ->
        %{
          status: :setup_required,
          failures: [
            %{
              component: "provider:anthropic",
              action: "Set ANTHROPIC_API_KEY.",
              gating: true,
              pane: "providers",
              detail_key: "provider:missing_credentials:anthropic"
            }
          ]
        }
      end,
      restart: fn ->
        %{
          required: true,
          reasons: [%{section: "providers", sentence: "Provider settings changed."}]
        }
      end,
      accounts: fn -> %{} end,
      sidecar_installed?: fn -> false end,
      legacy_service_unit: fn -> %{present: true, scope: :user, path: "/tmp/unit.plist"} end,
      secret_acl_restricted: fn -> %{present: false, keys: []} end,
      config_state: fn -> :clear end
    ]
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
