defmodule FermixCore.Memory.ReviewerTest do
  use ExUnit.Case, async: false

  alias FermixCore.Memory.PromptFiles
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Reviewer
  alias FermixCore.Providers.Error, as: ProviderError

  defmodule FakeProvider do
    def chat(messages, _opts) do
      send(Process.get(:test_pid), {:review_prompt, messages})

      {:ok,
       %{
         content:
           Jason.encode!(%{
             operations: [
               %{
                 action: "add",
                 target: "user",
                 category: "preference",
                 value: "User prefers terse answers"
               }
             ]
           }),
         tool_calls: [],
         usage: %{prompt_tokens: 1, completion_tokens: 1, total_tokens: 2}
       }}
    end
  end

  defmodule NothingProvider do
    def chat(_messages, _opts) do
      {:ok, %{content: "Nothing to save.", tool_calls: [], usage: %{}}}
    end
  end

  defmodule FailProvider do
    def chat(_messages, _opts), do: {:error, "boom"}
  end

  defmodule MalformedToolProvider do
    def chat(_messages, _opts) do
      {:ok, %{content: "", tool_calls: [%{"unexpected" => "shape"}], usage: %{}}}
    end
  end

  # The real-world "nothing to save" shapes: reasoning models narrate around the
  # verdict, so the reply is never the bare sentinel the old exact-match wanted.
  defmodule ProseNothingProvider do
    def chat(_messages, _opts) do
      {:ok,
       %{
         content:
           "Nothing to save.\n\nThis is a transient task request (look up an X " <>
             "account's numeric id) with no durable, reusable facts.",
         tool_calls: [],
         usage: %{}
       }}
    end
  end

  defmodule PreambleNothingProvider do
    def chat(_messages, _opts) do
      {:ok,
       %{
         content:
           "I'll review these excerpts for durable facts.\n\nThe messages are " <>
             "transient one-off requests already covered by existing memory.\n\n" <>
             "Nothing to save.",
         tool_calls: [],
         usage: %{}
       }}
    end
  end

  # A genuine structured-output attempt that is malformed must still fail loudly
  # (and be retried), not be silently swallowed as a no-op.
  defmodule BrokenJsonProvider do
    def chat(_messages, _opts) do
      {:ok,
       %{content: ~s({"operations": [{"action": "add", "target":), tool_calls: [], usage: %{}}}
    end
  end

  setup do
    Process.put(:test_pid, self())
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-reviewer-#{unique}.db")
    prompt_dir = Path.join(System.tmp_dir!(), "fermix-reviewer-prompt-#{unique}")
    repo = :"reviewer_repo_#{unique}"
    previous_config = Application.get_env(:fermix_core, :memory, [])

    Application.put_env(
      :fermix_core,
      :memory,
      Keyword.merge(previous_config,
        enabled: true,
        repo: repo,
        database_path: db_path,
        prompt_base_dir: prompt_dir,
        review_interval_hours: 24,
        review_max_messages: 40,
        review_input_token_budget: 4_000,
        review_failure_backoff_ms: 300_000
      )
    )

    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})

    on_exit(fn ->
      Application.put_env(:fermix_core, :memory, previous_config)
      FermixTestSupport.SafeRm.rm_rf!(prompt_dir)

      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], fn path ->
        FermixTestSupport.SafeRm.rm(path)
      end)
    end)

    %{repo: repo}
  end

  test "manual review applies operations, advances pointer, and rebuilds prompt files", %{
    repo: repo
  } do
    selector = conversation_selector()
    insert_user_message(repo, "Please keep answers terse.")

    test_pid = self()
    handler_id = "reviewer-memory-write-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:fermix, :memory, :write],
      fn _e, meas, meta, _c -> send(test_pid, {:memory_write, meas, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, result} =
             Reviewer.review_now(
               provider: FakeProvider,
               repo: repo,
               agent_id: "main",
               owner_id: "default",
               conversation_key: {"telegram", "chat-1", :root}
             )

    assert result.status == :ok
    assert result.ops_added == 1

    # The durable write is observable + conversation-attributed end to end.
    assert_receive {:memory_write, %{count: 1}, meta}
    assert meta.tool == "memory_write"
    assert meta.action == :added
    assert meta.channel == "telegram"
    assert meta.chat_id == "chat-1"
    assert meta.agent == "memory_reviewer"
    assert String.starts_with?(meta.session_id, "memory_review:main:telegram:chat-1:")
    assert_receive {:review_prompt, messages}
    prompt_text = Enum.map_join(messages, "\n", & &1.content)
    assert prompt_text =~ "Please keep answers terse"
    assert prompt_text =~ "<user_md used=\""
    assert prompt_text =~ "<memory_md used=\""

    assert {:ok, state} = Repo.get_memory_review_state(selector, server: repo)
    assert state.last_reviewed_message_id != nil
    assert state.failure_count == 0

    assert {:ok, %{user: user_text}} = PromptFiles.load("main")
    assert user_text =~ "User prefers terse answers"
  end

  # MILESTONE_31 §13.2: coarse city/region/postal-code identity stays storable,
  # but a street address or a coordinate pair is configuration (typed
  # Personalization), never curated memory. The guidance lives in the reviewer's
  # system prompt, so the prompt the provider actually receives is the proof.
  test "the reviewer prompt keeps coarse location but bars precise location", %{repo: repo} do
    insert_user_message(repo, "I moved to Jersey City.")

    assert {:ok, _result} =
             Reviewer.review_now(
               provider: FakeProvider,
               repo: repo,
               agent_id: "main",
               owner_id: "default",
               conversation_key: {"telegram", "chat-1", :root}
             )

    assert_receive {:review_prompt, messages}
    system = Enum.find(messages, &(&1.role == "system")).content

    assert system =~ "city, region, or postal code"
    assert system =~ "street address"
    assert system =~ "coordinates"
  end

  defmodule RouteFailAdapter do
    def chat(_messages, _capabilities, opts) do
      send(Process.get(:test_pid), {:route_chat, :primary, opts[:model]})
      {:error, ProviderError.transport(:anthropic, __MODULE__, :timeout)}
    end
  end

  defmodule RouteOkAdapter do
    def chat(_messages, _capabilities, opts) do
      send(Process.get(:test_pid), {:route_chat, :fallback, opts[:model]})
      {:ok, %{content: "Nothing to save.", tool_calls: [], usage: %{}}}
    end
  end

  test "the turn route chain wins over the legacy provider default and fails over", %{repo: repo} do
    insert_user_message(repo, "hello")

    routes = [
      {%{provider: :anthropic, model: "claude-x", auth_mode: :api_key, base_url: "https://a/v1"},
       [adapter: RouteFailAdapter, model: "claude-x"]},
      {%{provider: :openai, model: "gpt-x", auth_mode: :api_key, base_url: "https://o/v1"},
       [adapter: RouteOkAdapter, model: "gpt-x"]}
    ]

    # The turn runner passes BOTH `provider:` (its always-present module
    # default) and `routes:` — the chain must win, and a timed-out primary
    # must fall over to the fallback route (§7).
    assert {:ok, result} =
             Reviewer.review_now(
               provider: FailProvider,
               routes: routes,
               repo: repo,
               agent_id: "main",
               owner_id: "default",
               conversation_key: {"telegram", "chat-1", :root}
             )

    assert result.status == :nothing_to_save
    assert_receive {:route_chat, :primary, "claude-x"}
    assert_receive {:route_chat, :fallback, "gpt-x"}
  end

  defmodule TagFailAdapter do
    def chat(_messages, _capabilities, opts) do
      send(Process.get(:test_pid), {:tagged, :primary, opts[:agent], opts[:session_id]})
      {:error, ProviderError.transport(:anthropic, __MODULE__, :timeout)}
    end
  end

  defmodule TagOkAdapter do
    def chat(_messages, _capabilities, opts) do
      send(Process.get(:test_pid), {:tagged, :fallback, opts[:agent], opts[:session_id]})
      {:ok, %{content: "Nothing to save.", tool_calls: [], usage: %{}}}
    end
  end

  test "reviewer tags its provider call with agent + per-run session_id, surviving failover", %{
    repo: repo
  } do
    message = insert_user_message(repo, "hello")

    # No `adapter:`/`provider:` pin — the reviewer consumes the route chain
    # (active primary, then fallback) and must attribute every attempt so the
    # llm_call trace no longer surfaces as `agent: unknown`.
    routes = [
      {%{provider: :anthropic, model: "claude-x", auth_mode: :api_key, base_url: "https://a/v1"},
       [adapter: TagFailAdapter, model: "claude-x"]},
      {%{provider: :openai, model: "gpt-x", auth_mode: :api_key, base_url: "https://o/v1"},
       [adapter: TagOkAdapter, model: "gpt-x"]}
    ]

    assert {:ok, result} =
             Reviewer.review_now(
               routes: routes,
               repo: repo,
               agent_id: "main",
               owner_id: "default",
               conversation_key: {"telegram", "chat-1", :root}
             )

    assert result.status == :nothing_to_save

    expected_session = "memory_review:main:telegram:chat-1:root:#{message.id}"

    assert_receive {:tagged, :primary, "memory_reviewer", ^expected_session}
    assert_receive {:tagged, :fallback, "memory_reviewer", ^expected_session}
  end

  test "reviewer emits a :review closer carrying the run session_id", %{repo: repo} do
    message = insert_user_message(repo, "Please keep answers terse.")

    test_pid = self()
    handler_id = "reviewer-memory-review-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:fermix, :memory, :review],
      fn _e, meas, meta, _c -> send(test_pid, {:review_done, meas, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, result} =
             Reviewer.review_now(
               provider: FakeProvider,
               repo: repo,
               agent_id: "main",
               owner_id: "default",
               conversation_key: {"telegram", "chat-1", :root}
             )

    assert result.status == :ok

    # The closer shares the run id with the provider.call / memory.write spans, so
    # the exporter ships the run on this event instead of via the TTL sweep.
    expected_session = "memory_review:main:telegram:chat-1:root:#{message.id}"

    assert_receive {:review_done, meas, meta}
    assert meta.session_id == expected_session
    assert meta.fired == true
    assert meta.status == :ok
    assert meta.channel == "telegram"
    assert meta.chat_id == "chat-1"
    assert meas.ops_added == 1
  end

  test "nothing to save advances the reviewed pointer without rebuilding", %{repo: repo} do
    insert_user_message(repo, "hello")

    assert {:ok, result} =
             Reviewer.review_now(
               provider: NothingProvider,
               repo: repo,
               agent_id: "main",
               owner_id: "default",
               conversation_key: {"telegram", "chat-1", :root}
             )

    assert result.status == :nothing_to_save
    assert {:ok, %{user: nil, memory: nil}} = PromptFiles.load("main")
  end

  test "a prose 'nothing to save' reply is a clean no-op, not a parse failure", %{repo: repo} do
    selector = conversation_selector()
    message = insert_user_message(repo, "what's my X username?")

    assert {:ok, result} =
             Reviewer.review_now(
               provider: ProseNothingProvider,
               repo: repo,
               agent_id: "main",
               owner_id: "default",
               conversation_key: {"telegram", "chat-1", :root}
             )

    assert result.status == :nothing_to_save

    # The pointer advances so the same transient messages are not re-reviewed,
    # and no failure/backoff is recorded.
    assert {:ok, state} = Repo.get_memory_review_state(selector, server: repo)
    assert state.last_reviewed_message_id == message.id
    assert state.failure_count == 0
    assert state.last_review_failed_at == nil
  end

  test "a reasoning preamble ending in the sentinel is also a no-op", %{repo: repo} do
    insert_user_message(repo, "list open issues in elixir-lang/elixir")

    assert {:ok, result} =
             Reviewer.review_now(
               provider: PreambleNothingProvider,
               repo: repo,
               agent_id: "main",
               owner_id: "default",
               conversation_key: {"telegram", "chat-1", :root}
             )

    assert result.status == :nothing_to_save
  end

  test "malformed structured output still fails loudly and leaves the pointer", %{repo: repo} do
    selector = conversation_selector()
    insert_user_message(repo, "remember I prefer dark mode")

    assert {:error, {:invalid_review_json, _reason}} =
             Reviewer.review_now(
               provider: BrokenJsonProvider,
               repo: repo,
               agent_id: "main",
               owner_id: "default",
               conversation_key: {"telegram", "chat-1", :root}
             )

    assert {:ok, state} = Repo.get_memory_review_state(selector, server: repo)
    assert state.last_reviewed_message_id == nil
    assert state.failure_count == 1
  end

  test "manual review respects the max message cap", %{repo: repo} do
    first = insert_user_message(repo, "first durable preference")
    _second = insert_user_message(repo, "second durable preference")

    assert {:ok, result} =
             Reviewer.review_now(
               provider: FakeProvider,
               repo: repo,
               agent_id: "main",
               owner_id: "default",
               conversation_key: {"telegram", "chat-1", :root},
               review_max_messages: 1
             )

    assert result.input_messages == 1
    assert_receive {:review_prompt, messages}
    prompt_text = Enum.map_join(messages, "\n", & &1.content)
    assert prompt_text =~ "first durable preference"
    refute prompt_text =~ "second durable preference"

    assert {:ok, state} = Repo.get_memory_review_state(conversation_selector(), server: repo)
    assert state.last_reviewed_message_id == first.id
  end

  test "failed review leaves the pointer untouched; a later success resets failure_count", %{
    repo: repo
  } do
    selector = conversation_selector()
    insert_user_message(repo, "Please keep answers terse.")

    assert {:error, "boom"} =
             Reviewer.review_now(
               provider: FailProvider,
               repo: repo,
               agent_id: "main",
               owner_id: "default",
               conversation_key: {"telegram", "chat-1", :root}
             )

    assert {:ok, failed} = Repo.get_memory_review_state(selector, server: repo)
    assert failed.last_reviewed_message_id == nil
    assert failed.failure_count == 1
    assert failed.last_review_failed_at != nil

    assert {:ok, result} =
             Reviewer.review_now(
               provider: FakeProvider,
               repo: repo,
               agent_id: "main",
               owner_id: "default",
               conversation_key: {"telegram", "chat-1", :root}
             )

    assert result.status == :ok
    assert {:ok, recovered} = Repo.get_memory_review_state(selector, server: repo)
    assert recovered.last_reviewed_message_id != nil
    assert recovered.failure_count == 0
    assert recovered.last_review_failed_at == nil
  end

  test "background review skips under interval after a recent review", %{repo: repo} do
    insert_user_message(repo, "first preference")

    assert {:ok, _result} =
             Reviewer.review_now(
               provider: FakeProvider,
               repo: repo,
               agent_id: "main",
               owner_id: "default",
               conversation_key: {"telegram", "chat-1", :root}
             )

    insert_user_message(repo, "second preference")

    assert :ok =
             attach_skip_telemetry(fn ->
               Reviewer.start_background(
                 provider: FakeProvider,
                 repo: repo,
                 agent_id: "main",
                 owner_id: "default",
                 conversation_key: {"telegram", "chat-1", :root}
               )
             end)

    assert_receive {:review_skipped, %{reason: :under_interval}}
  end

  test "background review skips when a review is already in flight", %{repo: repo} do
    insert_user_message(repo, "hello")

    assert {:ok, _claimed} =
             Repo.claim_memory_review(conversation_selector(), DateTime.utc_now(), 300_000,
               server: repo
             )

    assert :ok =
             attach_skip_telemetry(fn ->
               Reviewer.start_background(
                 provider: FakeProvider,
                 repo: repo,
                 agent_id: "main",
                 owner_id: "default",
                 conversation_key: {"telegram", "chat-1", :root}
               )
             end)

    assert_receive {:review_skipped, %{reason: :concurrent_run}}
  end

  test "malformed tool calls are skipped, not crashed", %{repo: repo} do
    insert_user_message(repo, "hello")

    assert {:ok, result} =
             Reviewer.review_now(
               provider: MalformedToolProvider,
               repo: repo,
               agent_id: "main",
               owner_id: "default",
               conversation_key: {"telegram", "chat-1", :root}
             )

    assert result.status == :nothing_to_save
    assert result.ops_skipped == 1
  end

  defp attach_skip_telemetry(fun) do
    handler = "reviewer-skip-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler,
      [:fermix, :memory, :review_skipped],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:review_skipped, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    fun.()
  end

  defp insert_user_message(repo, content) do
    assert {:ok, message} =
             Repo.insert_message(
               %{
                 agent_id: "main",
                 owner_id: "default",
                 channel: "telegram",
                 chat_id: "chat-1",
                 thread_scope: "root",
                 sender: "alice",
                 role: "user",
                 kind: "chat_message",
                 content: content
               },
               server: repo
             )

    message
  end

  defp conversation_selector do
    %{
      agent_id: "main",
      owner_id: "default",
      channel: "telegram",
      chat_id: "chat-1",
      thread_scope: "root"
    }
  end
end
