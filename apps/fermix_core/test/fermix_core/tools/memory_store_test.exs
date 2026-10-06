defmodule FermixCore.Tools.MemoryStoreTest do
  # async: false — the long-term path publishes prompt files, whose directory and
  # repo come from the global `:fermix_core, :memory` app env.
  use ExUnit.Case, async: false

  alias FermixCore.Memory.Store
  alias FermixCore.Tools.MemoryStore

  alias FermixCore.Memory.PromptFiles
  alias FermixCore.Memory.Repo

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
    db_path = Path.join(System.tmp_dir!(), "fermix-memory-store-tool-#{unique}.db")
    prompt_dir = Path.join(System.tmp_dir!(), "fermix-memory-store-tool-prompt-#{unique}")
    repo = :"mem_store_tool_repo_#{unique}"
    store = :"mem_store_tool_#{unique}"
    previous_config = Application.get_env(:fermix_core, :memory, [])

    Application.put_env(
      :fermix_core,
      :memory,
      Keyword.merge(previous_config,
        enabled: true,
        repo: repo,
        database_path: db_path,
        prompt_base_dir: prompt_dir
      )
    )

    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})
    start_supervised!(%{id: store, start: {Store, :start_link, [[name: store, repo: repo]]}})
    main_agent = start_supervised!({MainAgentStub, test_pid: self()})

    on_exit(fn ->
      Application.put_env(:fermix_core, :memory, previous_config)
      FermixTestSupport.SafeRm.rm_rf!(prompt_dir)

      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], fn path ->
        FermixTestSupport.SafeRm.rm(path)
      end)
    end)

    conv_key = {"telegram", "chat_#{unique}"}

    context = %{
      agent_name: "test_agent",
      conversation_key: conv_key,
      memory_store: store,
      memory_repo: repo,
      memory_agent_id: "main",
      memory_owner_id: "default",
      source_trust: :operator,
      main_agent_server: main_agent
    }

    %{context: context, conv_key: conv_key, store: store, repo: repo}
  end

  describe "name/0" do
    test "returns memory_store" do
      assert MemoryStore.name() == "memory_store"
    end
  end

  describe "description/0" do
    test "returns a non-empty string" do
      desc = MemoryStore.description()
      assert is_binary(desc)
      assert byte_size(desc) > 0
    end
  end

  describe "parameters/0" do
    test "requires only the value; key, category and id say which kind of save it is" do
      params = MemoryStore.parameters()
      assert params.type == "object"
      assert params.required == ["value"]
      assert Map.keys(params.properties) |> Enum.sort() == [:category, :id, :key, :value]

      assert params.properties.category.enum ==
               ~w(identity preference interest goal context directive)
    end
  end

  describe "execute/2 — a note for this conversation" do
    test "is stored, and the result says it is not long-term memory", %{
      context: context,
      conv_key: conv_key,
      store: store
    } do
      # A model that fills every property sends the optional ones as null.
      args = %{"key" => "user_name", "value" => "Alice", "category" => nil, "id" => nil}
      assert {:ok, result} = MemoryStore.execute(args, context)
      assert result.success == true
      assert result.output =~ "note for this conversation only: user_name"
      assert result.output =~ "not long-term memory"

      assert {:ok, "Alice"} = Store.recall(conv_key, "user_name", server: store)
      assert {:ok, %{user: nil, memory: nil}} = PromptFiles.load("main")
      refute_received {:runtime_invalidated, _reason}
    end

    test "with durable memory off, the result does not claim it will last", %{context: context} do
      {:ok, ets_only} =
        Store.start_link(
          name: :"mem_store_tool_ets_#{System.unique_integer([:positive])}",
          repo: :"no_such_repo_#{System.unique_integer([:positive])}"
        )

      assert {:ok, result} =
               MemoryStore.execute(
                 %{"key" => "user_name", "value" => "Alice"},
                 %{context | memory_store: ets_only}
               )

      assert result.success == true
      assert result.output =~ "Durable memory is turned off"
      assert result.output =~ "only until Fermix restarts"
      refute result.output =~ "Saved"
    end

    test "needs a key", %{context: context} do
      assert {:ok, %{success: false, error: error}} =
               MemoryStore.execute(%{"value" => "Alice"}, context)

      assert error =~ "key unless id is given"
    end

    test "overwrites existing memory", %{context: context, conv_key: conv_key, store: store} do
      MemoryStore.execute(%{"key" => "lang", "value" => "en"}, context)
      MemoryStore.execute(%{"key" => "lang", "value" => "fr"}, context)

      assert {:ok, "fr"} = Store.recall(conv_key, "lang", server: store)
    end
  end

  describe "execute/2 — long-term memory" do
    test "a category makes it long-term: saved, published, and the prompt invalidated", %{
      context: context,
      repo: repo
    } do
      args = %{"key" => "report_format", "value" => "Wants reports as one page"}

      assert {:ok, result} =
               MemoryStore.execute(Map.put(args, "category", "preference"), context)

      assert result.success == true
      assert result.output =~ ~r/^Saved to long-term memory: id=\d+ preference report_format\./
      assert result.output =~ "from the next turn"

      assert {:ok, %{user: "## Preferences\n- Wants reports as one page"}} =
               PromptFiles.load("main")

      assert_receive {:runtime_invalidated, :memory_tool}

      assert {:ok, [row]} =
               Repo.get_memories(%{agent_id: "main", owner_id: "default", archived?: false},
                 server: repo
               )

      assert %{scope_type: "owner", category: "preference"} = row
    end

    test "an id corrects the memory it names", %{context: context, repo: repo} do
      {:ok, existing} =
        Repo.upsert_memory(
          %{
            agent_id: "main",
            owner_id: "default",
            scope_type: "owner",
            scope_id: "default",
            category: "identity",
            key: "review_identity_0123456789ab_3",
            value: "Lives in Porto"
          },
          server: repo
        )

      # The id arrives as the model wrote it: here, digits in a string.
      assert {:ok, result} =
               MemoryStore.execute(
                 %{"id" => Integer.to_string(existing.id), "value" => "Lives in Lisbon"},
                 context
               )

      assert result.success == true
      assert result.output =~ "Updated memory id=#{existing.id} (identity): Lives in Lisbon"
      assert {:ok, %{user: "## Identity\n- Lives in Lisbon"}} = PromptFiles.load("main")
    end

    test "a refusal is an error that says what to do, and nothing is saved", %{
      context: context,
      repo: repo
    } do
      long = String.duplicate("word ", 60)

      assert {:ok, %{success: false, error: too_long}} =
               MemoryStore.execute(
                 %{"key" => "k", "value" => long, "category" => "context"},
                 context
               )

      assert too_long =~ "200 characters at most"
      assert too_long =~ "Shorten it and save again"

      assert {:ok, %{success: false, error: bad_category}} =
               MemoryStore.execute(
                 %{"key" => "k", "value" => "v", "category" => "fact"},
                 context
               )

      assert bad_category =~ "identity, preference, interest, goal, context, directive"

      assert {:ok, %{success: false, error: missing}} =
               MemoryStore.execute(%{"id" => 999_999, "value" => "v"}, context)

      assert missing =~ "No memory has that id"

      assert {:ok, %{success: false, error: bad_id}} =
               MemoryStore.execute(%{"id" => "twelve", "value" => "v"}, context)

      assert bad_id =~ "positive integer"

      assert {:ok, []} =
               Repo.get_memories(%{agent_id: "main", owner_id: "default", archived?: false},
                 server: repo
               )

      refute_received {:runtime_invalidated, _reason}
    end
  end

  describe "telemetry" do
    test "emits [:fermix, :tool, :exec] on success", %{context: context} do
      handler_id = attach_telemetry()

      MemoryStore.execute(%{"key" => "k", "value" => "v"}, context)

      assert_receive {:telemetry, [:fermix, :tool, :exec], measurements, metadata}
      assert is_integer(measurements.duration_ms)
      assert measurements.duration_ms >= 0
      assert metadata.tool == "memory_store"
      assert metadata.agent == "test_agent"
      assert metadata.success == true

      :telemetry.detach(handler_id)
    end
  end

  defp attach_telemetry do
    handler_id = "test-memory-store-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:fermix, :tool, :exec],
      fn event, measurements, metadata, _config ->
        if self() == test_pid and metadata.tool == "memory_store" do
          send(test_pid, {:telemetry, event, measurements, metadata})
        end
      end,
      nil
    )

    handler_id
  end
end
