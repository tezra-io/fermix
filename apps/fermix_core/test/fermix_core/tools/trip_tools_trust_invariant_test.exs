defmodule FermixCore.Tools.TripToolsTrustInvariantTest do
  # M89 §14, written as the whole-feature invariant the Known Pitfalls
  # section mandates, after the lists' own: no trip tool is advertised or
  # executed, and no trip line or note is written, against a store that holds
  # a trip, on a turn that is not the owner's private turn or voice call; a job reaches a tool only by naming
  # it; and no prompt the turns share names the tools. The family is read from
  # the SEEDER, never spelled out here, so a member added later joins this
  # invariant or fails it.
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.Advertisement
  alias FermixCore.Capabilities.Builtin
  alias FermixCore.Capabilities.BuiltinSeeder
  alias FermixCore.Memory.Repo
  alias FermixCore.Prompt.RuntimeSections
  alias FermixCore.Tools.ScheduleJob
  alias FermixCore.Trips.Note
  alias FermixCore.Trips.Registry

  @family_prefix "trip_"

  @non_attended [
    {"guest trust",
     %{source_trust: :guest, computer_use_origin: :interactive, chat_type: "private"}},
    {"scheduled run naming no trip tool",
     %{
       source_trust: :operator,
       effective_trust: :operator,
       effective_allowed_tools: nil,
       conversation_key: {:scheduled_job, "job_1", "run_1"}
     }},
    {"detached background run", %{source_trust: :operator, computer_use_origin: :unattended}},
    {"delegated subagent",
     %{
       source_trust: :operator,
       computer_use_origin: :interactive,
       chat_type: "private",
       subagent_depth: 1
     }},
    {"coding continuation",
     %{
       source_trust: :operator,
       computer_use_origin: :interactive,
       chat_type: "private",
       harness_continuation_depth: 1
     }},
    {"missing source_trust", %{computer_use_origin: :interactive, chat_type: "private"}}
  ]

  @mention_key {"slack", "C0HALVERING", "1714000000.000100"}

  @shared [
    {"group chat", %{chat_type: "group"}},
    {"Slack channel mention", %{chat_type: "channel", conversation_key: @mention_key}},
    {"Slack mention with no chat type", %{chat_type: nil, conversation_key: @mention_key}},
    {"shared Buzz session",
     %{chat_type: "private", session_env: %{"BUZZ_RELAY_URL" => "wss://relay.invalid"}}}
  ]

  @private [
    {"Telegram private chat", %{chat_type: "private"}},
    {"Slack direct message", %{chat_type: "im", conversation_key: {"slack", "D0ORRIN", :root}}},
    {"paired phone", %{channel: "mobile", conversation_key: {"mobile", "phone-1", :root}}},
    {"Mac app", %{channel: "companion", conversation_key: {"companion", "mac-1", :root}}},
    {"voice call",
     %{
       computer_use_origin: :voice,
       realtime?: true,
       voice_call_id: "root",
       conversation_key: {"realtime", "dev-1", :root}
     }}
  ]

  defp tools, do: BuiltinSeeder.trip_tool_modules()
  defp capabilities, do: Enum.map(tools(), &Builtin.from_tool_module/1)

  # A store that holds a trip (R3#6): with one, a gate that let a turn through
  # would write the trip line and note, so the "none" below can fail.
  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-trip-trust-#{unique}.db")
    repo = :"trip_trust_repo_#{unique}"
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path}, id: repo)

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    create = %{"trip" => "Varonne", "ops" => [%{"op" => "create", "days" => 2}]}
    {:ok, _answer} = Registry.edit(create, owner(%{chat_type: "private"}, repo), repo: repo)
    %{repo: repo}
  end

  defp base(context, repo) do
    Map.merge(
      %{
        agent_name: "main",
        conversation_key: {"telegram", "40017", :root},
        memory_repo: repo,
        outside_sources: MapSet.new()
      },
      context
    )
  end

  defp owner(context, repo) do
    base(Map.merge(%{source_trust: :operator, computer_use_origin: :interactive}, context), repo)
  end

  defp advertised(context) do
    capabilities() |> Advertisement.prepare(context) |> Enum.map(& &1.name) |> Enum.sort()
  end

  defp refuses_everything(context, label) do
    for tool <- tools() do
      refute tool.advertise?(context), "#{tool.name()} was advertised on a #{label} turn"
      assert {:ok, result} = tool.execute(%{"trip" => "Varonne", "ops" => []}, context)
      refute result.success, "#{tool.name()} executed on a #{label} turn"
      assert result.error =~ tool.name()
    end

    assert advertised(context) == []
    assert Note.lines(context, "telegram", false) == %{rules: nil, index: nil}
  end

  test "the seeder exposes the family and every member is a registered built-in" do
    assert length(tools()) == 2
    assert Enum.all?(tools(), &(&1 in BuiltinSeeder.builtin_tool_modules()))
    assert Enum.all?(tools(), &function_exported?(&1, :advertise?, 1))
    assert Enum.sort(Enum.map(tools(), & &1.name())) == ["trip_edit", "trip_read"]
  end

  test "no seeded built-in named trip_* is missing from the family list" do
    seeded =
      BuiltinSeeder.builtin_tool_modules()
      |> Enum.filter(&String.starts_with?(&1.name(), @family_prefix))
      |> Enum.sort()

    assert seeded == Enum.sort(tools())
  end

  test "each is owner-only in the capability registry, the read read-only" do
    for tool <- tools(), do: assert(Builtin.from_tool_module(tool).owner_only? == true)

    assert Builtin.from_tool_module(FermixCore.Tools.TripRead).policy_class == :read_only
    assert Builtin.from_tool_module(FermixCore.Tools.TripEdit).policy_class == :read_write
  end

  for {label, context} <- @non_attended do
    test "no trip tool, line or note on a #{label} turn", %{repo: repo} do
      refuses_everything(base(unquote(Macro.escape(context)), repo), unquote(label))
    end
  end

  for {label, context} <- @shared do
    test "no trip tool, line or note in a #{label}", %{repo: repo} do
      refuses_everything(owner(unquote(Macro.escape(context)), repo), unquote(label))
    end
  end

  # The same store, on the owner's own turn: the line and the note are there.
  for {label, context} <- @private do
    test "the owner's #{label} is offered both tools, and told of the trip", %{repo: repo} do
      context = owner(unquote(Macro.escape(context)), repo)
      assert advertised(context) == ["trip_edit", "trip_read"]

      assert %{rules: rules, index: ~s(The owner's trips: "Varonne".)} =
               Note.lines(context, nil, false)

      assert is_binary(rules)
    end
  end

  test "a job reaches each tool only by naming it, and only at operator trust", %{repo: repo} do
    job =
      base(
        %{
          agent_name: "scheduled:job_1",
          conversation_key: {:scheduled_job, "job_1", "run_1"},
          source_trust: :operator,
          effective_trust: :operator,
          effective_allowed_tools: ["trip_read"]
        },
        repo
      )

    assert advertised(job) == ["trip_read"]

    assert advertised(%{job | effective_allowed_tools: ["trip_read", "trip_edit"]}) == [
             "trip_edit",
             "trip_read"
           ]

    assert advertised(%{job | effective_trust: :guest}) == []
    assert advertised(Map.put(job, :subagent_depth, 1)) == []

    # A job is told nothing per turn: its prompt is its own.
    assert Note.lines(job, nil, false) == %{rules: nil, index: nil}
  end

  test "the capability catalog, cached per profile and shared by group chats, names none of them" do
    for trust <- [:operator, :guest] do
      catalog = RuntimeSections.build([], capabilities: capabilities(), trust: trust)
      refute catalog =~ @family_prefix
    end
  end

  test "schedule_job gives a job a trip tool only from the owner's private turn", %{repo: repo} do
    args = %{
      "name" => "trip_morning_check",
      "schedule" => "0 7 * * *",
      "task" => "Read today's day of the Varonne trip and say what is first.",
      "allowed_tools" => ["trip_read"]
    }

    for context <- [
          owner(%{chat_type: "group"}, repo),
          base(
            %{
              conversation_key: {:scheduled_job, "job_1", "run_1"},
              source_trust: :operator,
              effective_trust: :operator,
              effective_allowed_tools: ["trip_read"]
            },
            repo
          )
        ] do
      {:ok, result} = ScheduleJob.execute(args, context)
      refute result.success
      assert result.error =~ "trip_read can be given to a job only from the owner's own"
    end
  end
end
