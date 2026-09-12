defmodule FermixCore.Memory.CompactorHistoryTaintTest do
  @moduledoc """
  MILESTONE_32 §13.6 — the prior-checkpoint leg of the strict taint: a
  checkpoint row that folded activity-derived content may feed the NEXT
  summarization prompt only when that compaction's route is permitted to carry
  history. Split from `CompactorTest` because these cases mutate the global
  `:computer_history` app env (Gate grants), which async siblings would race.
  """
  use ExUnit.Case, async: false

  alias FermixCore.Memory.Compactor
  alias FermixCore.Memory.Repo
  alias FermixTestSupport.ComputerHistoryCanary

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-compactor-taint-#{unique}.db")
    repo_name = :"compactor_taint_repo_#{unique}"

    start_supervised!({Repo, name: repo_name, enabled: true, database_path: db_path})

    original = Application.get_env(:fermix_core, :computer_history)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:fermix_core, :computer_history)
        value -> Application.put_env(:fermix_core, :computer_history, value)
      end

      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{repo: repo_name}
  end

  defp context(repo) do
    %{
      memory_repo: repo,
      memory_agent_id: "main",
      memory_owner_id: "default",
      conversation_key: {"telegram", "chat-1", :root}
    }
  end

  defp route do
    route_key = %{
      provider: :openai,
      model: "gpt-5.4-mini",
      auth_mode: :api_key,
      base_url: "https://api.openai.com/v1"
    }

    adapter_opts = [
      api_key: "sk-test",
      model: route_key.model,
      base_url: route_key.base_url,
      req_options: [plug: {Req.Test, __MODULE__}]
    ]

    {route_key, adapter_opts}
  end

  defp stub_summary(summary) do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:summary_request, body})

      Req.Test.json(conn, %{
        "model" => "gpt-5.4-mini",
        "output" => [
          %{
            "type" => "message",
            "id" => "msg_summary",
            "content" => [%{"type" => "output_text", "text" => summary}]
          }
        ],
        "usage" => %{"input_tokens" => 9, "output_tokens" => 3}
      })
    end)
  end

  defp seed_tainted_checkpoint(repo, canary) do
    {:ok, _row} =
      Repo.insert_message(
        %{
          agent_id: "main",
          owner_id: "default",
          channel: "telegram",
          chat_id: "chat-1",
          thread_scope: :root,
          sender: "compactor",
          role: "system",
          kind: "checkpoint_summary",
          content: "Earlier: the owner edited #{canary} in Numbers.",
          metadata: %{source: "agent_loop_compaction", history_tainted: true}
        },
        server: repo
      )
  end

  defp compactable_messages do
    [
      %{role: "system", content: "base prompt"},
      %{role: "user", content: String.duplicate("older turn ", 80)},
      %{role: "assistant", content: String.duplicate("older response ", 80)},
      %{role: "user", content: "new turn"}
    ]
  end

  defp compact(repo) do
    Compactor.compact(compactable_messages(),
      enabled: true,
      token_budget: 60,
      route: route(),
      context: context(repo)
    )
  end

  test "a tainted prior checkpoint is DROPPED from the summary prompt on an ungranted route",
       %{repo: repo} do
    # No grants configured: the openai route is an ungranted remote, so the
    # tainted prior must never reach the summarization request body.
    Application.delete_env(:fermix_core, :computer_history)
    canary = ComputerHistoryCanary.token("prior")
    seed_tainted_checkpoint(repo, canary)
    stub_summary("fresh summary")

    assert {:ok, %{compacted?: true} = result} = compact(repo)

    assert_receive {:summary_request, body}
    assert ComputerHistoryCanary.absent?(body, canary)
    refute body =~ "Prior checkpoint summary"

    # The prior was dropped, and the older turns were clean — so the new
    # summary carries no marker.
    assert result.cache.tainted? == false
  end

  test "a tainted prior checkpoint is kept on a granted route and taints the next summary",
       %{repo: repo} do
    Application.put_env(:fermix_core, :computer_history,
      enabled: true,
      summarizer: :local,
      remote_summaries: [:openai]
    )

    canary = ComputerHistoryCanary.token("granted")
    seed_tainted_checkpoint(repo, canary)
    stub_summary("summary over the prior")

    assert {:ok, %{compacted?: true} = result} = compact(repo)

    assert_receive {:summary_request, body}
    assert ComputerHistoryCanary.present?(body, canary)
    assert body =~ "Prior checkpoint summary"

    # The prior fed this summary, so the new summary message carries the
    # marker forward — the taint is transitive across checkpoints.
    assert result.cache.tainted? == true

    summary_message =
      Enum.find(
        result.messages,
        &(&1.role == "system" and &1.content =~ "summary over the prior")
      )

    assert summary_message.history_tainted == true
  end
end
