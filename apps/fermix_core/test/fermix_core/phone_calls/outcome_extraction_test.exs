defmodule FermixCore.PhoneCalls.OutcomeExtractionTest do
  # `Outcome.extract/4` with the provider injected into the route's opts, so
  # no real adapter is ever resolved and nothing reaches the network. Every
  # name, number and place is invented; numbers are in the 555-01XX range.
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias FermixCore.PhoneCalls.Brief
  alias FermixCore.PhoneCalls.Outcome
  alias FermixCore.PhoneCalls.Outcome.Extraction

  @now ~U[2026-11-18 16:00:00Z]
  @session "phone_call_pc_0a1b2c3d4e5f"
  @route %{
    provider: :openai,
    model: "gpt-test",
    auth_mode: :api_key,
    base_url: "https://api.openai.com/v1"
  }

  # A provider that answers as the test says and tells the test what it was sent.
  defmodule ExtractionAdapter do
    def chat(messages, tools, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:extraction_call, messages, tools, opts})

      case Keyword.fetch!(opts, :answer) do
        :hang -> receive(do: (:never_sent -> {:error, :unreachable}))
        {:raise, message} -> raise message
        answer -> answer
      end
    end
  end

  defp brief do
    {:ok, brief} =
      Brief.new(
        %{
          "destination" => "+13125550123",
          "destination_kind" => "business",
          "number_source" => "Listed on the restaurant's own website.",
          "contact_name" => "Marrow & Sage",
          "timezone" => "America/Chicago",
          "goal" => "Reserve a table for four on Saturday, December 5, 2026 at 7:30 PM.",
          "completion_criteria" => ["The restaurant confirms a table for four."],
          "times" => [%{"label" => "Requested table", "at" => "2026-12-05T19:30"}]
        },
        caller_number: "+14155550142",
        now: @now
      )

    brief
  end

  defp said(speaker, text, start_ms),
    do: %{speaker: speaker, text: text, start_ms: start_ms, end_ms: start_ms + 2_000}

  defp call do
    [
      said(:assistant, "Hi, I'm an AI assistant calling to book a table for four.", 0),
      said(:remote, "Sure, four on Saturday December 5th at 7:30 works.", 2_500),
      said(:assistant, "So four on December 5 at 7:30 PM. Is it booked?", 5_000),
      said(:remote, "Yes, it's booked.", 7_500)
    ]
  end

  defp claim_json do
    Jason.encode!(%{
      "outcome" => "confirmed",
      "commitment" => "completed",
      "confirmation_quote" => "Yes, it's booked",
      "criteria" => [%{"index" => 1, "quote" => "four on Saturday December 5th"}],
      "facts" => [
        %{"field" => "date", "value" => "2026-12-05", "quote" => "Saturday December 5th"},
        %{"field" => "local_time", "value" => "19:30", "quote" => "at 7:30"}
      ]
    })
  end

  defp turn(content),
    do: {:ok, %{content: content, tool_calls: [], provider_state: %{}, model: "gpt-test"}}

  defp opts(answer, extra \\ []) do
    Keyword.merge(
      [
        started_at: @now,
        session_id: @session,
        routes: [{@route, [adapter: ExtractionAdapter, test_pid: self(), answer: answer]}]
      ],
      extra
    )
  end

  @answered %{answered: true, end_reason: :hangup}

  describe "decided in code, with no model call" do
    test "a call nobody answered" do
      assert {:ok, %Outcome{outcome: :unknown, reason: :no_answer, extraction: :not_needed}} =
               Outcome.extract(
                 brief(),
                 [],
                 %{answered: false, end_reason: :no_answer},
                 opts(turn(claim_json()))
               )

      refute_received {:extraction_call, _, _, _}
    end

    test "a busy line and a rejected call keep their reason" do
      for reason <- [:busy, :rejected] do
        assert {:ok, %Outcome{outcome: :unknown, reason: ^reason}} =
                 Outcome.extract(
                   brief(),
                   [],
                   %{answered: false, end_reason: reason},
                   opts(turn(claim_json()))
                 )
      end

      refute_received {:extraction_call, _, _, _}
    end

    test "voicemail" do
      voicemail = [said(:remote, "Leave a message after the tone.", 0)]

      assert {:ok, %Outcome{outcome: :unknown, reason: :voicemail}} =
               Outcome.extract(
                 brief(),
                 voicemail,
                 %{answered: true, end_reason: :voicemail},
                 opts(turn(claim_json()))
               )

      refute_received {:extraction_call, _, _, _}
    end

    test "an answered call in which the recipient said nothing" do
      only_us = [said(:assistant, "Hello? Is anyone there?", 0)]

      assert {:ok, %Outcome{outcome: :unknown, reason: :no_recipient_speech}} =
               Outcome.extract(brief(), only_us, @answered, opts(turn(claim_json())))

      refute_received {:extraction_call, _, _, _}
    end
  end

  describe "one extraction" do
    test "a well-formed answer: one tool-free call on the call's session, then verified" do
      assert {:ok, %Outcome{outcome: :confirmed, extraction: :ok} = outcome} =
               Outcome.extract(brief(), call(), @answered, opts(turn(claim_json())))

      assert outcome.facts.date == "2026-12-05"

      assert_received {:extraction_call, [system, user], [], call_opts}
      refute_received {:extraction_call, _, _, _}

      assert system.role == "system"
      assert system.content == Extraction.prompt()
      assert system.content =~ "Only lines marked recipient are evidence"

      assert user.role == "user"
      assert user.content =~ "Objective: \"Reserve a table for four"
      assert user.content =~ ~s(<untrusted_tool_result source="phone_call_transcript">)

      assert user.content =~
               "[2.5s] recipient: Sure, four on Saturday December 5th at 7:30 works."

      refute user.content =~ "5550123"

      assert Keyword.fetch!(call_opts, :session_id) == @session
      assert Keyword.fetch!(call_opts, :agent) == "phone_call_outcome"
      assert Keyword.fetch!(call_opts, :temperature) == 0
    end

    test "a yes to the assistant's read-back, from the answer to the outcome" do
      call = [
        said(:remote, "Marrow and Sage, how can I help?", 0),
        said(
          :assistant,
          "A table for four on Saturday, December 5 at 7:30 PM. Is that booked?",
          2_500
        ),
        said(:remote, "Yes.", 5_000)
      ]

      claim =
        Jason.encode!(%{
          "outcome" => "confirmed",
          "commitment" => "completed",
          "confirmation_quote" => "Yes",
          "readback_quote" => "A table for four on Saturday, December 5 at 7:30 PM",
          "criteria" => [%{"index" => 1, "quote" => "A table for four"}],
          "facts" => [
            %{"field" => "date", "value" => "2026-12-05", "quote" => "Saturday, December 5"},
            %{"field" => "local_time", "value" => "19:30", "quote" => "at 7:30 PM"}
          ]
        })

      assert {:ok, %Outcome{outcome: :confirmed, confirmation: :readback}} =
               Outcome.extract(brief(), call, @answered, opts(turn(claim)))
    end

    test "an answer inside one code fence is read the same" do
      fenced = "```json\n" <> claim_json() <> "\n```"

      assert {:ok, %Outcome{outcome: :confirmed}} =
               Outcome.extract(brief(), call(), @answered, opts(turn(fenced)))
    end

    test "the verdict is verify's: a claimed booking with no recipient words behind it is unknown" do
      claim =
        claim_json()
        |> Jason.decode!()
        |> Map.put("confirmation_quote", "Is it booked?")
        |> Jason.encode!()

      assert {:ok,
              %Outcome{outcome: :unknown, reason: :assistant_only_confirmation, extraction: :ok}} =
               Outcome.extract(brief(), call(), @answered, opts(turn(claim)))
    end

    # An error the chain would retry on its route and then fail over from.
    test "only the first route is asked, once, with no retry and no failover" do
      retryable = {:error, {:provider_error, %{kind: :provider_unavailable}}}

      routes = [
        {@route, [adapter: ExtractionAdapter, test_pid: self(), answer: retryable]},
        {%{@route | model: "gpt-second"},
         [adapter: ExtractionAdapter, test_pid: self(), answer: turn(claim_json())]}
      ]

      assert {:ok, %Outcome{outcome: :unknown, reason: :extraction_provider_error}} =
               Outcome.extract(brief(), call(), @answered, opts(nil, routes: routes))

      assert_received {:extraction_call, _, _, _}
      refute_received {:extraction_call, _, _, _}
    end

    test "an abrupt end is noted beside a verified result" do
      assert {:ok, %Outcome{outcome: :confirmed, uncertainty: note}} =
               Outcome.extract(
                 brief(),
                 call(),
                 %{answered: true, end_reason: :connection_lost},
                 opts(turn(claim_json()))
               )

      assert note == "The call ended early (connection_lost)."
    end

    test "a transcript past its bound is cut from the front, and the outcome says so" do
      early =
        for n <- 1..900,
            do:
              said(
                Enum.at([:remote, :assistant], rem(n, 2)),
                "filler #{n} " <> String.duplicate("z", 50),
                n
              )

      assert {:ok, %Outcome{uncertainty: note}} =
               Outcome.extract(brief(), early ++ call(), @answered, opts(turn(claim_json())))

      assert note =~ "The start of a long call was left out of the review."
      assert_received {:extraction_call, [_system, user], [], _opts}
      assert user.content =~ "(earlier speech cut for length)"
      assert user.content =~ "Yes, it's booked."
      refute user.content =~ "filler 1 "
    end
  end

  describe "a failed extraction is an unknown outcome with its class kept" do
    test "malformed: prose instead of the object" do
      assert {:ok,
              %Outcome{
                outcome: :unknown,
                reason: :extraction_malformed,
                extraction: {:failed, :malformed, _}
              }} =
               Outcome.extract(
                 brief(),
                 call(),
                 @answered,
                 opts(turn("The table is booked for Saturday."))
               )
    end

    test "malformed: a key outside the object's shape" do
      extra = claim_json() |> Jason.decode!() |> Map.put("approved", true) |> Jason.encode!()

      assert {:ok, %Outcome{reason: :extraction_malformed}} =
               Outcome.extract(brief(), call(), @answered, opts(turn(extra)))
    end

    test "malformed: an outcome word outside the set" do
      word = claim_json() |> Jason.decode!() |> Map.put("outcome", "booked") |> Jason.encode!()

      assert {:ok, %Outcome{reason: :extraction_malformed}} =
               Outcome.extract(brief(), call(), @answered, opts(turn(word)))
    end

    test "a provider refusal" do
      refusal =
        {:ok,
         %{content: "", tool_calls: [], provider_state: %{stop_reason: "refusal"}, model: "m"}}

      assert {:ok,
              %Outcome{
                outcome: :unknown,
                reason: :extraction_refused,
                extraction: {:failed, :refused, _}
              }} =
               Outcome.extract(brief(), call(), @answered, opts(refusal))
    end

    test "no answer within the bound" do
      assert {:ok,
              %Outcome{
                outcome: :unknown,
                reason: :extraction_timeout,
                extraction: {:failed, :timeout, _}
              }} =
               Outcome.extract(brief(), call(), @answered, opts(:hang, timeout_ms: 100))
    end

    test "a provider error and a crash" do
      assert {:ok, %Outcome{reason: :extraction_provider_error}} =
               Outcome.extract(brief(), call(), @answered, opts({:error, :overloaded}))

      assert {:ok, %Outcome{reason: :extraction_crashed, extraction: {:failed, :crashed, _}}} =
               Outcome.extract(brief(), call(), @answered, opts({:raise, "boom"}))
    end

    test "the reason's sentence is the uncertainty" do
      assert {:ok, %Outcome{uncertainty: note}} =
               Outcome.extract(brief(), call(), @answered, opts(turn("not json")))

      assert note == Outcome.reason(:extraction_malformed)
    end
  end

  test "the session id and the start time are required, on every path" do
    unanswered = %{answered: false, end_reason: :no_answer}

    for key <- [:session_id, :started_at], transport <- [@answered, unanswered] do
      assert_raise ArgumentError, fn ->
        Outcome.extract(brief(), call(), transport, Keyword.delete(opts(turn(claim_json())), key))
      end
    end
  end
end
