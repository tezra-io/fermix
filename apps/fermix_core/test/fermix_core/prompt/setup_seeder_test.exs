defmodule FermixCore.Prompt.SetupSeederTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixCore.Memory.PromptFiles
  alias FermixCore.Memory.Repo, as: MemoryRepo
  alias FermixCore.Prompt.BootstrapPaths
  alias FermixCore.Prompt.Defaults
  alias FermixCore.Prompt.SetupSeeder
  alias FermixCore.Resource.Registry

  setup do
    unique = System.unique_integer([:positive, :monotonic])
    repo_name = :"setup_seeder_repo_#{unique}"
    db_path = Path.join(System.tmp_dir!(), "fermix-setup-seeder-#{unique}.db")
    bootstrap_dir = Path.join(System.tmp_dir!(), "fermix-setup-seeder-bootstrap-#{unique}")
    memory_dir = Path.join(System.tmp_dir!(), "fermix-setup-seeder-memory-#{unique}")

    previous_bootstrap = Application.get_env(:fermix_core, :prompt_bootstrap, [])
    previous_memory = Application.get_env(:fermix_core, :memory, [])
    previous_agent = Application.get_env(:fermix_core, :agent, [])

    Application.put_env(:fermix_core, :prompt_bootstrap, bootstrap_dir: bootstrap_dir)

    Application.put_env(
      :fermix_core,
      :memory,
      Keyword.merge(previous_memory,
        prompt_base_dir: memory_dir,
        agent_id: "main",
        owner_id: "default"
      )
    )

    Application.put_env(:fermix_core, :agent, name: "fermix")

    start_supervised!({MemoryRepo, name: repo_name, enabled: true, database_path: db_path})

    on_exit(fn ->
      Application.put_env(:fermix_core, :prompt_bootstrap, previous_bootstrap)
      Application.put_env(:fermix_core, :memory, previous_memory)
      Application.put_env(:fermix_core, :agent, previous_agent)
      File.rm_rf!(bootstrap_dir)
      File.rm_rf!(memory_dir)

      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], fn path -> File.rm(path) end)
    end)

    %{
      agent_id: "main",
      owner_id: "default",
      bootstrap_dir: bootstrap_dir,
      memory_dir: memory_dir,
      repo: repo_name
    }
  end

  describe "seed/2 fresh install" do
    test "writes all five files, commits seed revisions, and upserts user memories", %{
      agent_id: agent_id,
      owner_id: owner_id,
      repo: repo
    } do
      personalization = %{
        user_name: "Sujeeth",
        timezone: "Asia/Singapore",
        communication_style: "blunt"
      }

      handler_id = "setup-seeder-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler_id,
        [
          [:fermix, :prompt, :seed],
          [:fermix, :prompt, :seed_user_memories]
        ],
        fn event, measurements, metadata, test_pid ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        self()
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, results} = SetupSeeder.seed(personalization, repo: repo)

      assert Enum.map(results, & &1.name) == [:identity, :agents, :soul, :user, :memory]
      assert Enum.all?(results, &(&1.outcome == :seeded))
      assert Enum.all?(results, &is_integer(&1.revision_id))

      identity_path = BootstrapPaths.identity_path(agent_id)
      agents_path = BootstrapPaths.agents_path(agent_id)
      soul_path = BootstrapPaths.soul_path(agent_id)
      user_path = PromptFiles.user_path(agent_id)
      memory_path = PromptFiles.memory_path(agent_id)

      assert File.read!(identity_path) == Defaults.identity_md()
      assert File.read!(agents_path) == Defaults.agents_md()
      assert File.read!(soul_path) == Defaults.soul_md()

      user_content = File.read!(user_path)
      assert user_content =~ "name: Sujeeth"
      assert user_content =~ "timezone: Asia/Singapore"
      assert user_content =~ "communication style: blunt"

      memory_content = File.read!(memory_path)
      assert memory_content =~ "## Environment"
      assert memory_content =~ "## Project Context"
      assert memory_content =~ "## Working Rules"

      for {resource_type, expected_content} <- [
            {:identity_md, Defaults.identity_md()},
            {:agents_md, Defaults.agents_md()},
            {:soul_md, Defaults.soul_md()}
          ] do
        assert {:ok, [revision]} =
                 Registry.list_revisions(agent_id, resource_type, "global", repo: repo)

        assert revision.mutation_source == "seed"
        assert revision.content == expected_content
        assert revision.provenance["trigger"] == "setup_seed"
      end

      assert {:ok, [user_revision]} =
               Registry.list_revisions(agent_id, :user_md, "global", repo: repo)

      assert user_revision.provenance["wizard_inputs"] == [
               "user_name",
               "timezone",
               "communication_style"
             ]

      assert {:ok, memories} =
               MemoryRepo.get_memories(%{agent_id: agent_id, owner_id: owner_id}, server: repo)

      keys = Enum.map(memories, &{&1.scope_type, &1.category, &1.key, &1.value})

      assert {"owner", "identity", "name", "Sujeeth"} in keys
      assert {"owner", "identity", "timezone", "Asia/Singapore"} in keys
      assert {"owner", "preference", "communication style", "blunt"} in keys
      assert {"agent", "identity", "agent name", "fermix"} in keys

      promote_targets =
        memories
        |> Enum.map(&{&1.key, &1.promote_target})
        |> Enum.into(%{})

      assert promote_targets["name"] == "user_md"
      assert promote_targets["timezone"] == "user_md"
      assert promote_targets["communication style"] == "user_md"
      assert promote_targets["agent name"] == "memory_md"

      assert_received {:telemetry, [:fermix, :prompt, :seed], %{bytes: identity_bytes},
                       %{name: :identity, outcome: :seeded}}

      assert identity_bytes > 0

      assert_received {:telemetry, [:fermix, :prompt, :seed_user_memories], %{count: 4},
                       %{agent_id: ^agent_id, owner_id: ^owner_id}}
    end
  end

  describe "seed/2 idempotency" do
    test "skips files that already exist and emits skipped_exists telemetry", %{
      agent_id: agent_id,
      repo: repo
    } do
      personalization = %{user_name: "Aira"}

      assert {:ok, _first} = SetupSeeder.seed(personalization, repo: repo)

      File.write!(BootstrapPaths.identity_path(agent_id), "operator-edited identity")

      handler_id = "setup-seeder-skip-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:fermix, :prompt, :seed],
        fn _event, _measurements, metadata, test_pid ->
          send(test_pid, {:seed, metadata})
        end,
        self()
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, results} = SetupSeeder.seed(personalization, repo: repo)
      assert Enum.all?(results, &(&1.outcome == :skipped_exists))
      assert File.read!(BootstrapPaths.identity_path(agent_id)) == "operator-edited identity"

      assert_received {:seed, %{name: :identity, outcome: :skipped_exists}}
      assert_received {:seed, %{name: :agents, outcome: :skipped_exists}}
      assert_received {:seed, %{name: :soul, outcome: :skipped_exists}}
      assert_received {:seed, %{name: :user, outcome: :skipped_exists}}
      assert_received {:seed, %{name: :memory, outcome: :skipped_exists}}
    end
  end

  describe "seed/2 failure semantics" do
    test "returns write_failed when target directory cannot be created", %{
      bootstrap_dir: bootstrap_dir,
      repo: repo
    } do
      File.mkdir_p!(Path.dirname(bootstrap_dir))
      File.write!(bootstrap_dir, "block mkdir_p")

      assert {:error, {:write_failed, path, :enotdir}} =
               SetupSeeder.seed(%{user_name: "Aira"}, repo: repo)

      assert path =~ "IDENTITY.md"
    end

    test "logs commit failures, propagates user-memory upsert error, leaves files on disk", %{
      agent_id: agent_id
    } do
      disabled_repo = :"setup_seeder_disabled_#{System.unique_integer([:positive])}"

      start_supervised!(
        Supervisor.child_spec(
          {MemoryRepo, name: disabled_repo, enabled: false},
          id: disabled_repo
        )
      )

      log =
        capture_log(fn ->
          assert {:error, :disabled} =
                   SetupSeeder.seed(%{user_name: "Aira"}, repo: disabled_repo)

          for path <- [
                BootstrapPaths.identity_path(agent_id),
                BootstrapPaths.agents_path(agent_id),
                BootstrapPaths.soul_path(agent_id),
                PromptFiles.user_path(agent_id),
                PromptFiles.memory_path(agent_id)
              ] do
            assert File.exists?(path)
          end
        end)

      assert log =~ "commit failed"
      assert log =~ "user-memory upsert failed"
    end
  end
end
