defmodule FermixCore.Memory.CompactorTest do
  use ExUnit.Case, async: true

  alias FermixCore.Memory.Compactor
  alias FermixCore.Memory.Repo
  alias FermixCore.Resource.Registry

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

  defmodule RecordingAdapter do
    @behaviour FermixCore.Providers.Adapter

    @impl true
    def chat(messages, capabilities, opts) do
      send(
        Keyword.fetch!(opts, :test_pid),
        {:recording_adapter_chat, messages, capabilities, opts}
      )

      {:ok,
       %{
         content: "direct adapter summary",
         tool_calls: [],
         provider_state: %{},
         usage: %{prompt_tokens: 1, completion_tokens: 1, total_tokens: 2},
         model: Keyword.fetch!(opts, :model)
       }}
    end

    @impl true
    def continue(_provider_state, _tool_results, _opts), do: {:error, :not_used}

    @impl true
    def to_provider_tools(capabilities), do: capabilities

    @impl true
    def parse_tool_calls(_response), do: []

    @impl true
    def parse_response(response), do: response

    @impl true
    def supports_streaming?, do: false
  end

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-compactor-#{unique}.db")
    repo_name = :"compactor_repo_#{unique}"

    start_supervised!({Repo, name: repo_name, enabled: true, database_path: db_path})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
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
               token_budget: 10_000
             )

    assert result.messages == messages
    assert result.cache == nil
  end

  test "compaction summarizes through the real Anthropic adapter with no tools", %{repo: repo} do
    # §2.1 invariant test 2: memory/compaction paths call the selected
    # adapter with `capabilities: []` — the Anthropic adapter must omit
    # the tools field rather than send an empty list.
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)

      refute Map.has_key?(decoded, "tools")
      assert decoded["max_tokens"] == 8192

      Req.Test.json(conn, %{
        "model" => "claude-sonnet-4-6",
        "stop_reason" => "end_turn",
        "content" => [%{"type" => "text", "text" => "anthropic summary"}],
        "usage" => %{"input_tokens" => 5, "output_tokens" => 3}
      })
    end)

    route_key = %{
      provider: :anthropic,
      model: "claude-sonnet-4-6",
      auth_mode: :api_key,
      base_url: "https://api.anthropic.com/v1"
    }

    adapter_opts = [
      api_key: "sk-ant-test",
      model: "claude-sonnet-4-6",
      base_url: "https://api.anthropic.com/v1",
      req_options: [plug: {Req.Test, __MODULE__}]
    ]

    messages = [
      %{role: "system", content: "base prompt"},
      %{role: "user", content: String.duplicate("old user ", 80)},
      %{role: "assistant", content: String.duplicate("old assistant ", 80)},
      %{role: "user", content: "latest question"}
    ]

    assert {:ok, result} =
             Compactor.compact(messages,
               enabled: true,
               token_budget: 80,
               route: {route_key, adapter_opts},
               context: context(repo)
             )

    assert result.cache.summary == "anthropic summary"
  end

  test "summarizes older history while preserving leading system messages", %{repo: repo} do
    stub_summaries(["summary 1"])

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
               route: route(),
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

  test "summarizer is role-fenced and asks for tool attribution (M10 P2)", %{repo: repo} do
    stub_summaries(["summary 1"])

    messages = [
      %{role: "user", content: String.duplicate("old user ", 80)},
      %{role: "assistant", content: String.duplicate("old assistant ", 80)},
      %{role: "user", content: "latest question"}
    ]

    assert {:ok, _result} =
             Compactor.compact(messages,
               enabled: true,
               token_budget: 80,
               route: route(),
               context: context(repo)
             )

    assert_received {:summary_request, body}
    system_content = body |> Jason.decode!() |> request_system_text()

    # Role fence: the summarizer must never continue the conversation.
    assert system_content =~ "Do not continue the conversation"
    assert system_content =~ "output only the summary"
    # Provenance: facts from tool results carry inline attribution.
    assert system_content =~ "[tool: <name>]"
  end

  test "checkpoint message carries the reference-only provenance note (M10 P2)", %{repo: repo} do
    stub_summaries(["summary 1"])

    messages = [
      %{role: "user", content: String.duplicate("old user ", 80)},
      %{role: "assistant", content: String.duplicate("old assistant ", 80)},
      %{role: "user", content: "latest question"}
    ]

    assert {:ok, result} =
             Compactor.compact(messages,
               enabled: true,
               token_budget: 80,
               route: route(),
               context: context(repo)
             )

    checkpoint =
      Enum.find(result.messages, fn message ->
        message.role == "system" and
          String.starts_with?(message.content, "Conversation checkpoint summary:")
      end)

    assert checkpoint
    assert checkpoint.content =~ "Reference only"
    assert checkpoint.content =~ "latest user message wins"
    assert checkpoint.content =~ "summary 1"

    # The persisted checkpoint stores the RAW summary — the provenance note
    # never leaks into the prior fed to the next compaction.
    assert {:ok, [persisted]} = Repo.get_messages(checkpoint_selector(), server: repo, limit: 1)
    assert persisted.content == "summary 1"
  end

  defp request_system_text(%{"messages" => messages}) do
    messages
    |> Enum.filter(&(&1["role"] in ["system", "developer"]))
    |> Enum.map_join("\n", fn message ->
      case message["content"] do
        content when is_binary(content) -> content
        parts when is_list(parts) -> Enum.map_join(parts, "\n", &(&1["text"] || ""))
      end
    end)
  end

  defp request_system_text(%{"instructions" => instructions}) when is_binary(instructions),
    do: instructions

  test "does not create duplicate checkpoint revisions for unchanged summaries", %{repo: repo} do
    stub_summaries(["stable checkpoint", "stable checkpoint"])

    messages = compactable_messages()

    assert {:ok, %{compacted?: true}} =
             Compactor.compact(messages,
               enabled: true,
               token_budget: 60,
               route: route(),
               context: context(repo)
             )

    assert {:ok, %{compacted?: true}} =
             Compactor.compact(messages,
               enabled: true,
               token_budget: 60,
               route: route(),
               context: context(repo)
             )

    assert {:ok, [revision]} =
             Registry.list_revisions("main", "checkpoint", "telegram:chat-1:root", repo: repo)

    assert revision.revision == 1
    assert revision.content == "stable checkpoint"
    assert revision.mutation_source == "compaction"
  end

  test "keeps checkpoint revision histories isolated by conversation scope", %{repo: repo} do
    stub_summaries(["chat 1 summary", "chat 2 summary"])

    assert {:ok, %{compacted?: true}} =
             Compactor.compact(compactable_messages(),
               enabled: true,
               token_budget: 60,
               route: route(),
               context: context(repo, chat_id: "chat-1")
             )

    assert {:ok, %{compacted?: true}} =
             Compactor.compact(compactable_messages(),
               enabled: true,
               token_budget: 60,
               route: route(),
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
    stub_summaries(["summary 1"])

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
               route: route(),
               context: context(repo)
             )

    assert Enum.take(result.messages, length(composed_system_messages)) ==
             composed_system_messages

    assert Enum.any?(result.messages, &(&1.role == "system" and &1.content =~ "summary 1"))
    assert List.last(result.messages).content == "latest question"
  end

  test "continues with in-memory summary when checkpoint persistence fails" do
    stub_summaries(["summary 1"])
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
               route: route(),
               context: context(repo)
             )

    assert result.compacted?
    assert result.cache.summary == "summary 1"
    assert Enum.any?(result.messages, &(&1.content =~ "summary 1"))
  end

  test "does not duplicate injected checkpoint summaries on later compactions" do
    stub_summaries(["summary 1"])

    messages = [
      %{role: "system", content: "base prompt"},
      %{role: "user", content: String.duplicate("older turn ", 80)},
      %{role: "user", content: "new turn"}
    ]

    assert {:ok, first} =
             Compactor.compact(messages,
               enabled: true,
               token_budget: 60,
               route: route(),
               persist_checkpoints: false
             )

    second_messages =
      first.messages ++ [%{role: "assistant", content: String.duplicate("x", 240)}]

    assert {:ok, second} =
             Compactor.compact(second_messages,
               enabled: true,
               token_budget: 60,
               route: route(),
               persist_checkpoints: false,
               cache: first.cache
             )

    checkpoint_count =
      Enum.count(second.messages, fn message ->
        message.role == "system" and
          String.starts_with?(message.content, "Conversation checkpoint summary:")
      end)

    assert checkpoint_count == 1
    assert_received {:summary_request, _body}
    refute_receive {:summary_request, _body}, 100
  end

  test "uses persisted checkpoint as prior summary on later compactions", %{repo: repo} do
    stub_summaries(["summary 1"])

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
               route: route(),
               context: context(repo)
             )

    assert_received {:summary_request, body}
    assert body =~ "previous checkpoint"
  end

  test "instructs the summarizer to supersede stale info, dedup, and timestamp older turns",
       %{repo: repo} do
    stub_summaries(["summary 1"])

    messages = [
      %{role: "system", content: "base prompt"},
      %{
        role: "user",
        content: String.duplicate("older turn ", 80),
        timestamp: ~U[2026-05-20 09:00:00Z]
      },
      %{role: "user", content: "new turn"}
    ]

    assert {:ok, %{compacted?: true}} =
             Compactor.compact(messages,
               enabled: true,
               token_budget: 60,
               route: route(),
               context: context(repo)
             )

    assert_received {:summary_request, body}
    # Time-aware supersession + dedup instructions reach the summarizer.
    assert body =~ "supersede"
    assert body =~ "do not repeat information"
    # Older turns are rendered with their timestamp so recency is legible.
    assert body =~ "2026-05-20 09:00"
  end

  test "routes summaries through Adapter.chat/3 with empty capabilities" do
    stub_summaries(["routed summary"])

    assert {:ok, %{compacted?: true, cache: %{summary: "routed summary"}}} =
             Compactor.compact(compactable_messages(),
               enabled: true,
               token_budget: 60,
               route: route(),
               persist_checkpoints: false
             )

    assert_received {:summary_request, body}
    decoded = Jason.decode!(body)

    assert decoded["model"] == "gpt-5.4-mini"
    assert decoded["tools"] in [nil, []]
  end

  test "can compact through an explicitly provided adapter without mutating adapter options" do
    route_key = %{
      provider: :mock,
      model: "mock-model",
      auth_mode: :api_key,
      base_url: "mock://"
    }

    assert {:ok, %{compacted?: true, cache: %{summary: "direct adapter summary"}}} =
             Compactor.compact(compactable_messages(),
               enabled: true,
               token_budget: 60,
               adapter: RecordingAdapter,
               route: {route_key, [model: "mock-model", test_pid: self()]},
               persist_checkpoints: false
             )

    assert_received {:recording_adapter_chat, _messages, [], opts}
    assert Keyword.fetch!(opts, :model) == "mock-model"
    refute Keyword.has_key?(opts, :temperature)
  end

  defp compactable_messages do
    [
      %{role: "system", content: "base prompt"},
      %{role: "user", content: String.duplicate("older turn ", 80)},
      %{role: "assistant", content: String.duplicate("older response ", 80)},
      %{role: "user", content: "new turn"}
    ]
  end

  defp stub_summaries(summaries) do
    {:ok, agent} = Agent.start_link(fn -> summaries end)
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:summary_request, body})

      summary =
        Agent.get_and_update(agent, fn
          [next | rest] -> {next, rest}
          [] -> {"summary", []}
        end)

      Req.Test.json(conn, summary_response_body(summary))
    end)
  end

  defp summary_response_body(summary) do
    %{
      "model" => "gpt-5.4-mini",
      "output" => [
        %{
          "type" => "message",
          "id" => "msg_summary",
          "content" => [%{"type" => "output_text", "text" => summary}]
        }
      ],
      "usage" => %{"input_tokens" => 9, "output_tokens" => 3}
    }
  end

  defp route do
    route_key = %{
      provider: :openai,
      model: "gpt-5.4-mini",
      auth_mode: :api_key,
      base_url: "https://api.openai.com/v1"
    }

    adapter_opts = [
      api_key: "sk-test",
      model: route_key.model,
      base_url: route_key.base_url,
      req_options: [plug: {Req.Test, __MODULE__}]
    ]

    {route_key, adapter_opts}
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
