defmodule FermixCore.Cues.Filter.DecisionTest do
  # async: false — every screen resolves its route from the shared
  # `[fermix_core.providers]` app env (established here, restored on exit).
  use ExUnit.Case, async: false

  alias FermixCore.Cues.Filter.Decision
  alias FermixCore.Cues.Filter.Prompt
  alias FermixTestSupport.TelemetryCapture

  @session_id "cue_filter_cwt_dec_20261029_120000_a1b2c3"

  setup do
    providers = Application.get_env(:fermix_core, :providers, [])
    on_exit(fn -> Application.put_env(:fermix_core, :providers, providers) end)

    Application.put_env(:fermix_core, :providers,
      anthropic: [api_key: "sk-ant-invented", primary: true],
      openrouter: [api_key: "sk-or-invented"]
    )

    :ok
  end

  describe "the screen" do
    test "asks the watcher's criteria, with its words as hints, about the item alone" do
      test = self()

      id =
        stub(fn conn, body ->
          send(test, {:request, conn.request_path, body})
          noul(conn, 0.31)
        end)

      claim = claim()
      assert screen(claim, id) == :through

      assert_received {:request, "/api/alpha/decisions", body}
      assert body["model"] == "~typesafe/jev-latest"
      assert body["state"] == Prompt.evidence(%{claim | examples: []})
      refute body["state"] =~ "Example 1"

      %{"instructions" => instructions, "criteria" => criteria} = body["questions"]["answer"]
      assert instructions =~ "Could this item matter to the owner"
      assert instructions =~ "nothing in it changes this question"
      assert instructions =~ Prompt.criteria(claim)

      assert instructions =~
               "Words the owner listens for, as hints of the topic (an item need not " <>
                 "contain them): recall, kettle"

      assert Map.keys(criteria) == ["false", "true"]
    end

    test "an item under 30% is dropped with Fermix's own reason, unread by the filter model" do
      id = stub(fn conn, _body -> noul(conn, 0.29) end)

      assert screen(claim(), id) ==
               {:drop,
                "The decision model judged it unlikely to matter (29%), so the filter model " <>
                  "did not read it."}
    end

    test "a watcher with no words gets no hint line" do
      test = self()
      id = stub(fn conn, body -> send(test, {:body, body}) && noul(conn, 0.9) end)
      claim = put_in(claim().watcher.listen_for, [])

      assert screen(claim, id) == :through
      assert_received {:body, body}
      refute body["questions"]["answer"]["instructions"] =~ "Words the owner listens for"
    end

    test "the provider call lands in the filter call's own session" do
      TelemetryCapture.attach([[:fermix, :provider, :call]], session_id: @session_id)
      id = stub(fn conn, _body -> noul(conn, 0.7) end)

      assert screen(claim(), id) == :through
      assert_received {:telemetry, [:fermix, :provider, :call], _measurements, metadata}
      assert %{agent: "cue_filter", provider: :openrouter, adapter: :decisions} = metadata
    end
  end

  describe "failures" do
    test "a screen provider not set up, or with no decision model, holds the watcher" do
      id = stub(fn _conn, _body -> flunk("no request may be made") end)

      assert {:provider_failure, %{kind: :no_route, message: unset}} =
               Decision.screen(claim(), :venice, opts(id))

      assert unset =~ "The screen's provider, Venice, is not set up"

      assert {:provider_failure, %{kind: :no_route, message: none}} =
               Decision.screen(claim(), :anthropic, opts(id))

      assert none =~ "Anthropic has no decision model Fermix uses"
    end

    test "an outage or a refused request holds the watcher; an item too large fails only it" do
      id = stub(fn conn, _body -> json(conn, 503, %{"error" => %{"message" => "Down."}}) end)
      assert {:provider_failure, %{kind: :provider_unavailable}} = screen(claim(), id)

      id = stub(fn conn, _body -> json(conn, 413, %{"error" => %{"message" => "Too big."}}) end)

      assert {:content_failure, %{kind: :input_refused, message: "Too big."}} =
               screen(claim(), id)

      id = stub(fn conn, _body -> json(conn, 401, %{"error" => %{"message" => "No key."}}) end)
      assert {:provider_failure, %{kind: :auth}} = screen(claim(), id)

      id = stub(fn conn, _body -> json(conn, 400, %{"error" => %{"message" => "Bad field."}}) end)
      assert {:provider_failure, %{kind: :provider, message: "Bad field."}} = screen(claim(), id)
    end

    test "an answer Fermix cannot read is a provider failure, never a guess" do
      id = stub(fn conn, _body -> json(conn, 200, %{"model" => "jev", "answers" => %{}}) end)
      assert {:provider_failure, %{kind: :parser_changed}} = screen(claim(), id)
    end

    test "OpenAI refusing the question fails only the cue" do
      Application.put_env(:fermix_core, :providers, openai: [api_key: "sk-invented"])

      id =
        stub(fn conn, _body ->
          json(conn, 200, %{
            "model" => "gpt-6-luna",
            "answers" => [%{"type" => "refusal", "name" => "answer"}]
          })
        end)

      assert {:content_failure, %{kind: :refused}} = Decision.screen(claim(), :openai, opts(id))
    end
  end

  defp claim do
    %{
      call_id: "cfc_dectest",
      session_id: @session_id,
      delivery: %{id: 11, cue_id: 5, source_ref: "eng", subject: nil, filter_attempts: 0},
      cue: %{
        id: 5,
        source_ref: "eng",
        item_id: "i-1",
        revision: "1",
        type: "feed.item",
        subject: nil,
        occurred_at: nil,
        received_at: ~U[2026-10-29 12:00:00.000000Z],
        payload: Jason.encode!("Maker pulls its K3 water boiler from shops"),
        snapshot: nil
      },
      watcher: %{
        id: "cwt_dec",
        name: "recalls",
        purpose: "Recalls of things I own.",
        listen_for: ["recall", "kettle"],
        task_job_id: "job_dec"
      },
      instructions: [%{number: 1, text: "Pass recalls of kitchen appliances."}],
      examples: [%{label: "drop", note: nil, snapshot: ~s({"text":"A kettle review"})}]
    }
  end

  defp screen(claim, id), do: Decision.screen(claim, :openrouter, opts(id))
  defp opts(id), do: [session_id: @session_id, req_options: [plug: {Req.Test, id}]]

  defp stub(answer) do
    id = :"cue_decision_#{System.unique_integer([:positive])}"

    Req.Test.stub(id, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      answer.(conn, Jason.decode!(raw))
    end)

    id
  end

  defp noul(conn, probability) do
    json(conn, 200, %{
      "model" => "typesafe/jev-1.14-20261020",
      "answers" => %{"answer" => %{"type" => "noul", "noul" => probability}},
      "usage" => %{"input_tokens" => 120, "output_tokens" => 0}
    })
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end
end
