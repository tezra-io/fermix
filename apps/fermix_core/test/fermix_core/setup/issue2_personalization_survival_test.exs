defmodule FermixCore.Setup.Issue2PersonalizationSurvivalTest do
  @moduledoc """
  Investigator C reproduction for "Save and restart resets the Personalization page".

  DECISIVE CLAIM under test: a realtime-key save (which carries NO personalization
  answer) does NOT drop previously-persisted personalization. If this suite passes,
  Issue 2 is NOT config data loss — the blank form after restart is unsaved typing
  the operator never committed, discarded by `System.stop/1` + remount-from-TOML.

  DO NOT EXECUTE against the host: this test mutates FERMIX_HOME (config.toml) and
  :fermix_core app env. It is hermetic only under a tmp FERMIX_HOME + SecretWriterStub.
  Written to disk to make the reasoning concrete; run it only in a sandboxed
  FERMIX_HOME with `mix test` from repo root.
  """
  use ExUnit.Case, async: false

  alias FermixCore.Setup.{ConfigStore, Wizard}

  setup do
    prev_home = System.get_env("FERMIX_HOME")
    prev_providers = Application.get_env(:fermix_core, :providers, [])
    prev_personalization = Application.get_env(:fermix_core, :personalization, [])
    prev_agent = Application.get_env(:fermix_core, :agent, [])
    prev_realtime = Application.get_env(:fermix_core, :realtime, [])
    prev_writer = Application.get_env(:fermix_core, :secret_writer)

    tmp = FermixTestSupport.SafeRm.make_tmp_dir!("issue2-personalization")
    System.put_env("FERMIX_HOME", tmp)
    Application.put_env(:fermix_core, :secret_writer, FermixTestSupport.SecretWriterStub)
    FermixTestSupport.SecretWriterStub.reset()

    on_exit(fn ->
      Application.put_env(:fermix_core, :providers, prev_providers)
      Application.put_env(:fermix_core, :personalization, prev_personalization)
      Application.put_env(:fermix_core, :agent, prev_agent)
      Application.put_env(:fermix_core, :realtime, prev_realtime)

      if prev_writer do
        Application.put_env(:fermix_core, :secret_writer, prev_writer)
      else
        Application.delete_env(:fermix_core, :secret_writer)
      end

      case prev_home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      FermixTestSupport.SafeRm.rm_rf!(tmp)
    end)

    :ok
  end

  defp seed_complete_config! do
    # openai_codex primary + full personalization, persisted to TOML AND app env,
    # exactly like a freshly-booted daemon that completed setup earlier.
    Application.put_env(:fermix_core, :providers,
      openai_codex: [primary: true, default_model: "gpt-5-codex", reasoning_effort: "medium"]
    )

    Application.put_env(:fermix_core, :personalization,
      user_name: "Sujeeth",
      timezone: "Asia/Singapore",
      communication_style: "concise and direct"
    )

    snapshot = ConfigStore.current_snapshot()
    :ok = ConfigStore.save_snapshot(snapshot)
    :ok = ConfigStore.apply_snapshot(snapshot)
  end

  defp simulate_reboot! do
    # Wipe app env the way a fresh BEAM would, then rehydrate from TOML the way
    # config/runtime.exs -> bootstrap_runtime_config does on daemon restart.
    Application.delete_env(:fermix_core, :personalization)
    Application.delete_env(:fermix_core, :realtime)
    :ok = ConfigStore.bootstrap_runtime_config()
  end

  test "realtime-key save preserves personalization in TOML, app env, and the rebuilt form" do
    seed_complete_config!()

    report0 = Wizard.report()

    # A Realtime-tab save: ONLY a realtime api key answer, no personalization answer.
    {:ok, _report1} =
      Wizard.save_answers(report0.wizard, realtime_api_key: "sk-realtime-xyz")

    # (a) committed TOML still carries personalization
    toml = File.read!(ConfigStore.path())
    assert toml =~ "Sujeeth"
    assert toml =~ "Asia/Singapore"
    assert toml =~ "concise and direct"

    # (b) app env still carries personalization (apply_personalization_config merge)
    p = Application.get_env(:fermix_core, :personalization, [])
    assert Keyword.get(p, :user_name) == "Sujeeth"
    assert Keyword.get(p, :timezone) == "Asia/Singapore"

    # Now the restart boundary: System.stop -> fresh boot -> bootstrap_runtime_config
    simulate_reboot!()

    # (c) the rebuilt report/snapshot that mount() -> build_personalization_form reads
    report2 = Wizard.report()
    snapshot2 = report2.wizard.config_snapshot

    personalization2 =
      snapshot2
      |> Map.get(:fermix_core, [])
      |> Keyword.get(:personalization, [])

    assert Keyword.get(personalization2, :user_name) == "Sujeeth"
    assert Keyword.get(personalization2, :timezone) == "Asia/Singapore"
    assert Keyword.get(personalization2, :communication_style) == "concise and direct"

    # And the personalization tab is NOT flagged partial -> mount would not land there.
    refute Enum.any?(report2.failures, &(&1.component == "personalization"))
  end

  test "control: if personalization was NEVER saved to TOML, restart shows it blank" do
    # The operator typed personalization into the form but never submitted
    # save_personalization. Only a realtime key reached the wizard. This is the
    # ACTUAL Issue-2 path: unsaved typing the global restart banner discards.
    Application.put_env(:fermix_core, :providers,
      openai_codex: [primary: true, default_model: "gpt-5-codex"]
    )

    Application.delete_env(:fermix_core, :personalization)

    {:ok, _report} =
      Wizard.report().wizard
      |> Wizard.save_answers(realtime_api_key: "sk-realtime-xyz")

    toml = File.read!(ConfigStore.path())
    refute toml =~ "Sujeeth"

    simulate_reboot!()

    report = Wizard.report()

    personalization =
      report.wizard.config_snapshot
      |> Map.get(:fermix_core, [])
      |> Keyword.get(:personalization, [])

    assert Keyword.get(personalization, :user_name) in [nil, ""]
    # personalization is flagged partial -> next_action_tab lands the operator on it, blank.
    assert Enum.any?(report.failures, &(&1.component == "personalization"))
  end
end
