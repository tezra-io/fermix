defmodule FermixCore.Providers.DecisionModelTest do
  # async: false — the route tests write the shared `[fermix_core.providers]`
  # app env (established here, restored on exit).
  use ExUnit.Case, async: false

  alias FermixCore.Providers.DecisionModel
  alias FermixTestSupport.TelemetryCapture

  @question %{
    instructions: "Is this about a kettle recall?",
    yes: "It is about a kettle recall.",
    no: "It is about something else."
  }

  setup do
    providers = Application.get_env(:fermix_core, :providers, [])

    on_exit(fn ->
      Application.put_env(:fermix_core, :providers, providers)
    end)

    :ok
  end

  describe "pick/2" do
    test "the primary first, when it serves a decision model and is set up" do
      assert DecisionModel.pick({:ok, :venice}, fn _provider -> true end) == {:ok, :venice}
    end

    test "otherwise the first set up, in catalog order" do
      set_up = &(&1 in [:venice, :openrouter])

      assert DecisionModel.pick({:ok, :anthropic}, set_up) == {:ok, :openrouter}
      assert DecisionModel.pick({:ok, :openai}, set_up) == {:ok, :openrouter}
      assert DecisionModel.pick({:error, :multiple_primary}, set_up) == {:ok, :openrouter}
      assert DecisionModel.pick({:ok, :anthropic}, &(&1 == :venice)) == {:ok, :venice}
    end

    test "none set up" do
      assert DecisionModel.pick({:ok, :openai}, fn _provider -> false end) ==
               {:error, :not_set_up}
    end
  end

  describe "route/0" do
    test "a primary that serves one leads, on its own key" do
      Application.put_env(:fermix_core, :providers,
        openai: [api_key: "sk-invented"],
        venice: [api_key: "vn-invented", primary: true]
      )

      assert {:ok, venice} = DecisionModel.route()
      assert venice.model == "jev-latest"
      assert venice.url == "https://api.venice.ai/api/v1/decisions"
      assert venice.api_key == "vn-invented"
    end

    test "under a primary that serves none, the first set up, primary or not" do
      Application.put_env(:fermix_core, :providers,
        anthropic: [api_key: "sk-ant-invented", primary: true],
        venice: [api_key: "vn-invented"],
        openrouter: [api_key: "sk-or-invented"]
      )

      assert {:ok, openrouter} = DecisionModel.route()
      assert openrouter.model == "~typesafe/jev-latest"
      assert openrouter.url == "https://openrouter.ai/api/alpha/decisions"
      assert openrouter.api_key == "sk-or-invented"
    end

    test "OpenAI asks its Decisions API under the provider's own base URL" do
      Application.put_env(:fermix_core, :providers,
        openai: [api_key: "sk-invented", base_url: "https://gw.example.net/v1/"]
      )

      assert {:ok, route} = DecisionModel.route()
      assert {route.provider, route.model} == {:openai, "gpt-6-luna"}
      assert route.url == "https://gw.example.net/v1/decisions"
    end

    test "no provider that serves one set up is no route" do
      Application.put_env(:fermix_core, :providers,
        anthropic: [api_key: "sk-ant-invented", primary: true],
        openrouter: [default_model: "openai/gpt-5.5"]
      )

      assert DecisionModel.route() == {:error, :not_set_up}
    end
  end

  describe "yes_no/4 on Jev" do
    test "OpenRouter gets a noul with criteria, no fallback host and no training" do
      test = self()

      id =
        stub(fn conn, body ->
          send(test, {:request, conn.request_path, auth(conn), body})

          json(conn, 200, %{
            "model" => "typesafe/jev-1.14-20261020",
            "answers" => %{"answer" => %{"type" => "noul", "noul" => 0.87}},
            "usage" => %{"input_tokens" => 412, "output_tokens" => 0, "cost" => 0.00002}
          })
        end)

      assert {:ok, answer} =
               DecisionModel.yes_no(route(:openrouter), "A kettle recall.", @question, opts(id))

      assert answer == %{
               probability: 0.87,
               model: "typesafe/jev-1.14-20261020",
               tokens: %{prompt: 412, completion: 0}
             }

      assert_received {:request, "/api/alpha/decisions", "Bearer sk-or-invented", body}

      assert body == %{
               "model" => "~typesafe/jev-latest",
               "state" => "A kettle recall.",
               "questions" => %{
                 "answer" => %{
                   "type" => "noul",
                   "instructions" => @question.instructions,
                   "criteria" => %{"true" => @question.yes, "false" => @question.no}
                 }
               },
               "provider" => %{"allow_fallbacks" => false, "data_collection" => "deny"}
             }
    end

    test "Venice gets the same noul with no provider preferences" do
      test = self()

      id =
        stub(fn conn, body ->
          send(test, {:request, body})

          json(conn, 200, %{
            "model" => "jev-latest",
            "answers" => %{"answer" => %{"type" => "noul", "noul" => 0}},
            "usage" => %{"input_tokens" => 90, "output_tokens" => 48}
          })
        end)

      assert {:ok, %{probability: +0.0}} =
               DecisionModel.yes_no(route(:venice), "A tide table.", @question, opts(id))

      assert_received {:request, body}
      refute Map.has_key?(body, "provider")
      assert body["questions"]["answer"]["type"] == "noul"
    end

    test "an answer of another shape is parser_changed, never guessed" do
      for answers <- [
            %{"answer" => %{"type" => "choice", "choice" => "yes"}},
            %{"answer" => %{"type" => "noul", "noul" => 1.4}},
            %{"other" => %{"type" => "noul", "noul" => 0.5}}
          ] do
        id =
          stub(fn conn, _body -> json(conn, 200, %{"model" => "jev", "answers" => answers}) end)

        assert {:error, {:parser_changed, sentence}} =
                 DecisionModel.yes_no(route(:openrouter), "x", @question, opts(id))

        assert sentence =~ "OpenRouter's decision model answered in a shape Fermix does not read"
      end
    end
  end

  describe "yes_no/4 on OpenAI" do
    test "asks one predicate, with the criteria in its instructions" do
      test = self()

      id =
        stub(fn conn, body ->
          send(test, {:request, conn.request_path, body})

          json(conn, 200, %{
            "model" => "gpt-6-luna",
            "answers" => [%{"type" => "predicate", "name" => "answer", "probability" => 0.12}],
            "usage" => %{"input_tokens" => 300, "output_tokens" => 0, "total_tokens" => 300}
          })
        end)

      assert {:ok, %{probability: 0.12, model: "gpt-6-luna"}} =
               DecisionModel.yes_no(route(:openai), "A kettle recall.", @question, opts(id))

      assert_received {:request, "/v1/decisions", body}

      assert body == %{
               "model" => "gpt-6-luna",
               "input" => "A kettle recall.",
               "questions" => [
                 %{
                   "type" => "predicate",
                   "name" => "answer",
                   "instructions" =>
                     "Is this about a kettle recall?\n\nYes means: It is about a kettle " <>
                       "recall.\nNo means: It is about something else."
                 }
               ]
             }
    end

    test "a refused question is a refusal" do
      id =
        stub(fn conn, _body ->
          json(conn, 200, %{
            "model" => "gpt-6-luna",
            "answers" => [%{"type" => "refusal", "name" => "answer"}]
          })
        end)

      assert {:error, {:refused, _sentence}} =
               DecisionModel.yes_no(route(:openai), "x", @question, opts(id))
    end
  end

  describe "failures" do
    test "an HTTP failure is a provider error of the decisions adapter" do
      id =
        stub(fn conn, _body ->
          json(conn, 429, %{"error" => %{"message" => "Slow down."}})
        end)

      assert {:error, {:provider_error, error}} =
               DecisionModel.yes_no(route(:openai), "x", @question, opts(id))

      assert %{provider: :openai, adapter: :decisions, status: 429, kind: :rate_limit} = error
      assert error.message =~ "Slow down."
    end

    test "a transport failure is a provider transport error" do
      id = unique_id()
      Req.Test.stub(id, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, {:provider_transport_error, %{kind: :network}}} =
               DecisionModel.yes_no(route(:venice), "x", @question, opts(id))
    end
  end

  describe "telemetry" do
    test "every call is one provider call under the caller's session, without the key" do
      session_id = "cue_filter_cwt_dm_20261029_120000_a1b2c3"
      TelemetryCapture.attach([[:fermix, :provider, :call]], session_id: session_id)

      id =
        stub(fn conn, _body ->
          json(conn, 200, %{
            "model" => "typesafe/jev-1.14-20261020",
            "answers" => %{"answer" => %{"type" => "noul", "noul" => 0.6}},
            "usage" => %{"input_tokens" => 50, "output_tokens" => 0}
          })
        end)

      call_opts = [agent: "cue_filter", session_id: session_id] ++ opts(id)
      assert {:ok, _answer} = DecisionModel.yes_no(route(:openrouter), "x", @question, call_opts)

      assert_received {:telemetry, [:fermix, :provider, :call], %{duration_ms: _}, metadata}

      assert %{
               provider: :openrouter,
               adapter: :decisions,
               model: "typesafe/jev-1.14-20261020",
               status: :ok,
               tokens: %{prompt: 50, completion: 0},
               agent: "cue_filter"
             } = metadata

      refute inspect(metadata) =~ "sk-or-invented"

      id = stub(fn conn, _body -> json(conn, 200, %{"model" => "jev", "answers" => %{}}) end)
      call_opts = [agent: "cue_filter", session_id: session_id] ++ opts(id)

      assert {:error, _changed} =
               DecisionModel.yes_no(route(:openrouter), "x", @question, call_opts)

      assert_received {:telemetry, [:fermix, :provider, :call], _measurements, failed}

      assert %{status: :error, error_kind: :parser_changed, model: "~typesafe/jev-latest"} =
               failed
    end
  end

  defp route(:openrouter) do
    %{
      provider: :openrouter,
      model: "~typesafe/jev-latest",
      url: "https://openrouter.ai/api/alpha/decisions",
      api_key: "sk-or-invented"
    }
  end

  defp route(:venice) do
    %{
      provider: :venice,
      model: "jev-latest",
      url: "https://api.venice.ai/api/v1/decisions",
      api_key: "vn-invented"
    }
  end

  defp route(:openai) do
    %{
      provider: :openai,
      model: "gpt-6-luna",
      url: "https://api.openai.com/v1/decisions",
      api_key: "sk-invented"
    }
  end

  # A stub that hands the test the decoded request body.
  defp stub(answer) do
    id = unique_id()

    Req.Test.stub(id, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      answer.(conn, Jason.decode!(raw))
    end)

    id
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end

  defp auth(conn), do: conn |> Plug.Conn.get_req_header("authorization") |> List.first()
  defp opts(id), do: [req_options: [plug: {Req.Test, id}]]
  defp unique_id, do: :"decision_model_#{System.unique_integer([:positive])}"
end
