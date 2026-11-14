defmodule FermixCore.Tools.PlaceSearch.BravePacingTest do
  # Brave place searches through the home's pacer (`Brave.Pacer`): one request
  # at a time, each sent when Brave's last answer allows it, one bounded retry
  # after a 429, and a key whose plan has no place search named as that. The
  # `place_search` tool and a trip's lookups both go this way.
  #
  # Each test runs its own pacer on a clock it moves by hand, and its waits go
  # to a sleeper that only records them and moves that clock, so nothing here
  # waits on the wall clock. It drives the global config section the place
  # search reads (the backend and the Brave key), so it establishes it in
  # `setup`, restores it in `on_exit`, and runs `async: false`, as
  # `PlaceSearchTest` does; the log assertion needs that too.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixCore.ReplyBlocks
  alias FermixCore.Tools.PlaceSearch
  alias FermixCore.Tools.PlaceSearch.Brave
  alias FermixCore.Tools.PlaceSearch.Brave.Pacer
  alias FermixCore.Trips.Lookup
  alias FermixTestSupport.TelemetryCapture

  @key "brave-secret"
  @conversation {"test", "brave-pacing", :root}
  @plan_detail "The option is not included in the plan."
  @rate_detail "Request rate limit exceeded for plan"

  setup do
    tools = Application.get_env(:fermix_core, :tools)
    on_exit(fn -> restore(:tools, tools) end)

    Application.put_env(:fermix_core, :tools,
      web_search: [brave_api_key: @key],
      place_search: [backend: "brave"]
    )

    clock = agent(0)
    pacer = start_supervised!({Pacer, name: nil, now_ms: fn -> Agent.get(clock, & &1) end})
    test_pid = self()

    sleep = fn ms ->
      send(test_pid, {:slept, ms})
      Agent.update(clock, &(&1 + ms))
    end

    %{clock: clock, pacer: pacer, sleep: sleep, session_id: "pacing-#{unique()}"}
  end

  describe "pacing by Brave's rate headers" do
    test "after an answer with none left this second, the next request waits out the reset",
         ctx do
      context = stub(ctx, fn conn -> place(conn, spent()) end)

      assert {:ok, [_place], _trace} = search(context)
      refute_received {:slept, _ms}

      assert {:ok, [_place], _trace} = search(context)
      assert_received {:slept, 1_000}
    end

    test "a spent window that resets in under a second still holds the next request 1 s",
         ctx do
      context = stub(ctx, fn conn -> place(conn, rate("1, 15000", "0, 14999", "0, 1419704")) end)

      assert {:ok, [_place], _trace} = search(context)
      assert {:ok, [_place], _trace} = search(context)
      assert_received {:slept, 1_000}
    end

    test "after a 200 that spent the key's quota, the next search sends nothing and says so",
         ctx do
      counter = agent(0)

      context =
        stub(ctx, fn conn ->
          Agent.update(counter, &(&1 + 1))
          place(conn, rate("1, 15000", "1, 0", "1, 1419704"))
        end)

      assert {:ok, [_place], %{attempt: 1}} = search(context)
      assert {:error, reason, %{attempt: 0}} = search(context)

      assert reason ==
               "rate_limited: the Brave Search API key's quota is spent for 17 days, until " <>
                 "Brave resets it; place search cannot run until then, so do not search again"

      assert Agent.get(counter, & &1) == 1
      refute_received {:slept, _ms}
    end

    test "after an answer with some left this second, the next request goes at once", ctx do
      context = stub(ctx, fn conn -> place(conn, open()) end)

      assert {:ok, [_place], _trace} = search(context)
      assert {:ok, [_place], _trace} = search(context)
      refute_received {:slept, _ms}
    end

    test "concurrent searches reach Brave one at a time", ctx do
      gauge = agent(%{running: 0, most: 0})
      test_pid = self()

      context =
        stub(ctx, fn conn ->
          Agent.update(gauge, fn %{running: running, most: most} ->
            %{running: running + 1, most: max(most, running + 1)}
          end)

          send(test_pid, {:started, self()})

          receive do
            :go -> :ok
          end

          Agent.update(gauge, &%{&1 | running: &1.running - 1})
          place(conn, open())
        end)

      searches = for _search <- 1..4, do: Task.async(fn -> search(context) end)

      for _search <- 1..4 do
        assert_receive {:started, pid}
        send(pid, :go)
      end

      assert Enum.all?(Task.await_many(searches, 10_000), &match?({:ok, [_place], _trace}, &1))
      assert Agent.get(gauge, & &1.most) == 1
    end

    test "an answer with no rate headers is said once, and paces nothing", ctx do
      context = stub(ctx, fn conn -> place(conn, %{}) end)

      log =
        capture_log(fn ->
          assert {:ok, [_place], _trace} = search(context)
          assert {:ok, [_place], _trace} = search(context)
        end)

      assert length(String.split(log, "carried no rate window")) == 2
      refute_received {:slept, _ms}
    end
  end

  describe "one bounded retry after a 429" do
    test "a 429 is sent again once after the reset its headers give", ctx do
      counter = agent(0)

      context =
        stub(ctx, fn conn ->
          case Agent.get_and_update(counter, &{&1, &1 + 1}) do
            0 -> rate_limited(conn, rate(nil, "0, 14999", "1, 1419704"))
            _retry -> place(conn, open())
          end
        end)

      assert {:ok, [%{name: "Prado"}], %{attempt: 2}} = search(context)
      assert_received {:slept, 1_000}
      assert Agent.get(counter, & &1) == 2
    end

    test "a second 429 is rate_limited, with Brave's words", ctx do
      counter = agent(0)

      context =
        stub(ctx, fn conn ->
          Agent.update(counter, &(&1 + 1))
          rate_limited(conn, rate(nil, "0, 14999", "1, 1419704"))
        end)

      assert {:error, reason, %{attempt: 2}} = search(context)
      assert reason == "rate_limited: HTTP 429 RATE_LIMITED: #{@rate_detail}"
      assert Agent.get(counter, & &1) == 2
      assert_received {:slept, 1_000}
      refute_received {:slept, _ms}
    end

    test "a 429 with no reset header waits 1 s before its retry", ctx do
      counter = agent(0)

      context =
        stub(ctx, fn conn ->
          case Agent.get_and_update(counter, &{&1, &1 + 1}) do
            0 -> rate_limited(conn, %{})
            _retry -> place(conn, open())
          end
        end)

      assert {:ok, [_place], %{attempt: 2}} = search(context)
      assert_received {:slept, 1_000}
    end

    test "a 429 whose reset comes after 2 s is not sent again, and says until when", ctx do
      counter = agent(0)

      context =
        stub(ctx, fn conn ->
          Agent.update(counter, &(&1 + 1))
          rate_limited(conn, rate(nil, "0, 14999", "9, 1419704"))
        end)

      assert {:error, reason, %{attempt: 1, provider_code: "RATE_LIMITED"}} = search(context)

      assert reason ==
               "rate_limited: the Brave Search API key's quota is spent for 9 s, until Brave " <>
                 "resets it; place search cannot run until then, so do not search again " <>
                 "(HTTP 429 RATE_LIMITED: #{@rate_detail})"

      assert Agent.get(counter, & &1) == 1
      refute_received {:slept, _ms}
    end

    test "a 429 with no time left to send again is rate_limited, sent once", ctx do
      counter = agent(0)

      context =
        stub(ctx, fn conn ->
          Agent.update(counter, &(&1 + 1))
          rate_limited(conn, rate(nil, "0, 14999", "1, 1419704"))
        end)

      assert {:error, "rate_limited: " <> _rest, %{attempt: 1}} =
               Brave.search(%{query: "Prado"},
                 context: context,
                 brave_api_key: @key,
                 send_within_ms: 500
               )

      assert Agent.get(counter, & &1) == 1
      refute_received {:slept, _ms}
    end

    test "a search whose turn would come after its wait ends sends nothing", ctx do
      counter = agent(0)

      context =
        stub(ctx, fn conn ->
          Agent.update(counter, &(&1 + 1))
          place(conn, spent())
        end)

      assert {:ok, [_place], _trace} = search(context)

      assert {:error, reason, %{attempt: 0}} =
               Brave.search(%{query: "Prado"},
                 context: context,
                 brave_api_key: @key,
                 send_within_ms: 999
               )

      assert reason ==
               "deadline: the place search is busy with this home's other searches; " <>
                 "try again shortly"

      assert Agent.get(counter, & &1) == 1
      refute_received {:slept, _ms}
    end
  end

  describe "the turn always ends" do
    test "a raise between the turn and its end never leaves the door held", ctx do
      context =
        stub(ctx, fn conn -> brave_error(conn, 400, "OPTION_NOT_IN_PLAN", @plan_detail) end)

      assert_raise RuntimeError, "the stop broke", fn ->
        Brave.search(%{query: "Prado"},
          context: context,
          brave_api_key: @key,
          stop: fn _why -> raise "the stop broke" end
        )
      end

      # Held, the door would answer a caller with no time to wait only when
      # that wait ends, refused.
      assert {:ok, _turn, 0} = Pacer.turn(ctx.pacer, 0)
    end
  end

  describe "the place_search tool" do
    test "goes through the pacer, and one call is one tool event naming its attempts", ctx do
      TelemetryCapture.attach([[:fermix, :tool, :exec]], session_id: ctx.session_id)
      counter = agent(0)

      context =
        ctx
        |> stub(fn conn ->
          case Agent.get_and_update(counter, &{&1, &1 + 1}) do
            0 -> place(conn, spent())
            1 -> rate_limited(conn, rate(nil, "0, 14999", "1, 1419704"))
            _retry -> place(conn, open())
          end
        end)
        |> Map.put(:reply_blocks, holder())

      assert {:ok, %{success: true}} = PlaceSearch.execute(%{"query" => "Prado"}, context)
      assert_receive {:telemetry, [:fermix, :tool, :exec], _measurements, %{attempt: 1}}
      refute_received {:slept, _ms}

      assert {:ok, %{success: true}} = PlaceSearch.execute(%{"query" => "Prado"}, context)
      assert_receive {:telemetry, [:fermix, :tool, :exec], _measurements, metadata}
      assert metadata.tool == "place_search"
      assert metadata.attempt == 2
      assert_received {:slept, 1_000}
      assert_received {:slept, 1_000}

      refute_received {:telemetry, [:fermix, :tool, :exec], _more, _metadata}
    end

    test "says plainly that the key's plan has no place search", ctx do
      context =
        ctx
        |> stub(fn conn -> brave_error(conn, 400, "OPTION_NOT_IN_PLAN", @plan_detail) end)
        |> Map.put(:reply_blocks, holder())

      assert {:ok, %{success: false, error: error}} =
               PlaceSearch.execute(%{"query" => "Prado"}, context)

      assert error ==
               "plan_excludes_place_search: the Brave Search API key's plan does not include " <>
                 "place search, so searching again cannot find a place; tell the owner to add " <>
                 "place search to that key's plan, and take a place's link only from the " <>
                 "owner or a web search, never a made-up one " <>
                 "(HTTP 400 OPTION_NOT_IN_PLAN: #{@plan_detail})"
    end
  end

  describe "a trip's lookups" do
    test "a lookup whose turn would send after the call's deadline is stopped as :deadline",
         ctx do
      counter = agent(0)

      # The first answer spends this second's window as the call's clock
      # reaches half a second before its deadline: the next send would come
      # after it.
      context =
        stub(ctx, fn conn ->
          Agent.update(counter, &(&1 + 1))
          Agent.update(ctx.clock, &(&1 + Lookup.deadline_ms() - 500))
          place(conn, spent())
        end)

      requests = Enum.map(1..3, &%{ref: &1, place: "Prado", day: &1})

      # The two stopped before sending are no lookups.
      assert {:ok, %{outcomes: outcomes, lookups: 1, stop_reason: :deadline, stop_code: nil}} =
               resolve(requests, context, ctx.clock)

      assert [{1, {:placed, %{name: "Prado"}}}, {2, {:none, :deadline}}, {3, {:none, :deadline}}] =
               outcomes

      assert Agent.get(counter, & &1) == 1
      refute_received {:slept, _ms}
    end

    test "a key whose plan has no place search spends one request and stops the rest", ctx do
      counter = agent(0)

      context =
        stub(ctx, fn conn ->
          Agent.update(counter, &(&1 + 1))
          brave_error(conn, 400, "OPTION_NOT_IN_PLAN", @plan_detail)
        end)

      requests = Enum.map(1..5, &%{ref: &1, place: "Spot #{&1}", day: 1})

      assert {:ok, %{outcomes: outcomes, records: [], lookups: 1} = found} =
               resolve(requests, context, ctx.clock)

      assert %{stop_reason: :plan_excludes_place_search, stop_code: "OPTION_NOT_IN_PLAN"} = found

      assert Enum.map(outcomes, &elem(&1, 1)) ==
               List.duplicate({:none, :plan_excludes_place_search}, 5)

      assert Agent.get(counter, & &1) == 1

      assert Lookup.heading(:plan_excludes_place_search) ==
               "Not looked up, the Brave Search API key's plan does not include place search; " <>
                 "add place search to that key's plan, or give each stop its link from the " <>
                 "owner or a web search, never a made-up one"
    end

    test "once a key without place search answers, the rest of its wave send nothing", ctx do
      counter = agent(0)

      context =
        stub(ctx, fn conn ->
          case Agent.get_and_update(counter, &{&1, &1 + 1}) do
            0 -> place(conn, open())
            _later -> brave_error(conn, 400, "OPTION_NOT_IN_PLAN", @plan_detail)
          end
        end)

      # The first alone, then a wave of four queued for the door together.
      requests = Enum.map(1..5, &%{ref: &1, place: "Prado", day: &1})

      assert {:ok, %{outcomes: [{1, {:placed, _place}} | rest], lookups: 2} = found} =
               resolve(requests, context, ctx.clock)

      assert Enum.map(rest, &elem(&1, 1)) ==
               List.duplicate({:none, :plan_excludes_place_search}, 4)

      assert %{stop_reason: :plan_excludes_place_search, stop_code: "OPTION_NOT_IN_PLAN"} = found
      assert Agent.get(counter, & &1) == 2
    end

    test "the stop's code is the stopping answer's, though lookups it left unsent settle first" do
      test_pid = self()

      refusal =
        {:error, "plan_excludes_place_search: refused",
         %{attempt: 1, provider_code: "OPTION_NOT_IN_PLAN"}}

      # The last of the wave stops the call; the three before it wait for that
      # and then send nothing, as a Brave search queued behind it does.
      search = fn %{query: query}, terms ->
        case query do
          "Spot 1" ->
            {:ok, [], %{attempt: 1}}

          "Spot 5" ->
            :ok = Keyword.fetch!(terms, :stop).(:plan_excludes_place_search)
            send(test_pid, :stopped)
            refusal

          _sibling ->
            send(test_pid, {:queued, self()})

            receive do
              :go -> :ok
            end

            why = Keyword.fetch!(terms, :stopped).()
            {:error, "#{why}: not sent", %{attempt: 0}}
        end
      end

      server = holder()

      task =
        Task.async(fn ->
          Lookup.resolve(
            Enum.map(1..5, &%{ref: &1, place: "Spot #{&1}", day: 1}),
            %{placed: %{}, day_near: %{}, trip_near: "Lisbon, Portugal"},
            backend: {:ok, search},
            reply_blocks: server,
            conversation_key: @conversation
          )
        end)

      assert_receive :stopped

      siblings =
        for _sibling <- 1..3 do
          assert_receive {:queued, pid}
          pid
        end

      Enum.each(siblings, &send(&1, :go))

      assert {:ok, %{outcomes: [{1, {:none, :not_found}} | rest], lookups: 2} = found} =
               Task.await(task, 10_000)

      assert Enum.map(rest, &elem(&1, 1)) ==
               List.duplicate({:none, :plan_excludes_place_search}, 4)

      assert %{stop_reason: :plan_excludes_place_search, stop_code: "OPTION_NOT_IN_PLAN"} = found
    end

    test "once a lookup is rate limited, the rest of its wave send nothing", ctx do
      counter = agent(0)

      context =
        stub(ctx, fn conn ->
          case Agent.get_and_update(counter, &{&1, &1 + 1}) do
            0 -> place(conn, open())
            _later -> rate_limited(conn, rate(nil, "0, 14999", "0, 1419704"))
          end
        end)

      requests = Enum.map(1..5, &%{ref: &1, place: "Prado", day: &1})

      assert {:ok, %{outcomes: [{1, {:placed, _place}} | rest], lookups: 2} = found} =
               resolve(requests, context, ctx.clock)

      assert Enum.map(rest, &elem(&1, 1)) == List.duplicate({:none, :rate_limited}, 4)
      assert %{stop_reason: :rate_limited, stop_code: "RATE_LIMITED"} = found

      # The second lookup's 429 and its one retry; the other three sent nothing.
      assert Agent.get(counter, & &1) == 3
      assert_received {:slept, 1_000}
      refute_received {:slept, _ms}
    end

    test "a 400 with another code is a failed lookup, not a stop of the rest", ctx do
      counter = agent(0)

      context =
        stub(ctx, fn conn ->
          Agent.update(counter, &(&1 + 1))
          brave_error(conn, 400, "VALIDATION", "Unable to validate request parameter(s).")
        end)

      requests = Enum.map(1..2, &%{ref: &1, place: "Spot #{&1}", day: 1})

      assert {:ok, %{outcomes: outcomes, lookups: 2}} = resolve(requests, context, ctx.clock)

      assert [{1, {:none, {:failed, "provider_error: HTTP 400 VALIDATION" <> _}}}, _second] =
               outcomes

      assert Agent.get(counter, & &1) == 2
    end
  end

  describe "the application's pacer" do
    test "is started under its name, and a search that names no pacer goes through it" do
      pacer = Process.whereis(Pacer)
      assert is_pid(pacer)

      assert {Pacer, ^pacer, :worker, _modules} =
               List.keyfind(Supervisor.which_children(FermixCore.Supervisor), Pacer, 0)

      test_pid = self()
      test_id = :"brave_pacing_app_#{unique()}"

      # A caller holding a turn is monitored by the pacer that gave it.
      Req.Test.stub(test_id, fn conn ->
        {:monitored_by, watchers} = Process.info(self(), :monitored_by)
        send(test_pid, {:held_by_application_pacer, pacer in watchers})
        place(conn, open())
      end)

      context = %{
        req_options: [plug: {Req.Test, test_id}],
        net_resolver: fn "api.search.brave.com" -> {:ok, [{93, 184, 216, 34}]} end
      }

      assert {:ok, [_place], %{attempt: 1}} =
               Brave.search(%{query: "Prado"}, context: context, brave_api_key: @key)

      assert_received {:held_by_application_pacer, true}
    end
  end

  # -- helpers ---------------------------------------------------------------

  defp search(context), do: Brave.search(%{query: "Prado"}, context: context, brave_api_key: @key)

  defp resolve(requests, context, clock) do
    Lookup.resolve(
      requests,
      %{placed: %{}, day_near: %{}, trip_near: "Lisbon, Portugal"},
      backend: Lookup.backend(context),
      reply_blocks: holder(),
      conversation_key: @conversation,
      now_ms: fn -> Agent.get(clock, & &1) end
    )
  end

  defp stub(ctx, handler) do
    test_id = :"brave_pacing_#{unique()}"
    Req.Test.stub(test_id, handler)

    %{
      agent_name: "test_agent",
      session_id: ctx.session_id,
      conversation_key: @conversation,
      req_options: [plug: {Req.Test, test_id}],
      net_resolver: fn "api.search.brave.com" -> {:ok, [{93, 184, 216, 34}]} end,
      place_search_pacer: ctx.pacer,
      place_search_sleep: ctx.sleep
    }
  end

  defp agent(initial),
    do: start_supervised!(Supervisor.child_spec({Agent, fn -> initial end}, id: make_ref()))

  defp holder do
    start_supervised!(Supervisor.child_spec({ReplyBlocks, name: nil}, id: make_ref()))
  end

  defp place(conn, headers) do
    respond(conn, headers, 200, %{
      "results" => [
        %{
          "type" => "location_result",
          "title" => "Prado",
          "url" => "https://prado.example/",
          "provider_url" => "https://search.brave.com/local/place/prado",
          "coordinates" => [38.7101, -9.1335]
        }
      ]
    })
  end

  defp rate_limited(conn, headers) do
    respond(conn, headers, 429, error_body(429, "RATE_LIMITED", @rate_detail))
  end

  defp brave_error(conn, status, code, detail),
    do: respond(conn, %{}, status, error_body(status, code, detail))

  # Brave's ErrorResponse, as the owner's server saw it.
  defp error_body(status, code, detail) do
    %{
      "type" => "ErrorResponse",
      "error" => %{"code" => code, "detail" => detail, "meta" => %{}, "status" => status}
    }
  end

  defp respond(conn, headers, status, body) do
    headers
    |> Enum.reduce(conn, fn {name, [value]}, acc ->
      Plug.Conn.put_resp_header(acc, name, value)
    end)
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end

  # This second's window spent, and one with a request left in it.
  defp spent, do: rate("1, 15000", "0, 14999", "1, 1419704")
  defp open, do: rate("1, 15000", "1, 14999", "1, 1419704")

  defp rate(limit, remaining, reset) do
    [
      {"x-ratelimit-limit", limit},
      {"x-ratelimit-remaining", remaining},
      {"x-ratelimit-reset", reset}
    ]
    |> Enum.reject(fn {_name, value} -> is_nil(value) end)
    |> Map.new(fn {name, value} -> {name, [value]} end)
  end

  defp unique, do: System.unique_integer([:positive])

  defp restore(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore(key, value), do: Application.put_env(:fermix_core, key, value)
end
