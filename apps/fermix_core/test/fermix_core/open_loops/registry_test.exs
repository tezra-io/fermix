defmodule FermixCore.OpenLoops.RegistryTest do
  use ExUnit.Case, async: true

  alias FermixCore.Memory.Repo
  alias FermixCore.OpenLoops.Defaults
  alias FermixCore.OpenLoops.Registry
  alias FermixTestSupport.TelemetryCapture

  @tz "America/New_York"
  # Monday 2031-06-02, 10:00 EDT; June 2031 is EDT (UTC-4). Every name, date and
  # id in this file is invented.
  @now ~U[2031-06-02 14:00:00Z]
  @intention "Submit the Kestrel Valley fellowship application"
  @date %{"type" => "date", "date" => "2031-06-10"}

  defmodule FakeChannel do
    @moduledoc false
    def send_message(_destination, _payload, _opts), do: :ok
  end

  @attended %{
    source_trust: :operator,
    computer_use_origin: :interactive,
    conversation_key: {"telegram", "40001", :root},
    memory_owner_id: "default",
    memory_agent_id: "main",
    session_id: "sess_open_loops_registry"
  }

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-open-loops-registry-#{unique}.db")
    repo = :"open_loops_registry_repo_#{unique}"

    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    opts = [
      repo: repo,
      now: @now,
      personalization: [timezone: @tz],
      jobs_config: [delivery_channels: %{"telegram" => FakeChannel}],
      configured_owners: %{"telegram" => "40001"},
      scheduler: nil
    ]

    %{repo: repo, opts: opts}
  end

  defp note!(opts, params \\ %{}) do
    params = Map.merge(%{"intention" => @intention, "matters_by" => @date}, params)
    {:ok, result} = Registry.note(params, @attended, opts)
    result
  end

  defp at(opts, now), do: Keyword.put(opts, :now, now)

  defp utc(%DateTime{microsecond: {value, _precision}} = at), do: %{at | microsecond: {value, 6}}

  describe "note/3" do
    test "records a dated intention with its first check and its delivery", %{opts: opts} do
      params = %{
        "intention" => "  #{@intention}  ",
        "why_it_matters" => "the panel only reads applications that arrive on time",
        "matters_by" => @date
      }

      assert {:ok, result} = Registry.note(params, @attended, opts)

      assert %{status: :created, live_loops: 1} = result
      assert result.stated_as == "Tuesday, June 10, 2031"
      assert result.first_check == "Saturday, June 7, 2031 at 9:00 AM EDT"
      assert result.delivery == %{platform: "telegram", source: :derived}

      loop = result.loop
      assert "loop_" <> suffix = loop.id
      assert byte_size(suffix) == 11
      assert loop.intention == @intention
      assert loop.dedupe_key == "submit the kestrel valley fellowship application"
      assert loop.matters_by_kind == "date"
      assert loop.matters_by_date == ~D[2031-06-10]
      assert loop.matters_by_at == utc(~U[2031-06-11 04:00:00Z])
      assert loop.horizon_class == "medium"
      assert loop.next_touch_at == utc(~U[2031-06-07 13:00:00Z])
      assert loop.said_at == utc(@now)

      assert {loop.source_channel, loop.source_chat_id, loop.source_thread_scope} ==
               {"telegram", "40001", "root"}

      assert {loop.delivery_platform, loop.delivery_destination} == {"telegram", "40001"}
      assert loop.state == "open"
    end

    test "atom-keyed params are read the same way", %{opts: opts} do
      assert {:ok, %{status: :created}} =
               Registry.note(%{intention: @intention, matters_by: @date}, @attended, opts)
    end

    test "the same intention, however it is cased or punctuated, returns the stored loop",
         %{opts: opts, repo: repo} do
      first = note!(Keyword.put(opts, :scheduler, self()))
      assert_received {:"$gen_cast", :loop_changed}

      restated = %{
        "intention" => "  SUBMIT the Kestrel Valley fellowship application!! ",
        "matters_by" => %{"type" => "date", "date" => "2031-06-20"}
      }

      assert {:ok, again} =
               Registry.note(restated, @attended, Keyword.put(opts, :scheduler, self()))

      assert again.status == :existing
      assert again.loop == first.loop
      assert again.live_loops == 1
      assert again.stated_as == "Tuesday, June 10, 2031"
      refute_received {:"$gen_cast", :loop_changed}

      assert {:ok, 1} = Repo.count_live_open_loops("default", server: repo)
    end

    test "datetime, offset and relative forms resolve like events do", %{opts: opts} do
      timed =
        note!(opts, %{
          "matters_by" => %{"type" => "datetime", "date" => "2031-06-20", "time" => "15:30:00"}
        })

      assert timed.loop.matters_by_kind == "datetime"
      assert timed.loop.matters_by_time == ~T[15:30:00]
      assert timed.loop.matters_by_at == utc(~U[2031-06-20 19:30:00Z])
      assert timed.loop.horizon_class == "long"
      assert timed.stated_as == "Friday, June 20, 2031 at 3:30 PM EDT"

      offset =
        note!(opts, %{
          "intention" => "Book the Ardent Hall venue",
          "matters_by" => %{
            "type" => "datetime",
            "date" => "2031-06-20",
            "time" => "15:30:00",
            "utc_offset" => "-04:00"
          }
        })

      assert offset.loop.matters_by_at == utc(~U[2031-06-20 19:30:00Z])

      days =
        note!(opts, %{
          "intention" => "Return the Larkspur survey forms",
          "matters_by" => %{"type" => "relative", "amount" => 5, "unit" => "days"}
        })

      assert days.loop.matters_by_date == ~D[2031-06-07]
      assert days.loop.matters_by_kind == "date"

      weeks =
        note!(opts, %{
          "intention" => "Finish the Ostrander case study",
          "matters_by" => %{
            "type" => "relative",
            "amount" => 3,
            "unit" => "weeks",
            "time" => "17:00:00"
          }
        })

      assert weeks.loop.matters_by_date == ~D[2031-06-23]
      assert weeks.loop.matters_by_kind == "datetime"
      assert weeks.loop.matters_by_at == utc(~U[2031-06-23 21:00:00Z])
    end

    test "a date-only loop has passed at the start of the next local day", %{opts: opts} do
      today = note!(opts, %{"matters_by" => %{"type" => "date", "date" => "2031-06-02"}})

      assert today.loop.matters_by_at == utc(~U[2031-06-03 04:00:00Z])
      assert today.loop.horizon_class == "imminent"
      assert today.loop.next_touch_at == utc(@now)
    end

    test "a zone the owner named wins over the configured one", %{opts: opts} do
      result = note!(opts, %{"timezone" => "Europe/Lisbon"})

      assert result.loop.timezone == "Europe/Lisbon"
      assert result.loop.matters_by_at == utc(~U[2031-06-10 23:00:00Z])
    end

    test "refuses forms a loop cannot be", %{opts: opts} do
      for form <- [
            %{"type" => "relative", "amount" => 30, "unit" => "minutes"},
            %{"type" => "relative", "amount" => 3, "unit" => "hours"},
            %{"type" => "annual", "month" => 9, "day" => 14}
          ] do
        assert {:error, :not_dated} =
                 Registry.note(
                   %{"intention" => @intention, "matters_by" => form},
                   @attended,
                   opts
                 )
      end

      for form <- [%{"type" => "date", "date" => "June 10"}, %{"type" => "fortnight"}, "soon"] do
        assert {:error, {:invalid_when, ^form}} =
                 Registry.note(
                   %{"intention" => @intention, "matters_by" => form},
                   @attended,
                   opts
                 )
      end
    end

    test "refuses missing and oversized parameters", %{opts: opts} do
      assert {:error, {:missing_parameters, [:intention]}} =
               Registry.note(%{"matters_by" => @date}, @attended, opts)

      assert {:error, {:missing_parameters, [:intention]}} =
               Registry.note(%{"intention" => " ?! ", "matters_by" => @date}, @attended, opts)

      assert {:error, {:missing_parameters, [:matters_by]}} =
               Registry.note(%{"intention" => @intention}, @attended, opts)

      assert {:error, {:too_long, :intention, 500}} =
               Registry.note(
                 %{"intention" => String.duplicate("a", 501), "matters_by" => @date},
                 @attended,
                 opts
               )

      assert {:error, {:too_long, :why_it_matters, 300}} =
               Registry.note(
                 %{
                   "intention" => @intention,
                   "why_it_matters" => String.duplicate("b", 301),
                   "matters_by" => @date
                 },
                 @attended,
                 opts
               )
    end

    test "refuses a date that has passed", %{opts: opts} do
      assert {:error, :date_passed} =
               Registry.note(
                 %{
                   "intention" => @intention,
                   "matters_by" => %{"type" => "date", "date" => "2031-06-01"}
                 },
                 @attended,
                 opts
               )
    end

    test "refuses without a timezone, or with one the tz database does not know", %{opts: opts} do
      assert {:error, :timezone_not_configured} =
               Registry.note(
                 %{"intention" => @intention, "matters_by" => @date},
                 @attended,
                 Keyword.put(opts, :personalization, [])
               )

      assert {:error, {:invalid_timezone, "Mars/Olympus"}} =
               Registry.note(
                 %{
                   "intention" => @intention,
                   "matters_by" => @date,
                   "timezone" => "Mars/Olympus"
                 },
                 @attended,
                 opts
               )
    end

    test "refuses without a chat-capable owner inbox", %{opts: opts} do
      params = %{"intention" => @intention, "matters_by" => @date}

      assert {:error, :no_target} =
               Registry.note(params, @attended, Keyword.put(opts, :configured_owners, %{}))

      notification_only =
        opts
        |> Keyword.put(:configured_owners, %{"computer" => "local"})
        |> Keyword.put(:jobs_config,
          delivery_channels: %{"telegram" => FakeChannel},
          default_delivery_target: %{"platform" => "computer", "chat_id" => "local"}
        )

      assert {:error, :no_target} = Registry.note(params, @attended, notification_only)

      assert {:error, {:unsupported_delivery_platform, "telegram"}} =
               Registry.note(
                 params,
                 @attended,
                 Keyword.put(opts, :jobs_config, delivery_channels: %{})
               )
    end

    test "refuses the 21st live loop", %{opts: opts} do
      for n <- 1..Defaults.max_live_loops() do
        note!(opts, %{"intention" => "Invented errand number #{n}"})
      end

      assert {:error, :too_many_loops} =
               Registry.note(
                 %{"intention" => "One errand too many", "matters_by" => @date},
                 @attended,
                 opts
               )
    end

    test "only an attended owner turn outside a check-in may record", %{opts: opts} do
      params = %{"intention" => @intention, "matters_by" => @date}

      assert {:error, :not_attended} =
               Registry.note(params, %{@attended | source_trust: :guest}, opts)

      assert {:error, :not_attended} =
               Registry.note(params, Map.delete(@attended, :computer_use_origin), opts)

      assert {:error, :not_attended} =
               Registry.note(params, Map.put(@attended, :subagent_depth, 1), opts)

      checkin = Map.put(@attended, :open_loop_checkin, %{id: "loop_AbCdEfGhIjK"})
      assert {:error, :not_attended} = Registry.note(params, checkin, opts)

      assert {:error, :no_conversation} =
               Registry.note(params, Map.delete(@attended, :conversation_key), opts)
    end
  end

  describe "update/4" do
    setup %{opts: opts} do
      %{loop: note!(opts).loop}
    end

    defp update(loop, params, opts, context \\ @attended),
      do: Registry.update(loop.id, params, context, opts)

    test "done closes the loop for good and traces the settlement", %{loop: loop, opts: opts} do
      TelemetryCapture.attach([[:fermix, :open_loop, :settled]], open_loop_id: loop.id)

      assert {:ok, result} =
               update(
                 loop,
                 %{"answer" => "done", "owner_words" => "sent it off this morning"},
                 opts
               )

      assert result.previous_state == "open"
      assert result.next_check == nil
      assert %{state: "closed", close_reason: "done", last_answer: "done"} = result.loop

      assert_receive {:telemetry, [:fermix, :open_loop, :settled], %{count: 1}, meta}
      assert meta.from == "open"
      assert meta.to == "closed"
      assert meta.answer == "done"
      assert meta.by == "main_agent"
      assert meta.session_id == "sess_open_loops_registry"
    end

    test "stop and drop close with their own reasons", %{loop: loop, opts: opts} do
      assert {:ok, %{loop: %{close_reason: "stop"}}} =
               update(loop, %{"answer" => "stop", "owner_words" => "please stop asking"}, opts)

      other = note!(opts, %{"intention" => "Renew the Pellworth lease"}).loop

      assert {:ok, %{loop: %{close_reason: "dropped"}}} =
               update(other, %{"answer" => "drop", "owner_words" => "forget the lease"}, opts)
    end

    test "a plan re-arms at the plan's time and says when", %{loop: loop, opts: opts} do
      params = %{
        "answer" => "plan",
        "owner_words" => "Sunday evening",
        "plan_at" => %{"type" => "datetime", "date" => "2031-06-08", "time" => "18:00:00"}
      }

      assert {:ok, result} = update(loop, params, opts)
      assert result.loop.state == "open"
      assert result.loop.plan_at == utc(~U[2031-06-08 22:00:00Z])
      assert result.loop.next_touch_at == utc(~U[2031-06-08 22:00:00Z])
      assert result.next_check == "Sunday, June 8, 2031 at 6:00 PM EDT"
    end

    test "a date-only plan arms that day's active-hours start", %{loop: loop, opts: opts} do
      params = %{
        "answer" => "plan",
        "owner_words" => "on Sunday",
        "plan_at" => %{"type" => "date", "date" => "2031-06-08"}
      }

      assert {:ok, %{loop: %{next_touch_at: next}}} = update(loop, params, opts)
      assert next == utc(~U[2031-06-08 13:00:00Z])
    end

    test "not yet arms one more check nearer the date", %{loop: loop, opts: opts} do
      later = at(opts, ~U[2031-06-07 17:00:00Z])

      assert {:ok, result} =
               update(loop, %{"answer" => "not_yet", "owner_words" => "not yet"}, later)

      assert result.loop.next_touch_at == utc(~U[2031-06-09 13:00:00Z])
      assert result.next_check == "Monday, June 9, 2031 at 9:00 AM EDT"
    end

    test "asked records the raise as a touch, once", %{loop: loop, opts: opts} do
      later = at(opts, ~U[2031-06-07 14:00:00Z])

      assert {:ok, %{loop: asked, previous_state: "open"}} =
               update(loop, %{"answer" => "asked"}, later)

      assert %{state: "asked", touches: 1, last_touch_rung: 1} = asked

      assert {:error, :already_asked} = update(loop, %{"answer" => "asked"}, later)
    end

    test "the owner's words are required, bounded, and never stored", %{loop: loop, opts: opts} do
      assert {:error, :missing_owner_words} = update(loop, %{"answer" => "done"}, opts)

      assert {:error, :owner_words_too_long} =
               update(
                 loop,
                 %{"answer" => "done", "owner_words" => String.duplicate("w", 241)},
                 opts
               )

      words = "handed in the Kestrel Valley forms at noon"

      assert {:ok, %{loop: closed}} =
               update(loop, %{"answer" => "done", "owner_words" => words}, opts)

      refute Enum.any?(Map.values(closed), &(is_binary(&1) and String.contains?(&1, words)))
    end

    test "a plan needs a date no later than the loop's own", %{loop: loop, opts: opts} do
      assert {:error, :plan_requires_date} =
               update(loop, %{"answer" => "plan", "owner_words" => "soon"}, opts)

      late = %{"type" => "date", "date" => "2031-06-12"}

      assert {:error, :plan_after_date} =
               update(
                 loop,
                 %{"answer" => "plan", "owner_words" => "the 12th", "plan_at" => late},
                 opts
               )

      assert {:error, :plan_at_without_plan} =
               update(
                 loop,
                 %{"answer" => "done", "owner_words" => "done", "plan_at" => late},
                 opts
               )
    end

    test "refuses unknown, foreign and settled loops", %{loop: loop, opts: opts, repo: repo} do
      assert {:error, :not_found} =
               Registry.update(
                 "loop_ZZZZZZZZZZZ",
                 %{"answer" => "done", "owner_words" => "done"},
                 @attended,
                 opts
               )

      foreign = %{@attended | memory_owner_id: "another_owner"}

      assert {:error, :not_found} =
               update(loop, %{"answer" => "done", "owner_words" => "done"}, opts, foreign)

      {:ok, _} = update(loop, %{"answer" => "done", "owner_words" => "done"}, opts)

      assert {:error, :not_live} =
               update(loop, %{"answer" => "not_yet", "owner_words" => "not yet"}, opts)

      assert {:ok, %{state: "closed"}} = Repo.get_open_loop(loop.id, server: repo)
    end

    test "refuses an answer outside the vocabulary", %{loop: loop, opts: opts} do
      assert {:error, {:invalid_answer, "maybe"}} =
               update(loop, %{"answer" => "maybe", "owner_words" => "maybe"}, opts)
    end

    test "only an attended owner turn outside a check-in may settle", %{loop: loop, opts: opts} do
      params = %{"answer" => "done", "owner_words" => "done"}

      assert {:error, :not_attended} =
               update(loop, params, opts, %{@attended | source_trust: :guest})

      checkin = Map.put(@attended, :open_loop_checkin, %{id: loop.id})
      assert {:error, :not_attended} = update(loop, params, opts, checkin)
    end

    test "a settlement notifies the scheduler", %{loop: loop, opts: opts} do
      params = %{"answer" => "done", "owner_words" => "done"}
      assert {:ok, _} = update(loop, params, Keyword.put(opts, :scheduler, self()))
      assert_received {:"$gen_cast", :loop_changed}
    end
  end

  describe "list/3 and view/1" do
    setup %{opts: opts} do
      live = note!(opts).loop
      other = note!(opts, %{"intention" => "Renew the Pellworth lease"}).loop

      {:ok, _} =
        Registry.update(
          other.id,
          %{"answer" => "done", "owner_words" => "renewed"},
          @attended,
          opts
        )

      %{live: live, closed_id: other.id}
    end

    test "live is the default; closed and any add the settled ones", ctx do
      assert {:ok, [%{id: id}]} = Registry.list(%{}, @attended, ctx.opts)
      assert id == ctx.live.id

      assert {:ok, [%{id: closed_id}]} =
               Registry.list(%{"state" => "closed"}, @attended, ctx.opts)

      assert closed_id == ctx.closed_id

      assert {:ok, rows} = Registry.list(%{state: "any"}, @attended, ctx.opts)
      assert length(rows) == 2

      assert {:error, {:invalid_param, :state}} =
               Registry.list(%{"state" => "due"}, @attended, ctx.opts)
    end

    test "a check-in run may read; a guest may not", ctx do
      checkin = %{open_loop_checkin: %{id: ctx.live.id}, memory_owner_id: "default"}
      assert {:ok, [_]} = Registry.list(%{}, checkin, ctx.opts)

      assert {:error, :not_attended} =
               Registry.list(%{}, %{@attended | source_trust: :guest}, ctx.opts)
    end

    test "the model's view carries no destination and no message text", ctx do
      view = Registry.view(ctx.live)

      assert view == %{
               "open_loop_id" => ctx.live.id,
               "intention" => @intention,
               "why_it_matters" => nil,
               "matters_by" => "Tuesday, June 10, 2031",
               "said_on" => "Monday, June 2, 2031",
               "source_channel" => "telegram",
               "state" => "open",
               "touches" => 0,
               "next_check" => "Saturday, June 7, 2031 at 9:00 AM EDT",
               "last_answer" => nil
             }

      {:ok, [closed]} = Registry.list(%{"state" => "closed"}, @attended, ctx.opts)

      assert %{
               "close_reason" => "done",
               "closed_on" => "Monday, June 2, 2031",
               "next_check" => nil
             } =
               Registry.view(closed)

      for view <- [view, Registry.view(closed)] do
        refute Enum.any?(Map.values(view), &(&1 == "40001"))
      end
    end
  end

  describe "describe_error/1" do
    test "every reason is one sentence telling the model what to do" do
      reasons = [
        :not_attended,
        :disabled,
        :no_conversation,
        {:missing_parameters, [:intention]},
        {:too_long, :intention, 500},
        {:invalid_param, :timezone},
        {:invalid_param, :state},
        {:invalid_when, %{"type" => "fortnight"}},
        :not_dated,
        :date_passed,
        :timezone_not_configured,
        {:invalid_timezone, "Mars/Olympus"},
        {:dst_gap, @tz, ~D[2031-03-09], ~T[02:30:00]},
        {:dst_ambiguous, ["-04:00", "-05:00"]},
        :no_target,
        {:unsupported_delivery_platform, "telegram"},
        {:invalid_delivery_adapter, FakeChannel},
        :too_many_loops,
        :imminent_without_window,
        :not_found,
        :not_live,
        :already_asked,
        :missing_owner_words,
        :owner_words_too_long,
        :plan_after_date,
        :plan_requires_date,
        :plan_passed,
        :plan_at_without_plan,
        {:invalid_answer, "maybe"},
        {:invalid, :intention, :too_long},
        :repo_timeout
      ]

      for reason <- reasons do
        sentence = Registry.describe_error(reason)
        assert is_binary(sentence) and sentence != "", inspect(reason)
        assert String.ends_with?(sentence, "."), inspect(reason)
        refute String.contains?(sentence, "\n"), inspect(reason)
      end

      assert Registry.describe_error(:too_many_loops) =~ "20"
    end
  end
end
