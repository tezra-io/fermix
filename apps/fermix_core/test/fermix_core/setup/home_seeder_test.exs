defmodule FermixCore.Setup.HomeSeederTest do
  @moduledoc """
  The first boot seeds a home that has no config (owner rule of 2026-09-27):
  the config file from the machine's facts, the prompt files from those, and
  nothing on a home that already has a config. Hermetic: its own home, its own
  memory repo, the suite's stubbed machine facts, every app key restored.
  """
  use ExUnit.Case, async: false

  alias FermixCore.Management.Settings.Assistant
  alias FermixCore.Memory.Repo, as: MemoryRepo
  alias FermixCore.Prompt.BootstrapPaths
  alias FermixCore.Prompt.SetupSeeder
  alias FermixCore.Readiness
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.HomeSeeder
  alias FermixCore.Setup.RestartState
  alias FermixCore.Setup.Wizard
  alias FermixTestSupport.SafeRm

  setup do
    home = System.get_env("FERMIX_HOME")
    # A save applies every section to app env (channels, sandbox, tools,
    # profile and the rest), so both apps' environments go back whole.
    core = Application.get_all_env(:fermix_core)
    channels = Application.get_all_env(:fermix_channels)
    web = Application.get_all_env(:fermix_web)
    FermixTestSupport.SecretWriterStub.reset()

    tmp = SafeRm.make_tmp_dir!("home_seeder")
    System.put_env("FERMIX_HOME", tmp)
    bootstrap_dir = Path.join(tmp, "bootstrap")
    memory_dir = Path.join(tmp, "memory")

    Application.put_env(:fermix_core, :providers, [])
    Application.put_env(:fermix_core, :agent, name: "fermix")
    Application.put_env(:fermix_core, :personalization, [])
    Application.put_env(:fermix_core, :prompt_bootstrap, bootstrap_dir: bootstrap_dir)

    # The seed goes through the wizard's own path, which commits to the global
    # memory repo, so that repo is restarted on this test's own database.
    Application.put_env(
      :fermix_core,
      :memory,
      Keyword.merge(Keyword.get(core, :memory, []),
        prompt_base_dir: memory_dir,
        agent_id: "main",
        owner_id: "default",
        enabled: true,
        database_path: Path.join(tmp, "memory.db")
      )
    )

    Application.put_env(:fermix_core, :prompt_seeder, SetupSeeder)
    Application.delete_env(:fermix_core, :machine_facts_answers)
    restart_global_memory_repo!()

    # The daemon has read the (absent) file, which is what the write baseline means.
    :ok = RestartState.record_persisted_baseline()

    on_exit(fn ->
      restore_env(:fermix_core, core)
      restore_env(:fermix_channels, channels)
      restore_env(:fermix_web, web)
      restart_global_memory_repo!()
      restore_home(home)
      :ok = RestartState.record_persisted_baseline()
      SafeRm.rm_rf!(tmp)
    end)

    %{memory_dir: memory_dir}
  end

  test "a home with no config is seeded from the machine's facts", %{memory_dir: memory_dir} do
    refute File.exists?(ConfigStore.path())

    assert {:seeded, answers} = HomeSeeder.run()
    assert Keyword.keys(answers) == [:user_name, :timezone, :communication_style]

    personalization = persisted_personalization()
    assert Keyword.get(personalization, :user_name) == "Test Operator"
    assert Keyword.get(personalization, :timezone) == "America/New_York"
    assert Keyword.get(personalization, :communication_style) == Assistant.default_style()

    assert File.exists?(BootstrapPaths.identity_path("main", []))
    assert File.read!(user_document(memory_dir)) =~ "Test Operator"
    refute Enum.any?(Readiness.report().failures, &(&1.component == "personalization"))
  end

  test "a home that already has a config is left alone" do
    {:ok, _report} = Wizard.save_answers(Wizard.report().wizard, user_name: "Ada Lovelace")
    before = File.read!(ConfigStore.path())

    assert HomeSeeder.run() == :existing
    assert File.read!(ConfigStore.path()) == before
  end

  test "a fact the machine cannot provide is left unset, and readiness only advises" do
    Application.put_env(:fermix_core, :machine_facts_answers, full_name: :error)

    assert {:seeded, answers} = HomeSeeder.run()
    refute Keyword.has_key?(answers, :user_name)

    personalization = persisted_personalization()
    refute Keyword.has_key?(personalization, :user_name)
    assert Keyword.get(personalization, :timezone) == "America/New_York"

    failure = Enum.find(Readiness.report().failures, &(&1.component == "personalization"))
    assert failure.gating == false
  end

  test "a later personalization save reaches USER.md", %{memory_dir: memory_dir} do
    assert {:seeded, _answers} = HomeSeeder.run()
    assert File.read!(user_document(memory_dir)) =~ "Test Operator"

    {:ok, _report} = Wizard.save_answers(Wizard.report().wizard, user_name: "Ada Lovelace")

    assert File.read!(user_document(memory_dir)) =~ "Ada Lovelace"
    refute File.read!(user_document(memory_dir)) =~ "Test Operator"
  end

  # Memory switched off holds no rows: the seed still writes the files, and a
  # later personalization save must not rebuild them into empty ones.
  test "a home with memory switched off keeps its seeded USER.md across a save", %{
    memory_dir: memory_dir
  } do
    Application.put_env(
      :fermix_core,
      :memory,
      Keyword.put(Application.get_env(:fermix_core, :memory, []), :enabled, false)
    )

    restart_global_memory_repo!()

    assert {:seeded, _answers} = HomeSeeder.run()
    seeded = File.read!(user_document(memory_dir))
    assert seeded =~ "Test Operator"

    {:ok, _report} = Wizard.save_answers(Wizard.report().wizard, user_name: "Ada Lovelace")

    assert File.read!(user_document(memory_dir)) == seeded
  end

  defp persisted_personalization do
    {:ok, snapshot} = ConfigStore.load_runtime_config(resolve_secrets: false)
    Keyword.fetch!(snapshot.fermix_core, :personalization)
  end

  defp user_document(memory_dir), do: Path.join([memory_dir, "main", "USER.md"])

  defp restore_env(app, saved) do
    Enum.each(Application.get_all_env(app), fn {key, _value} ->
      if not Keyword.has_key?(saved, key), do: Application.delete_env(app, key)
    end)

    Enum.each(saved, fn {key, value} -> Application.put_env(app, key, value) end)
  end

  defp restore_home(nil), do: System.delete_env("FERMIX_HOME")
  defp restore_home(home), do: System.put_env("FERMIX_HOME", home)

  defp restart_global_memory_repo! do
    case Process.whereis(MemoryRepo) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        :ok = Supervisor.terminate_child(FermixCore.Supervisor, MemoryRepo)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          1_000 -> Process.demonitor(ref, [:flush])
        end
    end

    {:ok, _pid} = Supervisor.restart_child(FermixCore.Supervisor, MemoryRepo)
    :ok
  end
end
