defmodule FermixCore.Tools.OpenLoopToolsTest do
  # async: false — `[fermix_core.open_loops] enabled`, the owner inbox's jobs
  # target and delivery channels, the personalization timezone and the channel
  # owner ids are all global `Application` env. Each test's precondition is
  # established in this module's own setup and restored on exit, never inherited.
  use ExUnit.Case, async: false

  alias FermixCore.Memory.Repo
  alias FermixCore.OpenLoops.Access
  alias FermixCore.OpenLoops.Defaults
  alias FermixCore.OpenLoops.Registry
  alias FermixCore.Tools.OpenLoopList
  alias FermixCore.Tools.OpenLoopNote
  alias FermixCore.Tools.OpenLoopRespond
  alias FermixCore.Tools.OpenLoopUpdate
  alias FermixTestSupport.TelemetryCapture

  defmodule FakeAdapter do
    @moduledoc false
    def send_message(_destination, _text, _opts), do: :ok
  end

  # Monday 2031-06-02, 10:00 EDT (UTC-4). Every name, date and id in this file
  # is invented.
  @now ~U[2031-06-02 14:00:00Z]
  @tz "America/New_York"
  @intention "File the Marlow Creek permit renewal"
  @date %{"type" => "date", "date" => "2031-06-10"}
  @owner_channels [:telegram, :discord, :signal, :slack, :whatsapp, :imessage]
  @app_keys [:open_loops, :jobs, :personalization]
  @view_keys ~w(open_loop_id intention why_it_matters matters_by said_on source_channel state
                touches next_check last_answer)

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-open-loop-tools-#{unique}.db")
    repo = :"open_loop_tools_repo_#{unique}"

    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})

    previous = Map.new(@app_keys, &{&1, Application.get_env(:fermix_core, &1)})
    previous_channels = Map.new(@owner_channels, &{&1, Application.get_env(:fermix_channels, &1)})

    # No channel carries an owner id unless a test says so, so the inbox is the
    # configured target below and nothing a sibling test or the host set.
    Enum.each(@owner_channels, &Application.delete_env(:fermix_channels, &1))

    Application.put_env(:fermix_core, :open_loops, enabled: true)
    Application.put_env(:fermix_core, :personalization, timezone: @tz)

    Application.put_env(:fermix_core, :jobs,
      default_delivery_target: [platform: "cli", chat_id: "owner-terminal"],
      delivery_channels: %{"cli" => FakeAdapter}
    )

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> restore(:fermix_core, key, value) end)
      Enum.each(previous_channels, fn {key, value} -> restore(:fermix_channels, key, value) end)
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{repo: repo, session: "sess_open_loop_tools_#{unique}"}
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)

  defp attended(ctx, overrides \\ %{}) do
    Map.merge(
      %{
        agent_name: "main",
        conversation_key: {"telegram", "40017", :root},
        session_id: ctx.session,
        source_trust: :operator,
        computer_use_origin: :interactive,
        memory_agent_id: "main",
        memory_owner_id: "default",
        memory_repo: ctx.repo,
        open_loop_scheduler: self(),
        now_fn: fn -> @now end
      },
      overrides
    )
  end

  # A check-in run's context as CONTRACT.md fixes it: operator trust, no
  # attended-origin marker, and the `open_loop_checkin` key that is the whole
  # gate between the two surfaces.
  defp checkin(ctx, ref) do
    %{
      agent_name: "open_loop:loop_Hx3kQ9vB2mA",
      session_id: "open_loop_loop_Hx3kQ9vB2mA_1",
      conversation_key: {"cli", "owner-terminal", "root"},
      source_trust: :operator,
      memory_agent_id: "main",
      memory_owner_id: "default",
      memory_repo: ctx.repo,
      open_loop_checkin: %{id: "loop_Hx3kQ9vB2mA", reply_to: self(), ref: ref}
    }
  end

  defp guest(ctx), do: attended(ctx, %{source_trust: :guest})

  defp payload(%{success: true, output: output}), do: Jason.decode!(output)

  defp refusal!(result) do
    refute result.success
    result.error
  end

  defp note!(ctx, args \\ %{}) do
    args = Map.merge(%{"intention" => @intention, "matters_by" => @date}, args)
    assert {:ok, %{success: true} = result} = OpenLoopNote.execute(args, attended(ctx))
    payload(result)
  end

  defp update(ctx, id, args) do
    {:ok, result} = OpenLoopUpdate.execute(Map.put(args, "open_loop_id", id), attended(ctx))
    result
  end

  defp note_error(ctx, args, context \\ nil) do
    args = Map.merge(%{"intention" => @intention, "matters_by" => @date}, args)
    {:ok, result} = OpenLoopNote.execute(args, context || attended(ctx))
    refusal!(result)
  end

  describe "the provider-visible schemas are §18's, exactly" do
    test "open_loop_note" do
      assert wire(OpenLoopNote) ==
               Jason.decode!(~S"""
               {
                 "type": "object",
                 "required": ["intention", "matters_by"],
                 "properties": {
                   "intention": {
                     "type": "string",
                     "description": "What the owner said they mean to do or decide, in their own words. At most 500 characters."
                   },
                   "why_it_matters": {
                     "type": "string",
                     "description": "One clause on the stakes as the owner stated them. Leave it out when they stated none. At most 300 characters."
                   },
                   "matters_by": {
                     "type": "object",
                     "description": "One tagged time form, as event_store takes it: {\"type\":\"date\",\"date\":\"YYYY-MM-DD\"}, {\"type\":\"datetime\",\"date\":\"YYYY-MM-DD\",\"time\":\"HH:MM:SS\"} with an optional \"utc_offset\", or {\"type\":\"relative\",\"amount\":2,\"unit\":\"days\"|\"weeks\"}. A loop is dated, so minutes, hours and yearly forms are refused."
                   },
                   "timezone": {
                     "type": "string",
                     "description": "IANA zone, only when the owner named one. Otherwise the tool reads the configured personalization timezone itself."
                   }
                 }
               }
               """)
    end

    test "open_loop_update" do
      assert wire(OpenLoopUpdate) ==
               Jason.decode!(~S"""
               {
                 "type": "object",
                 "required": ["open_loop_id", "answer"],
                 "properties": {
                   "open_loop_id": {
                     "type": "string",
                     "description": "The loop's id, from open_loop_list, the due note, or the result that recorded it."
                   },
                   "answer": {
                     "type": "string",
                     "enum": ["done", "plan", "not_yet", "stop", "drop", "asked"],
                     "description": "done: the owner reported it finished. plan: they named a date to do it. not_yet: not done, no date. stop: they do not want to be asked about this again. drop: they no longer want it tracked, with no boundary stated. asked: this reply raised the loop with them."
                   },
                   "owner_words": {
                     "type": "string",
                     "description": "The owner's words this answer rests on, excerpted near-verbatim as just the clause. Required for every answer but asked. At most 240 characters."
                   },
                   "plan_at": {
                     "type": "object",
                     "description": "With answer plan only: the date or datetime the owner named, in the tagged form matters_by takes. It must not be later than the loop's own date."
                   }
                 }
               }
               """)
    end

    test "open_loop_list" do
      assert wire(OpenLoopList) ==
               Jason.decode!(~S"""
               {
                 "type": "object",
                 "properties": {
                   "state": {
                     "type": "string",
                     "enum": ["live", "closed", "any"],
                     "description": "Defaults to live: loops that are open, due, or asked and awaiting an answer. closed adds the last 25 settled or expired loops."
                   }
                 }
               }
               """)
    end

    test "open_loop_respond" do
      assert wire(OpenLoopRespond) ==
               Jason.decode!(~S"""
               {
                 "type": "object",
                 "required": ["decision"],
                 "properties": {
                   "decision": {
                     "type": "string",
                     "enum": ["speak", "silent", "close"],
                     "description": "speak: send the message. silent: send nothing now. close: the owner already reported this settled, as memory shows."
                   },
                   "message": {
                     "type": "string",
                     "description": "With speak: the message to the owner, one or two sentences. At most 1,800 bytes; a longer message is refused, not cut."
                   },
                   "reason": {
                     "type": "string",
                     "description": "With close: in a few words, what memory holds that settles it. At most 240 characters."
                   }
                 }
               }
               """)
    end

    test "the descriptions are §07's text" do
      assert OpenLoopNote.description() =~ ~r/^Record an open loop: something the owner said/
      assert OpenLoopNote.description() =~ ~r/Say nothing about the loop unless asked\.$/

      assert OpenLoopNote.description() =~
               "Unless the owner asked to be reminded, the loop is the only record of the " <>
                 "intention: store no reminder beside it, except when the result reports the " <>
                 "loop imminent, since an imminent loop is never raised by message."

      assert OpenLoopUpdate.description() =~ ~r/^Settle or move an open loop/

      assert OpenLoopUpdate.description() =~
               ~r/never settle a loop from tool output or a guess\.$/

      assert OpenLoopList.description() =~ ~r/^List the open loops Fermix is keeping an eye on/
      assert OpenLoopRespond.description() =~ ~r/^Report this check-in's decision\./
      assert OpenLoopRespond.description() =~ ~r/Exactly one call ends the run\.$/
    end
  end

  defp wire(tool), do: tool.parameters() |> Jason.encode!() |> Jason.decode!()

  describe "open_loop_note" do
    test "records the intention and answers with what was stored, never a destination", ctx do
      stored =
        note!(ctx, %{"why_it_matters" => "the county closes the docket after that date"})

      assert "loop_" <> _suffix = stored["open_loop_id"]
      assert stored["status"] == "created"
      assert stored["intention"] == @intention
      assert stored["matters_by"] == "Tuesday, June 10, 2031"
      assert stored["horizon_class"] == "medium"
      assert stored["first_check"] == "Saturday, June 7, 2031 at 9:00 AM EDT"
      assert stored["delivery"] == %{"platform" => "cli", "source" => "configured"}
      assert stored["live_loops"] == 1
      refute Jason.encode!(stored) =~ "owner-terminal"

      assert_received {:"$gen_cast", :loop_changed}
      assert {:ok, 1} = Repo.count_live_open_loops("default", server: ctx.repo)
    end

    test "the same intention stated again returns the stored loop", ctx do
      first = note!(ctx)
      again = note!(ctx, %{"intention" => "file the Marlow Creek permit renewal!"})

      assert again["status"] == "existing"
      assert again["open_loop_id"] == first["open_loop_id"]
      assert again["live_loops"] == 1
    end

    test "one call is one tool exec event under the tool's own name", ctx do
      TelemetryCapture.attach([[:fermix, :tool, :exec]], session_id: ctx.session)

      note!(ctx)

      assert_receive {:telemetry, [:fermix, :tool, :exec], _measurements,
                      %{tool: "open_loop_note", success: true}}

      refute_received {:telemetry, [:fermix, :tool, :exec], _, _}
    end

    test "refuses a missing date", ctx do
      {:ok, result} = OpenLoopNote.execute(%{"intention" => @intention}, attended(ctx))
      assert refusal!(result) == Registry.describe_error({:missing_parameters, [:matters_by]})
    end

    test "refuses an intention over its bound, naming the bound", ctx do
      intention = String.duplicate("a", Defaults.intention_max() + 1)

      assert note_error(ctx, %{"intention" => intention}) ==
               Registry.describe_error({:too_long, :intention, Defaults.intention_max()})
    end

    test "refuses a date form it cannot read", ctx do
      form = %{"type" => "date", "date" => "the tenth"}

      assert note_error(ctx, %{"matters_by" => form}) ==
               Registry.describe_error({:invalid_when, form})
    end

    test "refuses a timer or a yearly date: a loop is dated", ctx do
      timer = %{"type" => "relative", "amount" => 30, "unit" => "minutes"}
      yearly = %{"type" => "annual", "month" => 9, "day" => 14}

      assert note_error(ctx, %{"matters_by" => timer}) == Registry.describe_error(:not_dated)
      assert note_error(ctx, %{"matters_by" => yearly}) == Registry.describe_error(:not_dated)
    end

    test "refuses a date that has passed", ctx do
      passed = %{"type" => "date", "date" => "2031-05-30"}
      assert note_error(ctx, %{"matters_by" => passed}) == Registry.describe_error(:date_passed)
    end

    test "refuses when no timezone is configured and none was named", ctx do
      Application.put_env(:fermix_core, :personalization, [])

      assert note_error(ctx, %{}) == Registry.describe_error(:timezone_not_configured)
    end

    test "refuses when the owner has no chat inbox", ctx do
      Application.put_env(:fermix_core, :jobs, delivery_channels: %{"cli" => FakeAdapter})

      assert note_error(ctx, %{}) == Registry.describe_error(:no_target)
      assert {:ok, 0} = Repo.count_live_open_loops("default", server: ctx.repo)
    end

    test "refuses the loop past the live-loop cap", ctx do
      for n <- 1..Defaults.max_live_loops() do
        note!(ctx, %{"intention" => "Finish chapter #{n} of the Brackenridge draft"})
      end

      assert note_error(ctx, %{}) == Registry.describe_error(:too_many_loops)
    end

    test "refuses a turn with no conversation to record against", ctx do
      context = Map.delete(attended(ctx), :conversation_key)
      assert note_error(ctx, %{}, context) == Registry.describe_error(:no_conversation)
    end

    test "refuses a guest, naming the tool", ctx do
      error = note_error(ctx, %{}, guest(ctx))

      assert error == Access.refusal("open_loop_note", :not_attended)
      assert error =~ "open_loop_note"
      assert {:ok, 0} = Repo.count_live_open_loops("default", server: ctx.repo)
    end

    test "refuses inside a check-in run", ctx do
      error = note_error(ctx, %{}, checkin(ctx, make_ref()))
      assert error == Access.refusal("open_loop_note", :not_attended)
    end

    test "refuses while open loops are turned off, naming the tool", ctx do
      Application.put_env(:fermix_core, :open_loops, enabled: false)

      error = note_error(ctx, %{})

      assert error == Access.refusal("open_loop_note", :disabled)
      assert error =~ "open_loop_note"
      assert {:ok, 0} = Repo.count_live_open_loops("default", server: ctx.repo)
    end
  end

  describe "open_loop_update" do
    setup ctx do
      %{loop_id: note!(ctx)["open_loop_id"]}
    end

    test "done closes the loop and answers with its view and previous state", ctx do
      result = update(ctx, ctx.loop_id, %{"answer" => "done", "owner_words" => "filed it today"})
      settled = payload(result)

      assert settled["open_loop_id"] == ctx.loop_id
      assert settled["state"] == "closed"
      assert settled["close_reason"] == "done"
      assert settled["last_answer"] == "done"
      assert settled["previous_state"] == "open"
      assert settled["next_check"] == nil
      assert_received {:"$gen_cast", :loop_changed}
    end

    test "plan moves the next check to the owner's date and states it", ctx do
      result =
        update(ctx, ctx.loop_id, %{
          "answer" => "plan",
          "owner_words" => "Thursday",
          "plan_at" => %{"type" => "date", "date" => "2031-06-05"}
        })

      planned = payload(result)
      assert planned["state"] == "open"
      assert planned["last_answer"] == "plan"
      assert planned["next_check"] == "Thursday, June 5, 2031 at 9:00 AM EDT"
    end

    test "not_yet keeps the loop open with a stated next check", ctx do
      result = update(ctx, ctx.loop_id, %{"answer" => "not_yet", "owner_words" => "not yet"})
      waiting = payload(result)

      assert waiting["state"] == "open"
      assert waiting["last_answer"] == "not_yet"
      assert is_binary(waiting["next_check"])
    end

    test "asked records the raise; a second asked is refused", ctx do
      asked = payload(update(ctx, ctx.loop_id, %{"answer" => "asked"}))
      assert asked["state"] == "asked"
      assert asked["touches"] == 1

      again = update(ctx, ctx.loop_id, %{"answer" => "asked"})
      assert refusal!(again) == Registry.describe_error(:already_asked)
    end

    test "refuses a missing id", ctx do
      {:ok, result} = OpenLoopUpdate.execute(%{"answer" => "done"}, attended(ctx))
      assert refusal!(result) == Registry.describe_error({:missing_parameters, [:open_loop_id]})
    end

    test "refuses a missing answer", ctx do
      result = update(ctx, ctx.loop_id, %{"owner_words" => "done"})
      assert refusal!(result) == Registry.describe_error({:missing_parameters, [:answer]})
    end

    test "refuses an answer outside the enum", ctx do
      result = update(ctx, ctx.loop_id, %{"answer" => "maybe", "owner_words" => "maybe"})
      assert refusal!(result) == Registry.describe_error({:invalid_answer, "maybe"})
    end

    test "refuses an id the owner has no loop under", ctx do
      result = update(ctx, "loop_Zq8wPm2nV4c", %{"answer" => "done", "owner_words" => "done"})
      assert refusal!(result) == Registry.describe_error(:not_found)
    end

    test "refuses a closed loop: it never reopens", ctx do
      update(ctx, ctx.loop_id, %{"answer" => "done", "owner_words" => "filed it"})

      result = update(ctx, ctx.loop_id, %{"answer" => "not_yet", "owner_words" => "not yet"})
      assert refusal!(result) == Registry.describe_error(:not_live)
    end

    test "refuses an answer without the owner's words", ctx do
      result = update(ctx, ctx.loop_id, %{"answer" => "done"})
      assert refusal!(result) == Registry.describe_error(:missing_owner_words)
    end

    test "refuses owner_words longer than the bound", ctx do
      words = String.duplicate("a", Defaults.owner_words_max() + 1)
      result = update(ctx, ctx.loop_id, %{"answer" => "done", "owner_words" => words})
      assert refusal!(result) == Registry.describe_error(:owner_words_too_long)
    end

    test "refuses a plan later than the loop's own date", ctx do
      result =
        update(ctx, ctx.loop_id, %{
          "answer" => "plan",
          "owner_words" => "the twentieth",
          "plan_at" => %{"type" => "date", "date" => "2031-06-20"}
        })

      assert refusal!(result) == Registry.describe_error(:plan_after_date)
    end

    test "refuses a plan with no date", ctx do
      result = update(ctx, ctx.loop_id, %{"answer" => "plan", "owner_words" => "soon"})
      assert refusal!(result) == Registry.describe_error(:plan_requires_date)
    end

    test "refuses a plan whose time has passed", ctx do
      result =
        update(ctx, ctx.loop_id, %{
          "answer" => "plan",
          "owner_words" => "first thing this morning",
          "plan_at" => %{"type" => "datetime", "date" => "2031-06-02", "time" => "08:00:00"}
        })

      assert refusal!(result) == Registry.describe_error(:plan_passed)
    end

    test "refuses plan_at with any answer but plan", ctx do
      result =
        update(ctx, ctx.loop_id, %{
          "answer" => "not_yet",
          "owner_words" => "not yet",
          "plan_at" => %{"type" => "date", "date" => "2031-06-05"}
        })

      assert refusal!(result) == Registry.describe_error(:plan_at_without_plan)
    end

    test "refuses a guest and a check-in run, naming the tool", ctx do
      args = %{"open_loop_id" => ctx.loop_id, "answer" => "done", "owner_words" => "done"}

      for context <- [guest(ctx), checkin(ctx, make_ref())] do
        {:ok, result} = OpenLoopUpdate.execute(args, context)
        assert refusal!(result) == Access.refusal("open_loop_update", :not_attended)
      end
    end

    test "refuses while open loops are turned off, naming the tool", ctx do
      Application.put_env(:fermix_core, :open_loops, enabled: false)

      result = update(ctx, ctx.loop_id, %{"answer" => "done", "owner_words" => "done"})
      assert refusal!(result) == Access.refusal("open_loop_update", :disabled)
    end
  end

  describe "open_loop_list" do
    test "lists live loops by their view, with no destination or message text", ctx do
      first = note!(ctx)

      note!(ctx, %{
        "intention" => "Return the Oakhurst library books",
        "matters_by" => %{"type" => "date", "date" => "2031-06-20"}
      })

      {:ok, result} = OpenLoopList.execute(%{}, attended(ctx))
      rows = payload(result)["open_loops"]

      assert length(rows) == 2
      assert Enum.all?(rows, &(Map.keys(&1) |> Enum.sort() == Enum.sort(@view_keys)))
      assert hd(rows)["open_loop_id"] == first["open_loop_id"]
      refute Jason.encode!(rows) =~ "owner-terminal"
    end

    test "closed lists settled loops with their reason", ctx do
      id = note!(ctx)["open_loop_id"]
      update(ctx, id, %{"answer" => "drop", "owner_words" => "forget that one"})

      {:ok, live} = OpenLoopList.execute(%{}, attended(ctx))
      assert payload(live)["open_loops"] == []

      {:ok, closed} = OpenLoopList.execute(%{"state" => "closed"}, attended(ctx))

      assert [%{"open_loop_id" => ^id, "close_reason" => "dropped"}] =
               payload(closed)["open_loops"]
    end

    test "refuses a state outside the enum", ctx do
      {:ok, result} = OpenLoopList.execute(%{"state" => "open"}, attended(ctx))
      assert refusal!(result) == Registry.describe_error({:invalid_param, :state})
    end

    test "a check-in run may read the owner's loops", ctx do
      id = note!(ctx)["open_loop_id"]

      {:ok, result} = OpenLoopList.execute(%{}, checkin(ctx, make_ref()))
      assert [%{"open_loop_id" => ^id}] = payload(result)["open_loops"]
    end

    test "refuses a guest, naming the tool", ctx do
      {:ok, result} = OpenLoopList.execute(%{}, guest(ctx))
      assert refusal!(result) == Access.refusal("open_loop_list", :not_readable)
    end

    test "refuses while open loops are turned off, naming the tool", ctx do
      Application.put_env(:fermix_core, :open_loops, enabled: false)

      {:ok, result} = OpenLoopList.execute(%{}, attended(ctx))
      assert refusal!(result) == Access.refusal("open_loop_list", :disabled)
    end
  end

  describe "open_loop_respond" do
    setup ctx do
      ref = make_ref()
      %{ref: ref, checkin: checkin(ctx, ref)}
    end

    defp respond(context, args) do
      {:ok, result} = OpenLoopRespond.execute(args, context)
      result
    end

    test "speak sends the decision to the run and says the run ends here", ctx do
      text = "On Monday you said you'd file the Marlow Creek renewal; is it in yet?"
      result = respond(ctx.checkin, %{"decision" => "speak", "message" => text})

      assert result.success
      assert result.output =~ "ends here"
      refute result.output =~ "\n"

      ref = ctx.ref
      assert_received {:open_loop_respond, ^ref, %{decision: :speak, message: ^text, reason: nil}}
    end

    test "silent sends a decision with no text", ctx do
      assert respond(ctx.checkin, %{"decision" => "silent"}).success

      ref = ctx.ref
      assert_received {:open_loop_respond, ^ref, %{decision: :silent, message: nil, reason: nil}}
    end

    test "close sends the reason memory holds", ctx do
      reason = "owner said on Tuesday the renewal was filed"
      assert respond(ctx.checkin, %{"decision" => "close", "reason" => reason}).success

      ref = ctx.ref

      assert_received {:open_loop_respond, ^ref,
                       %{decision: :close, message: nil, reason: ^reason}}
    end

    test "a message over the byte bound is refused, not cut, and nothing is sent", ctx do
      text = String.duplicate("a", Defaults.message_max_bytes() + 1)
      result = respond(ctx.checkin, %{"decision" => "speak", "message" => text})

      assert refusal!(result) =~ "at most 1800 bytes"
      refute_received {:open_loop_respond, _ref, _decision}
    end

    test "the bound is bytes, not characters", ctx do
      # "€" is three bytes: 600 of them fill the bound exactly, 601 overrun it
      # while staying far under 1,800 characters.
      at_bound = String.duplicate("€", div(Defaults.message_max_bytes(), 3))
      over = at_bound <> "€"

      assert respond(ctx.checkin, %{"decision" => "speak", "message" => at_bound}).success
      ref = ctx.ref
      assert_received {:open_loop_respond, ^ref, %{message: ^at_bound}}

      refute respond(ctx.checkin, %{"decision" => "speak", "message" => over}).success
      refute_received {:open_loop_respond, _ref, _decision}
    end

    test "speak needs a message and close needs a reason", ctx do
      assert refusal!(respond(ctx.checkin, %{"decision" => "speak"})) =~ "message"

      assert refusal!(respond(ctx.checkin, %{"decision" => "speak", "message" => "  "})) =~
               "message"

      assert refusal!(respond(ctx.checkin, %{"decision" => "close"})) =~ "reason"
      refute_received {:open_loop_respond, _ref, _decision}
    end

    test "a reason over the character bound is refused", ctx do
      reason = String.duplicate("b", Defaults.reason_max() + 1)

      assert refusal!(respond(ctx.checkin, %{"decision" => "close", "reason" => reason})) =~
               "240 characters"

      refute_received {:open_loop_respond, _ref, _decision}
    end

    test "a decision outside the enum is refused", ctx do
      assert refusal!(respond(ctx.checkin, %{"decision" => "shout"})) =~ "speak, silent or close"
      assert refusal!(respond(ctx.checkin, %{})) =~ "speak, silent or close"
      refute_received {:open_loop_respond, _ref, _decision}
    end

    test "a second call is accepted by the tool; the run keeps the first", ctx do
      assert respond(ctx.checkin, %{"decision" => "silent"}).success
      assert respond(ctx.checkin, %{"decision" => "close", "reason" => "filed"}).success

      ref = ctx.ref
      assert_received {:open_loop_respond, ^ref, %{decision: :silent}}
      assert_received {:open_loop_respond, ^ref, %{decision: :close}}
    end

    test "one call is one tool exec event under the tool's own name", ctx do
      TelemetryCapture.attach([[:fermix, :tool, :exec]], session_id: ctx.checkin.session_id)

      respond(ctx.checkin, %{"decision" => "silent"})

      assert_receive {:telemetry, [:fermix, :tool, :exec], _measurements,
                      %{tool: "open_loop_respond", success: true}}
    end

    test "refuses an attended owner turn, naming the tool", ctx do
      result = respond(attended(ctx), %{"decision" => "silent"})

      assert refusal!(result) == Access.refusal("open_loop_respond", :not_checkin)
      refute_received {:open_loop_respond, _ref, _decision}
    end

    test "refuses while open loops are turned off, naming the tool", ctx do
      Application.put_env(:fermix_core, :open_loops, enabled: false)

      result = respond(ctx.checkin, %{"decision" => "silent"})

      assert refusal!(result) == Access.refusal("open_loop_respond", :disabled)
      refute_received {:open_loop_respond, _ref, _decision}
    end
  end
end
