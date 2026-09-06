defmodule FermixCore.Setup.ExternalChangeRefusalTest do
  @moduledoc """
  The refusal from M34 native setup §7.6: every management write that persists
  `config.toml` consults the config state first.

  It lives in the two shared write tails, not in the management layer, because
  four public wizard entries plus every plugin writer reach the same file. A
  gate in one of them would let the others revert an outside edit silently,
  which is the exact defect it exists for.
  """

  use ExUnit.Case, async: false

  alias FermixCore.Plugins.Config, as: PluginConfig
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.RestartState
  alias FermixCore.Setup.Wizard
  alias FermixTestSupport.SafeRm

  @seed """
  [fermix_core.providers.openai]
  api_key = "sk-seeded"
  primary = true
  """

  setup do
    home = System.get_env("FERMIX_HOME")
    providers = Application.get_env(:fermix_core, :providers)
    personalization = Application.get_env(:fermix_core, :personalization)
    plugins = Application.get_env(:fermix_core, :plugins)
    secret_writer = Application.get_env(:fermix_core, :secret_writer)

    Application.put_env(:fermix_core, :secret_writer, FermixTestSupport.SecretWriterStub)
    FermixTestSupport.SecretWriterStub.reset()

    tmp = SafeRm.make_tmp_dir!("external_change_home")
    System.put_env("FERMIX_HOME", tmp)
    File.write!(Path.join(tmp, "config.toml"), @seed)

    # A gating readiness failure so the write tail skips prompt-file seeding:
    # these cases exercise the refusal, not the memory repo.
    Application.put_env(:fermix_core, :providers, openai: [api_key: "sk-seeded", primary: true])
    Application.put_env(:fermix_core, :personalization, [])

    # The daemon has now read this file, which is what the baseline means. It
    # also clears the cached answer, so the next read is computed fresh.
    :ok = RestartState.record_persisted_baseline()

    on_exit(fn ->
      restore(:fermix_core, :providers, providers)
      restore(:fermix_core, :personalization, personalization)
      restore(:fermix_core, :plugins, plugins)
      restore(:fermix_core, :secret_writer, secret_writer)
      FermixTestSupport.SecretWriterStub.reset()

      case home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      SafeRm.rm_rf!(tmp)
    end)

    %{home: tmp}
  end

  test "with no outside change every write proceeds", %{home: home} do
    assert {:ok, _report} = Wizard.set_sandbox_overrides(:strict, nil, nil)
    assert File.read!(Path.join(home, "config.toml")) =~ ~s(mode = "strict")
  end

  test "an outside write refuses the wizard tail and names the sections", %{home: home} do
    write_outside(home)

    assert {:error, {:external_change, sections}} = Wizard.set_sandbox_overrides(:open, nil, nil)
    assert "providers" in sections
  end

  # `mark_primary/1` and `set_provider_auth_mode/2` never pass through
  # `save_answers/2`, so a gate placed there would leave both able to revert an
  # outside edit. They inherit the refusal from the shared tail instead.
  test "every public wizard entry inherits the refusal", %{home: home} do
    write_outside(home)

    assert {:error, {:external_change, _sections}} = Wizard.mark_primary(:openai)
    assert {:error, {:external_change, _sections}} = Wizard.set_provider_auth_mode(:xai, :oauth)
    assert {:error, {:external_change, _sections}} = Wizard.set_sandbox_overrides(:open, nil, nil)
  end

  # The plugin family persists through its own tail and never through the
  # wizard, so the same predicate has to run in both. Two tails, one predicate.
  test "the plugin write tail refuses the same way", %{home: home} do
    write_outside(home)

    assert {:error, {:external_change, _sections}} = PluginConfig.enable("google_calendar")
  end

  test "the write after a reload succeeds", %{home: home} do
    write_outside(home)
    assert {:error, {:external_change, _sections}} = Wizard.set_sandbox_overrides(:open, nil, nil)

    # What `settings.reload` does: re-read, re-apply, re-record.
    :ok = RestartState.record_persisted_baseline()

    assert {:ok, _report} = Wizard.set_sandbox_overrides(:open, nil, nil)
  end

  # An unreadable file is never answered with a reload: the reload runs the same
  # parse that just failed, so it is a loop neither front-end can leave.
  test "an unreadable file refuses with the parser's own sentence", %{home: home} do
    File.write!(Path.join(home, "config.toml"), "[fermix_core.providers]\nopenai = 5\n")

    assert {:error, {:config_unreadable, sentence}} =
             Wizard.set_sandbox_overrides(:open, nil, nil)

    assert is_binary(sentence) and sentence != ""
  end

  # The regression this whole family turns on: a write BY THIS VM that does not
  # go through a setup tail. `Tools.ModelRoutingConfig` (a model-callable tool)
  # and the `/history` channel command both run load / put / save / apply
  # directly, and with the baseline recorded only in the tails each of them made
  # the daemon report an outside edit against a file it had just written itself
  # — after which every settings, secret, primary and plugin write refused.
  test "an in-VM save through ConfigStore alone leaves the state clear", %{home: home} do
    {:ok, snapshot} = ConfigStore.load_runtime_config()
    next = put_in(snapshot.fermix_core[:routing], subagent_model: "gpt-5.6-mini")

    :ok = ConfigStore.save_snapshot(next)
    :ok = ConfigStore.apply_snapshot(next)

    assert File.read!(Path.join(home, "config.toml")) =~ "subagent_model"
    assert RestartState.config_state() == :clear
    assert {:ok, _report} = Wizard.set_sandbox_overrides(:strict, nil, nil)
  end

  defp write_outside(home) do
    File.write!(Path.join(home, "config.toml"), """
    [fermix_core.providers.openai]
    api_key = "sk-written-outside"
    primary = true
    """)
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
