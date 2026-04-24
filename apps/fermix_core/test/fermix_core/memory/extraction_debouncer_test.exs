defmodule FermixCore.Memory.ExtractionDebouncerTest do
  use ExUnit.Case, async: false

  alias FermixCore.Memory.ExtractionDebouncer

  defmodule TestExtractor do
    def extract(opts) do
      send(Keyword.fetch!(opts, :test_pid), {:extracted, opts})
      Keyword.get(opts, :result, {:ok, %{}})
    end
  end

  setup do
    task_supervisor =
      start_supervised!(
        {Task.Supervisor, name: :"extraction_debounce_task_#{System.unique_integer([:positive])}"}
      )

    debouncer =
      start_supervised!(
        {ExtractionDebouncer,
         [
           name: :"extraction_debouncer_#{System.unique_integer([:positive])}",
           task_supervisor: task_supervisor,
           extractor_module: TestExtractor,
           extraction_debounce_ms: 120
         ]}
      )

    %{debouncer: debouncer}
  end

  test "coalesces rapid requests for one agent conversation into the latest extraction", %{
    debouncer: debouncer
  } do
    assert :ok = request_extract(debouncer, "first")
    Process.sleep(20)
    assert :ok = request_extract(debouncer, "second")

    refute_receive {:extracted, _opts}, 70
    assert_receive {:extracted, opts}, 500
    refute_receive {:extracted, _opts}, 80

    assert Keyword.fetch!(opts, :messages) == [%{role: "user", content: "second"}]
    assert Keyword.fetch!(opts, :conversation_key) == {"telegram", "chat_1", :root}
  end

  test "does not coalesce different conversations", %{debouncer: debouncer} do
    assert :ok = request_extract(debouncer, "first", {"telegram", "chat_1", :root})
    assert :ok = request_extract(debouncer, "second", {"telegram", "chat_2", :root})

    assert_receive {:extracted, opts_a}, 500
    assert_receive {:extracted, opts_b}, 500

    conversations =
      [opts_a, opts_b]
      |> Enum.map(&Keyword.fetch!(&1, :conversation_key))
      |> Enum.sort()

    assert conversations == [
             {"telegram", "chat_1", :root},
             {"telegram", "chat_2", :root}
           ]
  end

  defp request_extract(debouncer, content, conversation_key \\ {"telegram", "chat_1", :root}) do
    ExtractionDebouncer.request(
      [
        provider: __MODULE__,
        messages: [%{role: "user", content: content}],
        agent_id: "main",
        owner_id: "default",
        conversation_key: conversation_key,
        chat_mode: :direct,
        memory_store: __MODULE__,
        scheduler: __MODULE__,
        repo: __MODULE__,
        test_pid: self()
      ],
      server: debouncer
    )
  end
end
