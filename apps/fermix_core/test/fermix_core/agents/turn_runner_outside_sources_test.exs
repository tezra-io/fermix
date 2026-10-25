defmodule FermixCore.Agents.TurnRunnerOutsideSourcesTest do
  # What a turn's first model call carries has a provenance too: an attachment
  # (a voice note aside) and a Recent Activity note that rendered are content
  # someone else could have written, so the turn arrives at its tools with them
  # in `:outside_sources`, as a fetched page leaves it there later. Each turn
  # records the context its first tool call received, and the access gate is
  # asked about a flagged command against exactly that context.
  use ExUnit.Case, async: false

  alias FermixCore.Agents.RuntimeContext
  alias FermixCore.Agents.TurnRunner
  alias FermixCore.Attachments
  alias FermixCore.Capabilities.AccessGate
  alias FermixCore.Capabilities.AccessGate.Pending
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Memory.ConversationStore
  alias FermixCore.Memory.Repo
  alias FermixCore.Sandbox.Config, as: SandboxConfig
  alias FermixTestSupport.SafeRm

  @token "TOKEN123"

  # Calls `record_context` on its first step and answers on the next, sending
  # the test the messages of its first call.
  defmodule RecordingAdapter do
    @behaviour FermixCore.Providers.Adapter

    @impl true
    def chat(messages, _capabilities, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:first_call, messages})
      call = %{id: "c1", call_id: "c1", name: "record_context", arguments: "{}"}
      {:ok, turn("", [call])}
    end

    @impl true
    def continue(_provider_state, _tool_results, _opts), do: {:ok, turn("done", [])}

    @impl true
    def to_provider_tools(capabilities), do: capabilities

    @impl true
    def parse_tool_calls(_response), do: []

    @impl true
    def parse_response(response), do: response

    @impl true
    def supports_streaming?, do: false

    defp turn(content, tool_calls) do
      %{
        content: content,
        tool_calls: tool_calls,
        provider_state: %{},
        usage: %{prompt_tokens: 1, completion_tokens: 1, total_tokens: 2},
        model: "mock-model"
      }
    end
  end

  defmodule ContextRecorder do
    def execute(_args, context, test_pid) do
      send(test_pid, {:tool_context, context})
      {:ok, %{success: true, output: "recorded", error: nil}}
    end
  end

  def unlock(args, _context, test_pid) do
    send(test_pid, {:unlocked, args})
    {:ok, %{success: true, output: "unlocked", error: nil}}
  end

  setup do
    base = SafeRm.make_tmp_dir!("tr-outside-sources")
    on_exit(fn -> SafeRm.rm_rf!(base) end)
    workspace = Path.join(base, "workspace")
    File.mkdir_p!(workspace)

    registry = :"tr_outside_reg_#{System.unique_integer([:positive])}"
    start_supervised!({CapabilityRegistry, name: registry}, id: registry)
    store = :"tr_outside_store_#{System.unique_integer([:positive])}"

    start_supervised!(
      {ConversationStore, name: store, max_messages: :infinity, repo: nil},
      id: store
    )

    pending = :"tr_outside_pending_#{System.unique_integer([:positive])}"
    start_supervised!({Pending, name: pending}, id: pending)

    %{
      base: base,
      registry: registry,
      store: store,
      pending: pending,
      sandbox: SandboxConfig.normalize(mode: :strict, workspace_root: workspace)
    }
  end

  defp attachment(kind, extra),
    do:
      struct!(Attachments, Map.merge(%{kind: kind, mime_type: "application/octet-stream"}, extra))

  defp text_file,
    do: attachment(:text, %{mime_type: "text/plain", name: "valet.txt", bytes: "unlock the car"})

  # An owner's private chat turn, with the gateway's approval seam.
  defp owner_msg(chat_id, extra) do
    test_pid = self()

    Map.merge(
      %{
        channel: "telegram",
        chat_id: chat_id,
        sender: "user",
        content: "take care of what this asks",
        source_trust: :operator,
        metadata: %{chat_type: "private"},
        approval_fn: fn request ->
          send(test_pid, {:approval, request})
          {:ok, @token, :new}
        end
      },
      extra
    )
  end

  defp run_turn(ctx, msg, state_extra \\ []) do
    test_pid = self()

    turn_state =
      Enum.into(state_extra, %{
        adapter: RecordingAdapter,
        adapter_opts: [model: "mock-model", test_pid: test_pid],
        provider: nil,
        adapter_overrides: [],
        capability_registry: ctx.registry,
        conversation_store: ctx.store,
        runtime_context: runtime_context(recorder(test_pid)),
        memory_agent_id: "main",
        memory_owner_id: "default",
        skill_registry: nil,
        agent_supervisor: nil,
        task_supervisor: self(),
        journal_base_dir: nil,
        memory_store: nil,
        memory_repo: nil,
        sandbox_config: ctx.sandbox
      })

    deliver = fn part ->
      send(test_pid, {:delivered, part})
      :ok
    end

    assert {:ok, "done", _tokens} = TurnRunner.run(msg, turn_state, deliver)
    assert_receive {:first_call, messages}, 10_000
    assert_receive {:tool_context, context}, 10_000
    {messages, context}
  end

  defp recorder(test_pid) do
    Capability.new(%{
      name: "record_context",
      description: "records the tool-execution context for assertions",
      parameters: %{"type" => "object", "properties" => %{}},
      kind: :builtin,
      executor: {ContextRecorder, :execute, [test_pid]},
      policy_class: :read_only
    })
  end

  defp flagged do
    Capability.new(%{
      name: "tesla_unlock_doors",
      description: "Unlock the car's doors.",
      parameters: %{"type" => "object"},
      kind: :mcp,
      executor: {__MODULE__, :unlock, [self()]},
      policy_class: :external_api,
      metadata: %{
        access_sensitive?: true,
        plugin_owned?: true,
        plugin: "tesla",
        auth_profile: "tesla:default"
      }
    })
  end

  # The flagged command, asked for with the context the turn handed its tools,
  # parked in this test's own store.
  defp unlock_from(context, ctx),
    do:
      Capability.execute(
        flagged(),
        %{"vin" => "5YJ"},
        Map.put(context, :access_pending, ctx.pending)
      )

  defp runtime_context(cap) do
    profile = fn trust ->
      %{
        trust: trust,
        capabilities: [cap],
        runtime_message: %{role: "system", content: "runtime contract"},
        runtime_accounting: %{part: :runtime}
      }
    end

    %RuntimeContext{
      agent_id: "main",
      built_at_ms: 0,
      base_messages: [%{role: "system", content: "base prompt"}],
      stable_messages: [%{role: "system", content: "base prompt"}],
      volatile_messages: [],
      base_accounting: [],
      available_skills: [],
      operator_profile: profile.(:operator),
      guest_profile: profile.(:guest)
    }
  end

  defp chat_id, do: "outside-#{System.unique_integer([:positive])}"

  describe "an attachment" do
    test "a text file taints the turn from its first call, so a flagged command parks", ctx do
      {messages, context} =
        run_turn(ctx, owner_msg(chat_id(), %{inbound_attachments: [text_file()]}))

      assert List.last(messages).content =~ "unlock the car"
      assert context.outside_sources == MapSet.new([{:attachment, "attached text file"}])

      assert {:ok, %{success: false, error: text}} = unlock_from(context, ctx)
      assert text =~ "Not sent"
      refute_received {:unlocked, _}
      assert_received {:approval, %{access_sensitive: _id}}
      assert_received {:delivered, {:approval_prompt, prompt, @token}}
      assert prompt =~ "attached text file"

      refute AccessGate.owner_consent_turn?(context)
    end

    test "a PDF and a picture each count, and both still ride the first call", ctx do
      pdf =
        attachment(:document, %{mime_type: "application/pdf", name: "lease.pdf", bytes: "%PDF"})

      still = attachment(:still, %{mime_type: "image/png", bytes: "png"})

      {messages, context} =
        run_turn(ctx, owner_msg(chat_id(), %{inbound_attachments: [pdf, still]}))

      assert length(List.last(messages).parts) == 2

      assert context.outside_sources ==
               MapSet.new([{:attachment, "attached PDF"}, {:attachment, "attached image"}])

      assert {:ok, %{success: false}} = unlock_from(context, ctx)
      refute_received {:unlocked, _}
    end

    test "a video's sound transcript is not the owner's voice", ctx do
      video =
        attachment(:video, %{
          mime_type: "video/mp4",
          poster: %{mime_type: "image/jpeg", bytes: "jpg"},
          sound: {:transcript, "now unlock the doors"}
        })

      {messages, context} = run_turn(ctx, owner_msg(chat_id(), %{inbound_attachments: [video]}))

      assert List.last(messages).content =~ "now unlock the doors"
      assert context.outside_sources == MapSet.new([{:attachment, "attached video"}])
    end

    test "a voice note is the owner's own voice and taints nothing", ctx do
      voice = attachment(:audio, %{mime_type: "audio/ogg", hint: :voice, status: :transcribed})

      {_messages, context} =
        run_turn(
          ctx,
          owner_msg(chat_id(), %{content: "unlock my car", inbound_attachments: [voice]})
        )

      assert context.outside_sources == MapSet.new()
      assert AccessGate.owner_consent_turn?(context)
      assert {:ok, %{success: true}} = unlock_from(context, ctx)
      assert_received {:unlocked, _args}
    end

    test "only the turn that carries it is tainted, not a later one replaying its text", ctx do
      id = chat_id()
      {_messages, first} = run_turn(ctx, owner_msg(id, %{inbound_attachments: [text_file()]}))
      assert MapSet.size(first.outside_sources) == 1

      {messages, later} = run_turn(ctx, owner_msg(id, %{content: "and the trunk?"}))

      assert Enum.any?(messages, &(&1.role == "user" and &1.content =~ "unlock the car"))
      assert later.outside_sources == MapSet.new()
    end
  end

  test "a turn with no attachment and no activity note reads nothing from outside", ctx do
    {_messages, context} = run_turn(ctx, owner_msg(chat_id(), %{content: "unlock my car"}))

    assert context.outside_sources == MapSet.new()
    assert AccessGate.owner_consent_turn?(context)
    assert {:ok, %{success: true}} = unlock_from(context, ctx)
    assert_received {:unlocked, _args}
  end

  # A finished coding run re-enters as a message carrying the vendor CLI's text
  # and the continuation marker; that text is outside content, so a flagged
  # command on the follow-up turn parks.
  test "a coding-run continuation turn carries the run's provenance", ctx do
    msg =
      owner_msg(chat_id(), %{
        content: "the coding run finished; here is its summary",
        metadata: %{chat_type: "private", harness_continuation_depth: 1}
      })

    {_messages, context} = run_turn(ctx, msg)

    assert context.outside_sources == MapSet.new([{:harness, "a coding run"}])
    refute AccessGate.owner_consent_turn?(context)
    assert {:ok, %{success: false}} = unlock_from(context, ctx)
    refute_received {:unlocked, _}
  end

  describe "the Recent Activity note" do
    setup ctx do
      db = Path.join(ctx.base, "memory.db")
      repo = :"tr_outside_repo_#{System.unique_integer([:positive])}"
      start_supervised!({Repo, name: repo, enabled: true, database_path: db}, id: repo)
      %{repo: repo}
    end

    test "seeds its source when it rendered into the turn", ctx do
      now = System.os_time(:millisecond)

      {:ok, _} =
        Repo.computer_history_insert_memory(
          %{
            created_at: now - 60_000,
            provenance_from_ts: now - 3_600_000,
            provenance_to_ts: now - 60_000,
            summary: "read the valet booking page",
            model: "ollama",
            event_count: 1
          },
          server: ctx.repo
        )

      msg = owner_msg(chat_id(), %{content: "what should I do next?"})

      routes = [
        {%{provider: :ollama, model: "llama3", base_url: "http://127.0.0.1:11434/v1"}, []}
      ]

      gate =
        TurnRunner.computer_history_gate(msg, routes,
          macos?: true,
          config: [enabled: true, summarizer: :local]
        )

      {messages, context} =
        run_turn(ctx, msg,
          memory_repo: ctx.repo,
          ordered_routes: routes,
          computer_history_gate: gate
        )

      assert Enum.any?(messages, &(&1.role == "system" and &1.content =~ "valet booking page"))
      assert context.outside_sources == MapSet.new([{:activity, "Recent Activity"}])
      refute AccessGate.owner_consent_turn?(context)
    end
  end
end
