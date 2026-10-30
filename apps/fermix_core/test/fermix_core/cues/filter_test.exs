defmodule FermixCore.Cues.FilterTest do
  # async: false — the screen setting and the routes are the shared
  # `[fermix_core.cues]` and `[fermix_core.providers]` app env (established
  # here, restored on exit).
  use ExUnit.Case, async: false

  alias FermixCore.Cues.Filter

  # The filter model's adapter: tells the test it was asked, and passes.
  defmodule ChatAdapter do
    @moduledoc false

    def chat(_messages, [], opts) do
      send(Keyword.fetch!(opts, :test_pid), :chat_asked)

      {:ok,
       %{
         content: ~s({"decision":"pass","reason":"A release.","hint":"New version."}),
         tool_calls: [],
         provider_state: nil,
         usage: %{prompt_tokens: 1, completion_tokens: 1, total_tokens: 2},
         model: "stub-model"
       }}
    end
  end

  setup do
    saved = Map.new([:cues, :providers, :routing], &{&1, Application.get_env(:fermix_core, &1)})

    on_exit(fn ->
      Enum.each(saved, fn
        {key, nil} -> Application.delete_env(:fermix_core, key)
        {key, value} -> Application.put_env(:fermix_core, key, value)
      end)
    end)

    Application.put_env(:fermix_core, :routing,
      filter_provider: "openai",
      filter_model: "gpt-5.4-mini"
    )

    Application.put_env(:fermix_core, :providers, openai: [api_key: "sk-invented", primary: true])
    :ok
  end

  test "with words as the screen, the filter model reads the item and no decision model is asked" do
    Application.put_env(:fermix_core, :cues, enabled: true)
    stub(fn _conn -> flunk("the decision model was asked") end)

    assert {:pass, "A release.", "New version."} = Filter.decide(claim(), opts())
    assert_received :chat_asked
  end

  test "an item the decision model lets through goes on to the filter model" do
    Application.put_env(:fermix_core, :cues, enabled: true, screen_provider: "openai")
    stub(&predicate(&1, 0.62))

    assert {:pass, "A release.", "New version."} = Filter.decide(claim(), opts())
    assert_received {:asked, "/v1/decisions"}
    assert_received :chat_asked
  end

  test "an item the decision model screens out never reaches the filter model" do
    Application.put_env(:fermix_core, :cues, enabled: true, screen_provider: "openai")
    stub(&predicate(&1, 0.05))

    assert {:drop, reason} = Filter.decide(claim(), opts())
    assert reason =~ "judged it unlikely to matter (5%)"
    assert_received {:asked, "/v1/decisions"}
    refute_received :chat_asked
  end

  defp stub(answer) do
    test = self()

    Req.Test.stub(:cue_filter_screen, fn conn ->
      send(test, {:asked, conn.request_path})
      answer.(conn)
    end)
  end

  defp predicate(conn, probability) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(
      200,
      Jason.encode!(%{
        "model" => "gpt-6-luna",
        "answers" => [%{"type" => "predicate", "name" => "answer", "probability" => probability}]
      })
    )
  end

  defp opts do
    [
      session_id: "cue_filter_cwt_sw_20261029_120000_a1b2c3",
      req_options: [plug: {Req.Test, :cue_filter_screen}],
      adapter: ChatAdapter,
      adapter_opts: [test_pid: self()],
      retry_delay_fn: fn _ms -> :ok end
    ]
  end

  defp claim do
    %{
      call_id: "cfc_screen",
      session_id: "cue_filter_cwt_sw_20261029_120000_a1b2c3",
      cue: %{
        source_ref: "eng",
        type: "feed.item",
        subject: nil,
        occurred_at: nil,
        received_at: ~U[2026-10-29 12:00:00.000000Z],
        payload: Jason.encode!("A release")
      },
      watcher: %{id: "cwt_sw", name: "eng-news", purpose: "Releases.", listen_for: ["release"]},
      instructions: [],
      examples: []
    }
  end
end
