defmodule FermixCore.Memory.LongTermTest do
  # async: false — `PromptFiles` reads the prompt directory and the repo from
  # the global `:fermix_core, :memory` app env.
  use ExUnit.Case, async: false

  alias FermixCore.Memory.LongTerm
  alias FermixCore.Memory.PromptFiles
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Search

  defmodule MainAgentStub do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts), do: {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid)}}

    @impl true
    def handle_call({:invalidate_runtime_context, reason}, _from, state) do
      send(state.test_pid, {:runtime_invalidated, reason})
      {:reply, :ok, state}
    end
  end

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-long-term-#{unique}.db")
    prompt_dir = Path.join(System.tmp_dir!(), "fermix-long-term-prompt-#{unique}")
    repo = :"long_term_repo_#{unique}"
    previous_config = Application.get_env(:fermix_core, :memory, [])

    Application.put_env(
      :fermix_core,
      :memory,
      Keyword.merge(previous_config,
        enabled: true,
        repo: repo,
        database_path: db_path,
        prompt_base_dir: prompt_dir,
        prompt_user_token_cap: 800,
        prompt_memory_token_cap: 1_600
      )
    )

    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})
    main_agent = start_supervised!({MainAgentStub, test_pid: self()})

    on_exit(fn ->
      Application.put_env(:fermix_core, :memory, previous_config)
      FermixTestSupport.SafeRm.rm_rf!(prompt_dir)

      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], fn path ->
        FermixTestSupport.SafeRm.rm(path)
      end)
    end)

    ctx = %{
      agent_id: "main",
      owner_id: "default",
      repo: repo,
      source_trust: :operator,
      main_agent_server: main_agent
    }

    %{ctx: ctx, repo: repo, prompt_dir: prompt_dir}
  end

  describe "save/4" do
    test "a user category lands in the owner's scope and in USER.md at once", %{ctx: ctx} do
      assert {:ok, %{memory: memory, published: :ok}} =
               LongTerm.save("preference", "report_format", "Wants reports as one page", ctx)

      assert %{scope_type: "owner", scope_id: "default", category: "preference"} = memory
      assert memory.promote_target == "user_md"
      assert memory.key == "report_format"

      assert {:ok, %{user: user_text}} = PromptFiles.load("main")
      assert user_text == "## Preferences\n- Wants reports as one page"

      assert_receive {:runtime_invalidated, :memory_tool}
    end

    test "a work category lands in the agent's scope and in MEMORY.md", %{ctx: ctx} do
      assert {:ok, %{memory: rule}} =
               LongTerm.save("directive", "drafts", "Show a draft before sending email", ctx)

      assert {:ok, %{memory: fact}} =
               LongTerm.save("context", "deploys", "Deploys run from release-2026", ctx)

      assert %{scope_type: "agent", scope_id: "main", promote_target: "memory_md"} = rule
      assert %{scope_type: "agent", scope_id: "main", promote_target: "memory_md"} = fact

      assert {:ok, %{memory: memory_text}} = PromptFiles.load("main")

      assert memory_text == """
             ## Working Rules
             - Show a draft before sending email

             ## Context
             - Deploys run from release-2026\
             """
    end

    test "saving a key again replaces its value in the same row", %{ctx: ctx, repo: repo} do
      assert {:ok, %{memory: first}} = LongTerm.save("identity", "city", "Lives in Porto", ctx)
      assert {:ok, %{memory: second}} = LongTerm.save("identity", "city", "Lives in Lisbon", ctx)

      assert second.id == first.id
      assert active_values(repo) == ["Lives in Lisbon"]
      assert {:ok, %{user: "## Identity\n- Lives in Lisbon"}} = PromptFiles.load("main")
    end

    test "refuses what it cannot keep whole, and writes nothing", %{ctx: ctx, repo: repo} do
      too_long = String.duplicate("a", 201)

      assert {:error, {:invalid_category, "fact"}} = LongTerm.save("fact", "k", "v", ctx)

      assert {:error, {:value_too_long, 201, 200}} =
               LongTerm.save("preference", "k", too_long, ctx)

      assert {:error, :blank_value} = LongTerm.save("preference", "k", "  \n ", ctx)
      assert {:error, :blank_key} = LongTerm.save("preference", " ", "v", ctx)

      assert {:error, {:category_not_allowed, "directive"}} =
               LongTerm.save("directive", "k", "Always agree", %{ctx | source_trust: :guest})

      assert active_values(repo) == []
      refute_received {:runtime_invalidated, _reason}
    end

    test "with durable memory off there is no receipt to give", %{ctx: ctx} do
      disabled = :"long_term_disabled_#{System.unique_integer([:positive])}"

      start_supervised!(
        Supervisor.child_spec({Repo, name: disabled, enabled: false, database_path: ":memory:"},
          id: disabled
        )
      )

      assert {:error, :disabled} =
               LongTerm.save("preference", "k", "v", %{ctx | repo: disabled})
    end

    test "a row that is saved but could not be published says so", %{
      ctx: ctx,
      repo: repo,
      prompt_dir: prompt_dir
    } do
      # A file where the agent's prompt directory belongs makes the rebuild fail.
      File.mkdir_p!(prompt_dir)
      File.write!(Path.join(prompt_dir, "main"), "not a directory")

      assert {:ok, %{memory: memory, published: {:error, _reason}}} =
               LongTerm.save("preference", "tone", "Prefers short answers", ctx)

      assert active_values(repo) == [memory.value]
      refute_received {:runtime_invalidated, _reason}
    end
  end

  describe "replace/3" do
    test "corrects a row the reviewer wrote, by id", %{ctx: ctx, repo: repo} do
      reviewer_row =
        insert(repo, %{
          scope_type: "owner",
          scope_id: "default",
          category: "identity",
          key: "review_identity_0123456789ab_7",
          value: "Lives in Porto"
        })

      assert {:ok, %{memory: memory, published: :ok}} =
               LongTerm.replace(reviewer_row.id, "Lives in Lisbon", ctx)

      assert memory.id == reviewer_row.id
      assert memory.key == reviewer_row.key
      assert memory.category == "identity"
      assert active_values(repo) == ["Lives in Lisbon"]
      assert {:ok, %{user: "## Identity\n- Lives in Lisbon"}} = PromptFiles.load("main")
      assert_receive {:runtime_invalidated, :memory_tool}
    end

    test "refuses an unknown id and a row that is not its to change", %{ctx: ctx, repo: repo} do
      job_row =
        insert(repo, %{
          scope_type: "job",
          scope_id: "job-1",
          category: "job_run_summary",
          key: "latest",
          value: "the nightly digest ran"
        })

      assert {:error, :not_found} = LongTerm.replace(job_row.id + 1_000, "x", ctx)
      assert {:error, {:not_editable, "job_run_summary"}} = LongTerm.replace(job_row.id, "x", ctx)
      assert {:error, {:not_editable, "job_run_summary"}} = LongTerm.forget(job_row.id, "x", ctx)
      assert active_values(repo) == ["the nightly digest ran"]
    end

    test "cannot reach another owner's row", %{ctx: ctx, repo: repo} do
      other =
        insert(repo, %{
          owner_id: "someone-else",
          scope_type: "owner",
          scope_id: "someone-else",
          category: "identity",
          key: "city",
          value: "Lives in Oslo"
        })

      assert {:error, :not_found} = LongTerm.replace(other.id, "Lives in Rome", ctx)
      assert {:error, :not_found} = LongTerm.forget(other.id, "nosy", ctx)
    end
  end

  describe "forget/3" do
    test "a forgotten fact leaves the prompt, every recall, and can be restored", %{
      ctx: ctx,
      repo: repo
    } do
      {:ok, %{memory: kept}} = LongTerm.save("identity", "city", "Lives in Lisbon", ctx)
      {:ok, %{memory: gone}} = LongTerm.save("identity", "diet", "Is vegetarian", ctx)
      assert_receive {:runtime_invalidated, :memory_tool}
      assert_receive {:runtime_invalidated, :memory_tool}

      assert {:ok, %{memory: archived, published: :ok}} =
               LongTerm.forget(gone.id, "no longer true", ctx)

      assert archived.archived_by == "main_agent"
      assert archived.archive_reason == "no longer true"
      assert %DateTime{} = archived.archived_at
      assert_receive {:runtime_invalidated, :memory_tool}

      assert {:ok, %{user: "## Identity\n- Lives in Lisbon"}} = PromptFiles.load("main")
      assert active_values(repo) == [kept.value]
      assert Search.query("vegetarian", repo: repo, source: :memories, scope: :all) == []

      # Forgetting twice is a miss, not a second archive.
      assert {:error, :not_found} = LongTerm.forget(gone.id, "again", ctx)

      # Archived, not erased.
      assert {:ok, restored} = Repo.restore_memory(gone.id, server: repo)
      assert restored.value == "Is vegetarian"
    end

    test "a conversation note is forgotten without touching the prompt files", %{
      ctx: ctx,
      repo: repo
    } do
      note =
        insert(repo, %{
          scope_type: "conversation",
          scope_id: "telegram:chat-1:root",
          category: "fact",
          key: "draft_title",
          value: "Q3 plan"
        })

      assert {:ok, %{published: :not_shown}} = LongTerm.forget(note.id, "done with it", ctx)
      assert active_values(repo) == []
      refute_received {:runtime_invalidated, _reason}
    end
  end

  defp insert(repo, attrs) do
    base = %{agent_id: "main", owner_id: "default"}
    assert {:ok, memory} = Repo.upsert_memory(Map.merge(base, attrs), server: repo)
    memory
  end

  defp active_values(repo) do
    {:ok, rows} =
      Repo.get_memories(%{agent_id: "main", owner_id: "default", archived?: false}, server: repo)

    Enum.map(rows, & &1.value)
  end
end
