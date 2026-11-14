defmodule FermixCore.Realtime.SessionServerKeptTest do
  @moduledoc """
  What an OpenAI Realtime call is told of the owner's lists and trips
  (MILESTONE_85 §05, M89 §04): the lines a voice-channel turn gets, with a
  call's own presentation lines, built from the call's tool context when its
  instructions are; and a trip tool's answer carries the call's line only
  when the instructions did not.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixCore.Capabilities.Builtin
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Checklists.Note, as: ChecklistNote
  alias FermixCore.Checklists.Registry, as: ChecklistRegistry
  alias FermixCore.Memory.Repo
  alias FermixCore.Prompt.ChannelPresentation
  alias FermixCore.Realtime.Config
  alias FermixCore.Realtime.SessionServer
  alias FermixCore.ReplyBlocks
  alias FermixCore.Tools.TripEdit
  alias FermixCore.Tools.TripRead
  alias FermixCore.Trips.Note, as: TripNote
  alias FermixCore.Trips.Registry, as: TripRegistry
  alias FermixTestSupport.CallLeases
  alias FermixTestSupport.TelemetryCapture

  defmodule FakeOpenAIClient do
    def start_link(opts), do: Agent.start_link(fn -> %{opts: opts, events: []} end)

    def send_event(pid, event),
      do: Agent.update(pid, fn state -> %{state | events: state.events ++ [event]} end)

    def close(_pid), do: :ok
    def events(pid), do: Agent.get(pid, & &1.events)
  end

  def report_context(_args, context, test_pid) do
    send(test_pid, {:tool_context, context})
    {:ok, %{success: true, output: "ok", error: nil}}
  end

  # Every title and id here is invented.
  @owner %{
    agent_name: "main",
    conversation_key: {"telegram", "40091", :root},
    source_trust: :operator,
    computer_use_origin: :interactive,
    chat_type: "private",
    outside_sources: MapSet.new()
  }

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-rt-kept-#{unique}.db")
    repo = :"rt_kept_repo_#{unique}"
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path}, id: repo)
    holder = start_supervised!({ReplyBlocks, name: nil})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{repo: repo, holder: holder}
  end

  defp keep_list!(repo) do
    changes = [%{"list" => "Groceries", "ops" => [%{"op" => "create"}]}]
    {:ok, _answer} = ChecklistRegistry.edit(%{"changes" => changes}, @owner, repo: repo)
  end

  defp keep_trip!(repo) do
    ops = [%{"op" => "create", "days" => 3, "starts_on" => "2031-07-04"}]

    {:ok, _answer} =
      TripRegistry.edit(%{"trip" => "Varonne", "ops" => ops}, @owner,
        repo: repo,
        notifier: fn _changes -> :ok end
      )
  end

  # The call's own tool context, as `SessionServer` builds it: no channel and
  # no chat type, so a voice call is known by its origin alone.
  defp call_context(%{repo: repo, holder: holder}) do
    %{
      agent_name: "realtime",
      conversation_key: {"realtime", "device-40091", :root},
      memory_repo: repo,
      reply_blocks: holder,
      realtime?: true,
      source_trust: :operator
    }
  end

  defp start_call!(ctx, opts \\ []) do
    server = start_call_server!(ctx, opts)
    :ok = SessionServer.call_start(server)
    server
  end

  defp start_call_server!(ctx, opts) do
    {:ok, server} =
      SessionServer.start_link(
        session_scope: Keyword.get(opts, :session_scope, :root),
        companion: self(),
        endpoint: :desktop,
        call_lease: CallLeases.own!(),
        config: Config.normalize(enabled: true),
        openai_client: FakeOpenAIClient,
        api_key: "sk-test",
        safety_identifier: "safe-id",
        capabilities: [
          Builtin.from_tool_module(TripRead),
          Builtin.from_tool_module(TripEdit),
          context_reporter()
        ],
        context: call_context(ctx),
        task_supervisor:
          start_supervised!(Supervisor.child_spec({Task.Supervisor, []}, id: make_ref())),
        prompt_loader: fn _opts ->
          {:ok, %{messages: [%{role: "system", content: "prompt"}], parts: [], accounting: []}}
        end
      )

    server
  end

  defp context_reporter do
    Capability.new(%{
      name: "report_context",
      description: "Reports the context a tool is run with.",
      parameters: %{"type" => "object"},
      kind: :builtin,
      executor: {__MODULE__, :report_context, [self()]},
      policy_class: :read_only
    })
  end

  # A call's own session id, its realtime events pinned to the test by it.
  defp traced_scope do
    scope = "session:kept-#{System.unique_integer([:positive])}"
    TelemetryCapture.attach([[:fermix, :realtime, :session_updated]], session_id: scope)
    scope
  end

  defp instructions(server) do
    [event] = server |> SessionServer.openai_pid() |> FakeOpenAIClient.events()
    event.session.instructions
  end

  # What a Live or Grok hand-off turn on the voice channel is told, in the
  # order `Agents.TurnRunner` appends it.
  defp hand_off_lines(ctx) do
    hand_off = Map.merge(@owner, %{channel: "voice", computer_use_origin: :voice})
    hand_off = Map.merge(hand_off, %{memory_repo: ctx.repo})
    trips = TripNote.lines(hand_off, "voice", false)
    lists = [ChecklistNote.rules(hand_off, "voice", false), ChecklistNote.index(hand_off)]
    {lists, trips}
  end

  defp tool_output(server, name, args) do
    call_id = "call-#{name}"
    call = %{"call_id" => call_id, "name" => name, "arguments" => Jason.encode!(args)}
    :ok = SessionServer.handle_provider_event(server, {:function_call, call})
    assert_receive {:realtime, %{type: "tool_event", status: "completed", name: ^name}}

    server
    |> SessionServer.openai_pid()
    |> FakeOpenAIClient.events()
    |> Enum.find_value(fn
      %{item: %{type: "function_call_output", call_id: ^call_id, output: output}} -> output
      _other -> nil
    end)
  end

  test "keeping a list and a trip, the call is told what a voice-channel turn is", ctx do
    keep_list!(ctx.repo)
    keep_trip!(ctx.repo)
    {[list_rules, list_index], trips} = hand_off_lines(ctx)
    scope = traced_scope()
    server = start_call!(ctx, session_scope: scope)

    assert instructions(server) ==
             Enum.join(["prompt", list_rules, trips.rules, list_index, trips.index], "\n\n")

    # A call whose lines were read carries no mark of a read that failed.
    :ok = SessionServer.handle_provider_event(server, {:session_updated, %{}})
    assert_receive {:telemetry, [:fermix, :realtime, :session_updated], _measurements, meta}
    refute Map.has_key?(meta, :kept_lines)
    refute Map.has_key?(meta, :kept_lines_reason)

    assert list_rules =~ "\n" <> ChannelPresentation.checklist_line("voice", false)
    assert trips.rules =~ "\n" <> ChannelPresentation.trip_line("voice", false)
    assert list_index == ~s(The owner's lists: "Groceries".)
    assert trips.index == ~s|The owner's trips: "Varonne" (4 to 6 Jul 2031).|
  end

  # As on a text turn, the lists' rules ride every owner's call, since a first
  # list is made there too; their index and every trip line need one kept.
  test "keeping no list and no trip, the call is told only the lists' rules", ctx do
    {[list_rules, nil], %{rules: nil, index: nil}} = hand_off_lines(ctx)
    text = instructions(start_call!(ctx))

    assert text == "prompt\n\n" <> list_rules
    refute text =~ "The owner's lists:"
    refute text =~ "lives in their trips"
    refute text =~ "The owner's trips:"
  end

  test "a trip tool's answer carries the call's line only when the call was not told it", ctx do
    spoken = ChannelPresentation.trip_line("voice", false)
    untold = start_call!(ctx)

    created =
      tool_output(untold, "trip_edit", %{
        "trip" => "Varonne",
        "ops" => [%{"op" => "create", "days" => 2, "starts_on" => "2031-07-04"}]
      })

    assert created =~ spoken
    refute created =~ "No trip is drawn here"
    assert tool_output(untold, "trip_read", %{"trip" => "Varonne"}) =~ spoken

    told = start_call!(ctx)
    assert instructions(told) =~ spoken
    refute tool_output(told, "trip_read", %{"trip" => "Varonne"}) =~ spoken
  end

  # A store that cannot answer costs the call only what it would have read:
  # the lists' and trips' index lines, and the trips' rules, which only a kept
  # trip brings. The lists' rules read nothing and stay. The reads share one
  # budget far inside `call_start`'s own 10 s bound, which two reads at the
  # store's 5 s each used to reach; a store that exits mid-request, or one
  # that is gone (a Repo restarting), is the same, and none of them ends the
  # call. The call's trace says it ran without them.
  test "a store that does not answer, exits or is gone: the call starts with the lists' rules",
       ctx do
    owner_call = %{source_trust: :operator, computer_use_origin: :voice}
    list_rules = ChecklistNote.rules(owner_call, "voice", false)
    silent = start_supervised!({Task, fn -> receive do: (:never_sent -> :ok) end}, id: :silent)

    exiting =
      start_supervised!(
        {Task,
         fn ->
           receive do: ({:"$gen_call", _from, _request} -> exit({:shutdown, :restarting}))
         end},
        id: :exiting
      )

    gone = :"rt_kept_gone_repo_#{System.unique_integer([:positive])}"

    for {store, reason} <- [
          {silent, "timeout after 1500 ms"},
          {exiting, ":restarting"},
          {gone, ":noproc"}
        ] do
      scope = traced_scope()
      server = start_call_server!(%{ctx | repo: store}, session_scope: scope)

      log = capture_log(fn -> assert :ok = SessionServer.call_start(server) end)

      assert instructions(server) == "prompt\n\n" <> list_rules, reason
      assert [_one] = Regex.scan(~r/could not be read/, log), log
      assert log =~ "the owner's lists and trips could not be read ("
      assert log =~ reason
      assert log =~ "this session.update goes without their index lines and the trips' rules"

      :ok = SessionServer.handle_provider_event(server, {:session_updated, %{}})

      assert_receive {:telemetry, [:fermix, :realtime, :session_updated], _measurements,
                      %{kept_lines: "left_out", kept_lines_reason: traced}}

      assert traced =~ reason
    end
  end

  # A refresh that cannot read the store keeps the lines the call already
  # had, so a reload never takes guidance away; the log says why.
  test "a session.update mid-call that cannot read the store keeps the call's lines", ctx do
    keep_list!(ctx.repo)
    keep_trip!(ctx.repo)
    server = start_call!(ctx)
    told = instructions(server)
    repo = Process.whereis(ctx.repo)

    :ok = :sys.suspend(repo)
    log = capture_log(fn -> assert {:ok, _summary} = SessionServer.reload_runtime(server) end)
    :ok = :sys.resume(repo)

    [_first, refreshed] = server |> SessionServer.openai_pid() |> FakeOpenAIClient.events()
    assert refreshed.session.instructions == told
    assert told =~ "The owner's trips:"
    assert log =~ "the owner's lists and trips could not be read (timeout after 1500 ms)"
    assert log =~ "this session.update keeps the lines of the last one"

    spoken = ChannelPresentation.trip_line("voice", false)
    refute tool_output(server, "trip_read", %{"trip" => "Varonne"}) =~ spoken
  end

  # The call reaches the voice lines by the voice-call fact, never by a
  # channel: `Native`, `Capabilities.AccessGate` and the harness tools key on
  # a context's `:channel`, so the call's tool context still names none.
  test "a tool on the call is run with no channel and no chat type", ctx do
    keep_trip!(ctx.repo)
    server = start_call!(ctx)
    assert tool_output(server, "report_context", %{}) =~ "ok"
    assert_receive {:tool_context, context}

    refute Map.has_key?(context, :channel)
    refute Map.has_key?(context, :chat_type)
    assert context.computer_use_origin == :voice
    assert context.trips_told == true
    assert ChannelPresentation.channel_of(context) == "voice"
  end

  # A refresh mid-call (`reload_runtime`, a new `session.update`) builds the
  # lines again from the store as it is then, and the tool answers follow it.
  test "a session.update mid-call tells the call of a trip made since it began", ctx do
    server = start_call!(ctx)
    refute instructions(server) =~ "The owner's trips:"
    keep_trip!(ctx.repo)

    assert {:ok, _summary} = SessionServer.reload_runtime(server)

    [_first, refreshed] = server |> SessionServer.openai_pid() |> FakeOpenAIClient.events()
    assert refreshed.session.instructions =~ ~s|The owner's trips: "Varonne"|
    spoken = ChannelPresentation.trip_line("voice", false)
    refute tool_output(server, "trip_read", %{"trip" => "Varonne"}) =~ spoken
  end
end
