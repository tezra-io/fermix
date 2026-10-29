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
    chat_type: "private",
    outside_sources: MapSet.new(),
    memory_owner_id: "default",
    memory_agent_id: "main",
    session_id: "sess_open_loops_registry"
  }

  @read_a_page MapSet.new([{:tool, "web_fetch"}])

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
    params =
      Map.merge(%{"intention" => @intention, "matters_by" => @date, "reach" => "message"}, params)

    {:ok, result} = Registry.note(params, @attended, opts)
    result
  end

  defp at(opts, now), do: Keyword.put(opts, :now, now)

  # The due scan at `at`, as the scheduler runs it: a loop whose touch has
  # arrived becomes due, the only state a raise may be recorded on.
  defp due!(opts, %DateTime{} = at) do
    {:ok, _scan} = Repo.scan_due_open_loops(at, 50, server: Keyword.fetch!(opts, :repo))
    :ok
  end

  defp utc(%DateTime{microsecond: {value, _precision}} = at), do: %{at | microsecond: {value, 6}}

  describe "note/3" do
    test "records a dated intention with its first check and its delivery", %{opts: opts} do
      params = %{
        "intention" => "  #{@intention}  ",
        "why_it_matters" => "the panel only reads applications that arrive on time",
        "matters_by" => @date,
        "reach" => "message"
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
               Registry.note(
                 %{intention: @intention, matters_by: @date, reach: "conversation"},
                 @attended,
                 opts
               )
    end

    test "the same intention, however it is cased or punctuated, returns the stored loop",
         %{opts: opts, repo: repo} do
      first = note!(Keyword.put(opts, :scheduler, self()))
      assert_received {:"$gen_cast", :loop_changed}

      restated = %{
        "intention" => "  SUBMIT the Kestrel Valley fellowship application!! ",
        "matters_by" => %{"type" => "date", "date" => "2031-06-20"},
        "reach" => "message"
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
      assert today.loop.next_touch_at == utc(~U[2031-06-02 17:00:00Z])
    end

    test "a loop said within three hours of its date is not recorded", %{opts: opts} do
      soon = %{"type" => "datetime", "date" => "2031-06-02", "time" => "12:00:00"}

      assert {:error, :imminent_without_window} =
               Registry.note(
                 %{"intention" => @intention, "matters_by" => soon, "reach" => "message"},
                 @attended,
                 opts
               )
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
                   %{"intention" => @intention, "matters_by" => form, "reach" => "message"},
                   @attended,
                   opts
                 )
      end

      for form <- [%{"type" => "date", "date" => "June 10"}, %{"type" => "fortnight"}, "soon"] do
        assert {:error, {:invalid_when, ^form}} =
                 Registry.note(
                   %{"intention" => @intention, "matters_by" => form, "reach" => "message"},
                   @attended,
                   opts
                 )
      end
    end

    test "refuses missing and oversized parameters", %{opts: opts} do
      assert {:error, {:missing_parameters, [:intention]}} =
               Registry.note(%{"matters_by" => @date, "reach" => "message"}, @attended, opts)

      assert {:error, {:missing_parameters, [:intention]}} =
               Registry.note(
                 %{"intention" => " ?! ", "matters_by" => @date, "reach" => "message"},
                 @attended,
                 opts
               )

      assert {:error, :missing_when} =
               Registry.note(%{"intention" => @intention, "reach" => "message"}, @attended, opts)

      assert {:error, {:missing_parameters, [:reach]}} =
               Registry.note(%{"intention" => @intention, "matters_by" => @date}, @attended, opts)

      assert {:error, {:too_long, :intention, 500}} =
               Registry.note(
                 %{
                   "intention" => String.duplicate("a", 501),
                   "matters_by" => @date,
                   "reach" => "message"
                 },
                 @attended,
                 opts
               )

      assert {:error, {:too_long, :why_it_matters, 300}} =
               Registry.note(
                 %{
                   "intention" => @intention,
                   "why_it_matters" => String.duplicate("b", 301),
                   "matters_by" => @date,
                   "reach" => "message"
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
                   "matters_by" => %{"type" => "date", "date" => "2031-06-01"},
                   "reach" => "message"
                 },
                 @attended,
                 opts
               )
    end

    test "refuses without a timezone, or with one the tz database does not know", %{opts: opts} do
      assert {:error, :timezone_not_configured} =
               Registry.note(
                 %{"intention" => @intention, "matters_by" => @date, "reach" => "message"},
                 @attended,
                 Keyword.put(opts, :personalization, [])
               )

      assert {:error, {:invalid_timezone, "Mars/Olympus"}} =
               Registry.note(
                 %{
                   "intention" => @intention,
                   "matters_by" => @date,
                   "reach" => "message",
                   "timezone" => "Mars/Olympus"
                 },
                 @attended,
                 opts
               )
    end

    test "refuses without a chat-capable owner inbox", %{opts: opts} do
      params = %{"intention" => @intention, "matters_by" => @date, "reach" => "message"}

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
                 %{
                   "intention" => "One errand too many",
                   "matters_by" => @date,
                   "reach" => "message"
                 },
                 @attended,
                 opts
               )
    end

    test "only an attended owner turn outside a check-in may record", %{opts: opts} do
      params = %{"intention" => @intention, "matters_by" => @date, "reach" => "message"}

      assert {:error, :not_attended} =
               Registry.note(params, %{@attended | source_trust: :guest}, opts)

      assert {:error, :not_attended} =
               Registry.note(params, Map.delete(@attended, :computer_use_origin), opts)

      assert {:error, :not_attended} =
               Registry.note(params, Map.put(@attended, :subagent_depth, 1), opts)

      checkin = Map.put(@attended, :open_loop_checkin, %{id: "loop_AbCdEfGhIjK"})
      assert {:error, :not_attended} = Registry.note(params, checkin, opts)

      group = Map.put(@attended, :chat_type, "group")
      assert {:error, :not_attended} = Registry.note(params, group, opts)
      assert {:ok, _} = Registry.note(params, Map.put(@attended, :chat_type, "private"), opts)

      assert {:error, :no_conversation} =
               Registry.note(params, Map.delete(@attended, :conversation_key), opts)
    end

    # MILESTONE_78 §08: a group chat never produces a loop, and a chat with no
    # label is shared, as a Slack channel mention is.
    test "a group chat or an unlabelled chat may not record", %{opts: opts} do
      params = %{"intention" => @intention, "matters_by" => @date, "reach" => "message"}

      for context <- [%{@attended | chat_type: "group"}, Map.delete(@attended, :chat_type)] do
        assert {:error, :not_attended} = Registry.note(params, context, opts)
      end
    end

    # What the turn that noted a loop had read is stamped on the row, so the
    # loop's words are framed when they come back. A context the loop never
    # stamped is read as having read outside content, as the access gate reads it.
    test "a capture after outside content is stamped; a clean one is not", %{opts: opts} do
      refute note!(opts).loop.noted_after_outside_content

      read_a_page = %{@attended | outside_sources: @read_a_page}

      params = %{
        "intention" => "Renew the Pellworth lease",
        "matters_by" => @date,
        "reach" => "message"
      }

      assert {:ok, %{loop: stamped}} = Registry.note(params, read_a_page, opts)
      assert stamped.noted_after_outside_content

      unstamped = Map.delete(@attended, :outside_sources)

      params = %{
        "intention" => "Book the Ardent Hall for the launch",
        "matters_by" => @date,
        "reach" => "message"
      }

      assert {:ok, %{loop: unknown}} = Registry.note(params, unstamped, opts)
      assert unknown.noted_after_outside_content
    end
  end

  describe "note/3: something waited on or gone through" do
    @interview "Final-round interview with Brightwell"
    @tuesday_evening %{"type" => "datetime", "date" => "2031-06-03", "time" => "17:00:00"}

    defp waited!(opts, params \\ %{}) do
      params =
        Map.merge(
          %{"intention" => @interview, "ask_after" => @tuesday_evening, "reach" => "message"},
          params
        )

      {:ok, result} = Registry.note(params, @attended, opts)
      result
    end

    test "records it with its ask_after as the anchor, its reach and no source", %{opts: opts} do
      result = waited!(opts, %{"reach" => "conversation"})
      loop = result.loop

      assert %{status: :created} = result
      assert result.stated_as == "Tuesday, June 3, 2031 at 5:00 PM EDT"
      assert result.first_check == "Tuesday, June 3, 2031 at 5:00 PM EDT"

      assert %{
               anchor_kind: "ask_after",
               horizon_class: "after",
               matters_by_source: nil,
               reach: "conversation",
               matters_by_kind: "datetime",
               matters_by_date: ~D[2031-06-03],
               matters_by_time: ~T[17:00:00]
             } = loop

      assert loop.matters_by_at == utc(~U[2031-06-03 21:00:00Z])
      assert loop.next_touch_at == utc(~U[2031-06-03 21:00:00Z])
    end

    test "a date alone means after that day ends: the next day's active-hours start",
         %{opts: opts} do
      loop = waited!(opts, %{"ask_after" => %{"type" => "date", "date" => "2031-06-04"}}).loop

      assert {loop.matters_by_kind, loop.matters_by_date} == {"date", ~D[2031-06-04]}
      assert loop.matters_by_at == utc(~U[2031-06-05 13:00:00Z])

      relative =
        waited!(opts, %{
          "intention" => "Hear back about the Juniper Row flat",
          "ask_after" => %{"type" => "relative", "amount" => 2, "unit" => "days"}
        }).loop

      assert relative.matters_by_at == utc(~U[2031-06-05 13:00:00Z])
    end

    # A year is a sanity bound, not taste: a same-evening outcome works, and so
    # do a birth due in about six weeks and a wedding next spring.
    test "ask_after lies from three hours to a year out", %{opts: opts} do
      tonight = %{"type" => "datetime", "date" => "2031-06-02", "time" => "13:00:00"}

      assert waited!(opts, %{"ask_after" => tonight}).loop.next_touch_at ==
               utc(~U[2031-06-02 17:00:00Z])

      six_weeks = %{"type" => "relative", "amount" => 6, "unit" => "weeks"}

      due = waited!(opts, %{"intention" => "The baby is due", "ask_after" => six_weeks}).loop
      assert due.next_touch_at == utc(~U[2031-07-15 13:00:00Z])

      for {form, reason} <- [
            {%{"type" => "datetime", "date" => "2031-06-02", "time" => "12:59:59"},
             :ask_after_too_soon},
            {%{"type" => "date", "date" => "2031-06-01"}, :ask_after_too_soon},
            {%{"type" => "date", "date" => "2032-06-01"}, :ask_after_too_far}
          ] do
        params = %{
          "intention" => "Hear from the Ellery clinic",
          "ask_after" => form,
          "reach" => "message"
        }

        assert {:error, ^reason} = Registry.note(params, @attended, opts)
      end

      last =
        waited!(opts, %{
          "intention" => "Hear from the Ellery clinic",
          "ask_after" => %{"type" => "date", "date" => "2032-05-31"}
        })

      assert last.loop.matters_by_at == utc(~U[2032-06-01 13:00:00Z])
    end

    test "exactly one time, and a reach the vocabulary knows", %{opts: opts} do
      both = %{
        "intention" => @interview,
        "ask_after" => @tuesday_evening,
        "matters_by" => @date,
        "reach" => "message"
      }

      assert {:error, :both_whens} = Registry.note(both, @attended, opts)

      bad_reach = %{
        "intention" => @interview,
        "ask_after" => @tuesday_evening,
        "reach" => "email"
      }

      assert {:error, {:invalid_param, :reach}} = Registry.note(bad_reach, @attended, opts)
    end

    test "a dated loop records who gave its date; a loop waited on has none", %{opts: opts} do
      assert note!(opts).loop.matters_by_source == "owner"

      looked_up =
        note!(opts, %{
          "intention" => "Pay the Corvina parking fine",
          "matters_by_source" => "lookup"
        })

      assert looked_up.loop.matters_by_source == "lookup"

      assert {:error, :source_without_matters_by} =
               Registry.note(
                 %{
                   "intention" => @interview,
                   "ask_after" => @tuesday_evening,
                   "reach" => "message",
                   "matters_by_source" => "owner"
                 },
                 @attended,
                 opts
               )

      assert {:error, {:invalid_param, :matters_by_source}} =
               Registry.note(
                 %{
                   "intention" => "Renew the Tamsin permit",
                   "matters_by" => @date,
                   "reach" => "message",
                   "matters_by_source" => "guess"
                 },
                 @attended,
                 opts
               )
    end

    test "the same words in the other timing are a kind conflict, naming the live loop",
         %{opts: opts, repo: repo} do
      dated = note!(opts, %{"intention" => @interview})

      assert {:error, {:kind_conflict, id}} =
               Registry.note(
                 %{
                   "intention" => @interview,
                   "ask_after" => @tuesday_evening,
                   "reach" => "message"
                 },
                 @attended,
                 opts
               )

      assert id == dated.loop.id
      assert {:ok, 1} = Repo.count_live_open_loops("default", server: repo)

      waited = waited!(opts, %{"intention" => "Hear about the Fernhill lease"})
      again = waited!(opts, %{"intention" => "hear about the fernhill lease!"})
      assert again.status == :existing and again.loop == waited.loop
    end

    test "the model's view states the ask_after, the reach and the class", %{opts: opts} do
      view = Registry.view(waited!(opts).loop, opts)

      assert view["ask_after"] == "Tuesday, June 3, 2031 at 5:00 PM EDT"
      assert view["reach"] == "message"
      assert view["horizon_class"] == "after"
      refute Map.has_key?(view, "matters_by")
      refute Map.has_key?(view, "matters_by_source")
    end
  end

  describe "update/4: moved, reach, and answers about something waited on" do
    test "moved gives a dated loop a new date, re-derives its class and keeps its touches",
         %{opts: opts} do
      loop = note!(opts).loop
      :ok = due!(opts, ~U[2031-06-07 14:00:00Z])

      {:ok, %{loop: asked}} =
        Registry.update(
          loop.id,
          %{"answer" => "asked"},
          @attended,
          at(opts, ~U[2031-06-07 14:00:00Z])
        )

      TelemetryCapture.attach([[:fermix, :open_loop, :settled]], open_loop_id: loop.id)

      params = %{
        "answer" => "moved",
        "owner_words" => "they pushed it to the 24th at noon",
        "matters_by" => %{"type" => "datetime", "date" => "2031-06-24", "time" => "12:00:00"},
        "matters_by_source" => "lookup"
      }

      later = at(opts, ~U[2031-06-08 14:00:00Z])
      assert {:ok, result} = Registry.update(asked.id, params, @attended, later)

      assert %{
               horizon_class: "long",
               touches: 1,
               state: "open",
               last_answer: "moved",
               matters_by_source: "lookup"
             } =
               result.loop

      assert result.loop.matters_by_at == utc(~U[2031-06-24 16:00:00Z])
      assert result.next_check == "Monday, June 23, 2031 at 9:00 AM EDT"

      assert Registry.view(result.loop, later)["matters_by"] ==
               "Tuesday, June 24, 2031 at 12:00 PM EDT"

      assert_receive {:telemetry, [:fermix, :open_loop, :settled], _,
                      %{answer: "moved", from: "asked", to: "open"}}
    end

    test "moved needs a date ahead with room for a touch, and only a dated loop has one",
         %{opts: opts} do
      loop = note!(opts).loop
      waited = waited!(opts).loop
      soon = %{"type" => "datetime", "date" => "2031-06-02", "time" => "12:00:00"}

      for {id, params, reason} <- [
            {loop.id, %{"answer" => "moved", "owner_words" => "moved"}, :moved_requires_date},
            {loop.id, %{"answer" => "moved", "owner_words" => "noon", "matters_by" => soon},
             :imminent_without_window},
            {loop.id, %{"answer" => "done", "owner_words" => "done", "matters_by" => @date},
             :matters_by_without_moved},
            {loop.id,
             %{"answer" => "moved", "owner_words" => "x", "matters_by_source" => "lookup"},
             :source_without_matters_by},
            {waited.id, %{"answer" => "moved", "owner_words" => "moved", "matters_by" => @date},
             :moved_on_after_loop}
          ] do
        assert {:error, ^reason} = Registry.update(id, params, @attended, opts)
      end

      assert {:error, :missing_owner_words} =
               Registry.update(
                 loop.id,
                 %{"answer" => "moved", "matters_by" => @date},
                 @attended,
                 opts
               )
    end

    test "reach changes how a loop may be raised, from the owner's words", %{opts: opts} do
      loop = note!(opts).loop
      TelemetryCapture.attach([[:fermix, :open_loop, :settled]], open_loop_id: loop.id)

      params = %{
        "answer" => "reach",
        "owner_words" => "just mention it when I'm around",
        "reach" => "conversation"
      }

      assert {:ok, %{loop: %{reach: "conversation", state: "open"} = settled}} =
               Registry.update(loop.id, params, @attended, opts)

      assert settled.next_touch_at == loop.next_touch_at
      assert settled.last_answer == nil
      assert_receive {:telemetry, [:fermix, :open_loop, :settled], _, %{answer: "reach"}}

      assert {:error, {:missing_parameters, [:reach]}} =
               Registry.update(
                 loop.id,
                 %{"answer" => "reach", "owner_words" => "x"},
                 @attended,
                 opts
               )

      assert {:error, {:invalid_param, :reach}} =
               Registry.update(loop.id, %{params | "reach" => "email"}, @attended, opts)

      assert {:error, :reach_without_reach_answer} =
               Registry.update(
                 loop.id,
                 %{"answer" => "done", "owner_words" => "x", "reach" => "message"},
                 @attended,
                 opts
               )
    end

    test "not yet on something waited on needs ask_after, resolved as capture resolves it",
         %{opts: opts} do
      loop = waited!(opts).loop
      later = at(opts, ~U[2031-06-03 22:00:00Z])
      :ok = due!(opts, ~U[2031-06-03 22:00:00Z])
      {:ok, %{loop: asked}} = Registry.update(loop.id, %{"answer" => "asked"}, @attended, later)

      assert {:error, :ask_after_required} =
               Registry.update(
                 asked.id,
                 %{"answer" => "not_yet", "owner_words" => "nothing yet"},
                 @attended,
                 later
               )

      friday = %{"type" => "date", "date" => "2031-06-06"}

      params = %{
        "answer" => "not_yet",
        "owner_words" => "they decide by Friday",
        "ask_after" => friday
      }

      assert {:ok, result} = Registry.update(asked.id, params, @attended, later)
      assert result.loop.next_touch_at == utc(~U[2031-06-07 13:00:00Z])
      assert result.next_check == "Saturday, June 7, 2031 at 9:00 AM EDT"

      too_soon = %{
        params
        | "ask_after" => %{"type" => "datetime", "date" => "2031-06-03", "time" => "19:00:00"}
      }

      assert {:error, :ask_after_too_soon} = Registry.update(asked.id, too_soon, @attended, later)

      dated = note!(opts).loop

      assert {:error, :ask_after_on_dated_loop} =
               Registry.update(dated.id, params, @attended, opts)

      assert {:error, :ask_after_without_not_yet} =
               Registry.update(asked.id, %{params | "answer" => "plan"}, @attended, later)
    end

    test "a plan on something waited on means after that day, bounded only by a year",
         %{opts: opts} do
      loop = waited!(opts).loop

      august = %{
        "answer" => "plan",
        "owner_words" => "after the August trip",
        "plan_at" => %{"type" => "date", "date" => "2031-08-15"}
      }

      far = %{august | "plan_at" => %{"type" => "date", "date" => "2032-06-01"}}
      assert {:error, :plan_too_far} = Registry.update(loop.id, far, @attended, opts)

      assert {:ok, %{loop: planned}} = Registry.update(loop.id, august, @attended, opts)
      assert planned.next_touch_at == utc(~U[2031-08-16 13:00:00Z])
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
      :ok = due!(opts, ~U[2031-06-07 14:00:00Z])

      assert {:ok, %{loop: asked, previous_state: "due"}} =
               update(loop, %{"answer" => "asked"}, later)

      assert %{state: "asked", touches: 1, last_touch_rung: 1} = asked

      assert {:error, :already_asked} = update(loop, %{"answer" => "asked"}, later)
    end

    test "asked on a loop not yet due is refused: it comes up on its own", %{
      loop: loop,
      opts: opts
    } do
      assert {:error, :not_due} = update(loop, %{"answer" => "asked"}, opts)

      assert {:ok, %{state: "open", touches: 0}} =
               Repo.get_open_loop(loop.id, server: opts[:repo])
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

  # A turn that read outside content can be steered by it, so on such a turn an
  # answer rests only on words the owner typed: `owner_words` must appear, after
  # the dedupe key's normalisation, in the owner's own text for the turn
  # (`:owner_text`, the message as typed, before any attachment manifest, and
  # empty when it was forwarded). `asked` names no words, and a clean turn is
  # unchanged.
  describe "update/4 on a turn that read outside content" do
    setup %{opts: opts} do
      %{loop: note!(opts).loop}
    end

    defp read_a_page(owner_text),
      do: Map.merge(@attended, %{outside_sources: @read_a_page, owner_text: owner_text})

    defp settle(loop, answer, words, context, opts),
      do: Registry.update(loop.id, %{"answer" => answer, "owner_words" => words}, context, opts)

    test "the owner's own words settle it, however cased or punctuated",
         %{loop: loop, opts: opts} do
      typed = "Good news: I SENT the Kestrel Valley application off, this morning!"

      assert {:ok, %{loop: %{state: "closed"}}} =
               settle(
                 loop,
                 "done",
                 "sent the kestrel valley application off this morning",
                 read_a_page(typed),
                 opts
               )
    end

    test "words found only in what the turn read are refused, and nothing changes",
         %{loop: loop, opts: opts, repo: repo} do
      # Words from a fetched page, words that matched only inside a longer word,
      # words from an attachment's manifest (never part of the typed text), and
      # anything at all when the message was forwarded (no typed text).
      for {typed, words} <- [
            {"What does this page say about the fellowship?", "the application was submitted"},
            {"I redid the forms", "did the forms"},
            {"Here is the form, have a look", "attachments 1 kestrel_form.pdf"},
            {"", "I submitted it last night"}
          ] do
        assert {:error, :owner_words_not_in_message} =
                 settle(loop, "done", words, read_a_page(typed), opts),
               inspect({typed, words})
      end

      assert {:ok, %{state: "open"}} = Repo.get_open_loop(loop.id, server: repo)
    end

    test "every answer that names words is bound; asked names none", %{loop: loop, opts: opts} do
      for answer <- ~w(done stop drop not_yet) do
        assert {:error, :owner_words_not_in_message} =
                 settle(loop, answer, "please stop asking", read_a_page("hi"), opts),
               answer
      end

      later = at(opts, ~U[2031-06-07 14:00:00Z])
      :ok = due!(opts, ~U[2031-06-07 14:00:00Z])

      assert {:ok, %{loop: %{state: "asked"}}} =
               Registry.update(loop.id, %{"answer" => "asked"}, read_a_page(""), later)
    end

    # The realtime voice session reads outside content into the whole call and
    # carries no typed text at all: there is nothing to check the words against.
    test "a call with no typed text cannot settle after outside content",
         %{loop: loop, opts: opts} do
      call = Map.put(@attended, :outside_sources, @read_a_page)

      assert {:error, :owner_words_unverifiable} = settle(loop, "done", "done", call, opts)
    end

    # A Live or Grok hand-off's text is the exchange the call's session put
    # together, so even words found in it were not typed by the owner: after
    # outside content its answer waits for the owner's chat, as a realtime
    # call's does.
    test "a voice hand-off cannot settle after outside content", %{loop: loop, opts: opts} do
      hand_off =
        "user: the deposit is done"
        |> read_a_page()
        |> Map.merge(%{computer_use_origin: :voice, voice_call_id: "voice_live_7"})

      assert {:error, :owner_words_unverifiable} =
               settle(loop, "done", "the deposit is done", hand_off, opts)
    end

    # MILESTONE_83's answers move a loop as surely as done closes one: moved,
    # reach and not_yet with ask_after are held to the owner's typed words as the
    # others are, and go through once the owner typed them.
    test "moved, reach and a waited-on not_yet are bound too", %{loop: loop, opts: opts} do
      waited = waited!(opts).loop
      later = at(opts, ~U[2031-06-03 22:00:00Z])
      :ok = due!(opts, ~U[2031-06-03 22:00:00Z])
      {:ok, %{loop: asked}} = Registry.update(waited.id, %{"answer" => "asked"}, @attended, later)

      moved = %{
        "answer" => "moved",
        "owner_words" => "they pushed it to the 24th",
        "matters_by" => %{"type" => "date", "date" => "2031-06-24"}
      }

      reach = %{
        "answer" => "reach",
        "owner_words" => "only mention it when I'm around",
        "reach" => "conversation"
      }

      not_yet = %{
        "answer" => "not_yet",
        "owner_words" => "they decide by Friday",
        "ask_after" => %{"type" => "date", "date" => "2031-06-06"}
      }

      page = read_a_page("What does this page say about the panel?")

      for {id, params, when_opts} <- [
            {loop.id, moved, opts},
            {loop.id, reach, opts},
            {asked.id, not_yet, later}
          ] do
        assert {:error, :owner_words_not_in_message} =
                 Registry.update(id, params, page, when_opts),
               params["answer"]
      end

      typed = read_a_page("Only mention it when I'm around, please")

      assert {:ok, %{loop: %{reach: "conversation"}}} =
               Registry.update(loop.id, reach, typed, opts)

      typed = read_a_page("Good news: they pushed it to the 24th!")

      assert {:ok, %{loop: %{last_answer: "moved"}}} =
               Registry.update(loop.id, moved, typed, opts)

      typed = read_a_page("Nothing yet, they decide by Friday.")

      assert {:ok, %{loop: %{state: "open"}}} =
               Registry.update(asked.id, not_yet, typed, later)
    end

    test "a turn that read nothing is unchanged", %{loop: loop, opts: opts} do
      clean = Map.put(@attended, :owner_text, "What's the weather like on Friday?")

      assert {:ok, %{loop: %{state: "closed"}}} =
               settle(loop, "done", "sent it off this morning", clean, opts)
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
      view = Registry.view(ctx.live, ctx.opts)

      assert view == %{
               "open_loop_id" => ctx.live.id,
               "intention" => @intention,
               "why_it_matters" => nil,
               "matters_by" => "Tuesday, June 10, 2031",
               "matters_by_source" => "owner",
               "reach" => "message",
               "horizon_class" => "medium",
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
               Registry.view(closed, ctx.opts)

      for view <- [view, Registry.view(closed, ctx.opts)] do
        refute Enum.any?(Map.values(view), &(&1 == "40001"))
      end
    end

    test "times are stated in the owner's current zone, the clock the date note reads", ctx do
      # 02:30 UTC on Tuesday is 03:30 Tuesday in London and 22:30 Monday in New
      # York. A loop whose dates are London's still states the day it was said
      # on the owner's clock, so it agrees with the current-date note.
      said = ~U[2031-06-03 02:30:00Z]
      opts = at(ctx.opts, said)

      %{loop: loop} =
        note!(opts, %{"intention" => "Book the Larkspur ferry", "timezone" => "Europe/London"})

      assert loop.timezone == "Europe/London"
      assert %{"said_on" => "Monday, June 2, 2031"} = Registry.view(loop, opts)

      assert %{"said_on" => "Tuesday, June 3, 2031"} =
               Registry.view(loop, personalization: [timezone: "Europe/London"])
    end
  end

  describe "error_tag/1" do
    test "is the reason or its leading atom, as the failure modes name it" do
      assert Registry.error_tag(:ask_after_too_far) == "ask_after_too_far"
      assert Registry.error_tag({:invalid_param, :reach}) == "invalid_param"
      assert Registry.error_tag({:kind_conflict, "loop_AbCdEfGhIjK"}) == "kind_conflict"
      assert Registry.error_tag({:timeout, :repo_call, 5_000}) == "timeout"
      assert Registry.error_tag("socket closed") == "storage_failed"
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
        :owner_words_not_in_message,
        :owner_words_unverifiable,
        :plan_after_date,
        :plan_requires_date,
        :plan_passed,
        :plan_at_without_plan,
        :missing_when,
        :both_whens,
        {:kind_conflict, "loop_AbCdEfGhIjK"},
        :ask_after_too_soon,
        :ask_after_too_far,
        :source_without_matters_by,
        {:invalid_param, :reach},
        {:invalid_param, :matters_by_source},
        {:missing_parameters, [:reach]},
        :plan_too_far,
        :ask_after_required,
        :ask_after_without_not_yet,
        :ask_after_on_dated_loop,
        :matters_by_without_moved,
        :moved_requires_date,
        :moved_on_after_loop,
        :reach_without_reach_answer,
        :not_due,
        :touches_spent,
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
      assert Registry.describe_error(:owner_words_not_in_message) =~ "owner's own words"
      assert Registry.describe_error(:owner_words_not_in_message) =~ "ask the owner"
      assert Registry.describe_error(:not_due) =~ "not due yet"
      assert Registry.describe_error(:touches_spent) =~ "twice"
    end
  end
end
