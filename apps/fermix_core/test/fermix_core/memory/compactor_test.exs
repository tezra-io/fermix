defmodule FermixCore.Memory.CompactorTest do
  use ExUnit.Case, async: true

  alias FermixCore.Memory.Compactor
  alias FermixCore.Memory.Repo
  alias FermixCore.Resource.Registry

  defmodule SummaryProvider do
    @behaviour FermixCore.Providers.Provider

    @impl true
    def chat(messages, opts) do
      calls = Process.get(:summary_provider_calls, [])
      Process.put(:summary_provider_calls, calls ++ [{messages, opts}])

      content = Process.get(:summary_provider_content, "summary #{length(calls) + 1}")

      {:ok,
       %{
         content: content,
         tool_calls: [],
         usage: %{prompt_tokens: 1, completion_tokens: 1, total_tokens: 2}
       }}
    end

    @impl true
    def models, do: {:ok, ["summary-model"]}
  end

  defmodule FailingRepo do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    @impl true
    def init(_opts), do: {:ok, %{}}

    @impl true
    def handle_call({:get_messages, _selector, _limit}, _from, state) do
      {:reply, {:ok, []}, state}
    end

    def handle_call({:insert_message, _attrs}, _from, state) do
      {:reply, {:error, :sqlite_failure}, state}
    end
  end

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-compactor-#{unique}.db")
    repo_name = :"compactor_repo_#{unique}"

    start_supervised!({Repo, name: repo_name, enabled: true, database_path: db_path})
    Process.put(:summary_provider_calls, [])

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &File.rm/1)
    end)

    %{repo: repo_name}
  end

  test "passes under-budget messages through unchanged" do
    messages = [
      %{role: "system", content: "keep this system prompt"},
      %{role: "user", content: "short"}
    ]

    assert {:ok, result} =
             Compactor.compact(messages,
               enabled: true,
               token_budget: 10_000,
               provider: SummaryProvider,
               model: "summary-model"
             )

    assert result.messages == messages
    assert result.cache == nil
    assert Process.get(:summary_provider_calls) == []
  end

  test "summarizes older history while preserving leading system messages", %{repo: repo} do
    messages = [
      %{role: "system", content: "base prompt must stay verbatim"},
      %{role: "user", content: String.duplicate("old user ", 80)},
      %{role: "assistant", content: String.duplicate("old assistant ", 80)},
      %{role: "user", content: "latest question"}
    ]

    assert {:ok, result} =
             Compactor.compact(messages,
               enabled: true,
               token_budget: 80,
               provider: SummaryProvider,
               model: "summary-model",
               context: context(repo)
             )

    assert [%{role: "system", content: "base prompt must stay verbatim"} | rest] =
             result.messages

    assert Enum.any?(rest, &(&1.role == "system" and &1.content =~ "summary 1"))
    assert List.last(result.messages).content == "latest question"
    assert result.cache.summary == "summary 1"

    assert {:ok, [checkpoint]} =
             Repo.get_messages(
               checkpoint_selector(),
               server: repo,
               limit: 10
             )

    assert checkpoint.kind == "checkpoint_summary"
    assert checkpoint.content == "summary 1"

    assert {:ok, [revision]} =
             Registry.list_revisions("main", "checkpoint", "telegram:chat-1:root", repo: repo)

    assert revision.content == "summary 1"
    assert revision.mutation_source == "compaction"

    assert revision.provenance == %{
             "trigger" => "compaction",
             "messages_summarized" => 2,
             "token_budget" => 80,
             "description" => "Compacted 2 messages into checkpoint summary"
           }
  end

  test "does not create duplicate checkpoint revisions for unchanged summaries", %{repo: repo} do
    Process.put(:summary_provider_content, "stable checkpoint")

    messages = compactable_messages()

    assert {:ok, %{compacted?: true}} =
             Compactor.compact(messages,
               enabled: true,
               token_budget: 60,
               provider: SummaryProvider,
               model: "summary-model",
               context: context(repo)
             )

    assert {:ok, %{compacted?: true}} =
             Compactor.compact(messages,
               enabled: true,
               token_budget: 60,
               provider: SummaryProvider,
               model: "summary-model",
               context: context(repo)
             )

    assert {:ok, [revision]} =
             Registry.list_revisions("main", "checkpoint", "telegram:chat-1:root", repo: repo)

    assert revision.revision == 1
    assert revision.content == "stable checkpoint"
    assert revision.mutation_source == "compaction"
  end

  test "keeps checkpoint revision histories isolated by conversation scope", %{repo: repo} do
    Process.put(:summary_provider_content, "chat 1 summary")

    assert {:ok, %{compacted?: true}} =
             Compactor.compact(compactable_messages(),
               enabled: true,
               token_budget: 60,
               provider: SummaryProvider,
               model: "summary-model",
               context: context(repo, chat_id: "chat-1")
             )

    Process.put(:summary_provider_content, "chat 2 summary")

    assert {:ok, %{compacted?: true}} =
             Compactor.compact(compactable_messages(),
               enabled: true,
               token_budget: 60,
               provider: SummaryProvider,
               model: "summary-model",
               context: context(repo, chat_id: "chat-2")
             )

    assert {:ok, [chat_1_revision]} =
             Registry.list_revisions("main", "checkpoint", "telegram:chat-1:root", repo: repo)

    assert {:ok, [chat_2_revision]} =
             Registry.list_revisions("main", "checkpoint", "telegram:chat-2:root", repo: repo)

    assert chat_1_revision.content == "chat 1 summary"
    assert chat_2_revision.content == "chat 2 summary"
    assert chat_1_revision.scope_id != chat_2_revision.scope_id
  end

  test "preserves composed prompt system messages verbatim during compaction", %{repo: repo} do
    composed_system_messages = [
      %{role: "system", content: "SOUL bootstrap"},
      %{role: "system", content: "AGENTS bootstrap"},
      %{role: "system", content: "USER memory"},
      %{role: "system", content: "AGENT memory"},
      %{role: "system", content: "## Runtime Contract\n- runtime rules"}
    ]

    messages =
      composed_system_messages ++
        [
          %{role: "user", content: String.duplicate("old user ", 80)},
          %{role: "assistant", content: String.duplicate("old assistant ", 80)},
          %{role: "user", content: "latest question"}
        ]

    assert {:ok, result} =
             Compactor.compact(messages,
               enabled: true,
               token_budget: 80,
               provider: SummaryProvider,
               model: "summary-model",
               context: context(repo)
             )

    assert Enum.take(result.messages, length(composed_system_messages)) ==
             composed_system_messages

    assert Enum.any?(result.messages, &(&1.role == "system" and &1.content =~ "summary 1"))
    assert List.last(result.messages).content == "latest question"
  end

  test "continues with in-memory summary when checkpoint persistence fails" do
    repo = start_supervised!(FailingRepo)

    messages = [
      %{role: "system", content: "base prompt"},
      %{role: "user", content: String.duplicate("older turn ", 80)},
      %{role: "user", content: "new turn"}
    ]

    assert {:ok, result} =
             Compactor.compact(messages,
               enabled: true,
               token_budget: 60,
               provider: SummaryProvider,
               model: "summary-model",
               context: context(repo)
             )

    assert result.compacted?
    assert result.cache.summary == "summary 1"
    assert Enum.any?(result.messages, &(&1.content =~ "summary 1"))
  end

  test "does not duplicate injected checkpoint summaries on later compactions" do
    messages = [
      %{role: "system", content: "base prompt"},
      %{role: "user", content: String.duplicate("older turn ", 80)},
      %{role: "user", content: "new turn"}
    ]

    assert {:ok, first} =
             Compactor.compact(messages,
               enabled: true,
               token_budget: 60,
               provider: SummaryProvider,
               model: "summary-model",
               persist_checkpoints: false
             )

    second_messages =
      first.messages ++ [%{role: "assistant", content: String.duplicate("x", 240)}]

    assert {:ok, second} =
             Compactor.compact(second_messages,
               enabled: true,
               token_budget: 60,
               provider: SummaryProvider,
               model: "summary-model",
               persist_checkpoints: false,
               cache: first.cache
             )

    checkpoint_count =
      Enum.count(second.messages, fn message ->
        message.role == "system" and
          String.starts_with?(message.content, "Conversation checkpoint summary:")
      end)

    assert checkpoint_count == 1
    assert Process.get(:summary_provider_calls) |> length() == 1
  end

  test "uses persisted checkpoint as prior summary on later compactions", %{repo: repo} do
    {:ok, _checkpoint} =
      Repo.insert_message(
        %{
          agent_id: "main",
          owner_id: "default",
          channel: "telegram",
          chat_id: "chat-1",
          thread_scope: :root,
          sender: "compactor",
          role: "system",
          kind: "checkpoint_summary",
          content: "previous checkpoint"
        },
        server: repo
      )

    messages = [
      %{role: "system", content: "base prompt"},
      %{role: "user", content: String.duplicate("older turn ", 80)},
      %{role: "user", content: "new turn"}
    ]

    assert {:ok, _result} =
             Compactor.compact(messages,
               enabled: true,
               token_budget: 60,
               provider: SummaryProvider,
               model: "summary-model",
               context: context(repo)
             )

    [{summary_messages, _opts}] = Process.get(:summary_provider_calls)
    rendered_prompt = Enum.map_join(summary_messages, "\n", & &1.content)

    assert rendered_prompt =~ "previous checkpoint"
  end

  defp compactable_messages do
    [
      %{role: "system", content: "base prompt"},
      %{role: "user", content: String.duplicate("older turn ", 80)},
      %{role: "assistant", content: String.duplicate("older response ", 80)},
      %{role: "user", content: "new turn"}
    ]
  end

  defp context(repo, opts \\ []) do
    chat_id = Keyword.get(opts, :chat_id, "chat-1")
    thread_scope = Keyword.get(opts, :thread_scope, :root)

    %{
      memory_repo: repo,
      memory_agent_id: "main",
      memory_owner_id: "default",
      conversation_key: {"telegram", chat_id, thread_scope}
    }
  end

  defp checkpoint_selector do
    %{
      agent_id: "main",
      channel: "telegram",
      chat_id: "chat-1",
      thread_scope: :root,
      kind: "checkpoint_summary"
    }
  end
end
