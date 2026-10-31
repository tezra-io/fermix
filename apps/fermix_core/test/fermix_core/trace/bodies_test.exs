defmodule FermixCore.Trace.BodiesTest do
  @moduledoc """
  On an Always On server a trace keeps less (M75 L20): a record that carries a
  body (a prompt, a reply, a tool's input or output) is written whole to the
  day's `<type>.bodies.jsonl` and without its bodies to `<type>.jsonl`, and a
  retention pass removes the bodies files of every day before yesterday while
  the records stay 14 days. Everywhere else a record is written whole to
  `<type>.jsonl` and kept 14 days, as before. The clock is injected, so no test
  reads it, and every tree is a test-marked temporary directory.
  """

  use ExUnit.Case, async: true

  alias FermixCore.Trace
  alias FermixTestSupport.SafeRm

  @day ~D[2026-10-30]
  @turn %{
    event: "turn_complete",
    session_id: "main-7",
    input: "Plan the Lisbon trip for the Okafor twins",
    output: "Here is a plan for three days."
  }
  @call %{provider: :anthropic, status: :ok, tokens: %{prompt: 1200, completion: 80}}

  setup do
    base = SafeRm.make_tmp_dir!("trace-bodies")
    on_exit(fn -> SafeRm.rm_rf!(base) end)
    clock = start_supervised!({Agent, fn -> @day end})
    %{base: base, clock: clock}
  end

  defp start_trace(base, clock, separate_bodies) do
    name = :"trace_bodies_#{System.unique_integer([:positive])}"

    opts = [
      base_dir: base,
      name: name,
      today: fn -> Agent.get(clock, & &1) end,
      timer_enabled: false,
      separate_bodies: separate_bodies
    ]

    start_supervised!({Trace, opts})
    name
  end

  defp rows(base, date, file) do
    path = Path.join([base, Date.to_iso8601(date), file])

    case File.read(path) do
      {:ok, text} -> text |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
      {:error, :enoent} -> :absent
    end
  end

  defp pass(name, clock, date) do
    Agent.update(clock, fn _ -> date end)
    send(Process.whereis(name), :retention)
    :sys.get_state(name)
  end

  describe "writing on a server" do
    test "a record with bodies is written whole to the bodies file and without them to its own",
         %{base: base, clock: clock} do
      name = start_trace(base, clock, true)
      Trace.record(:agent_event, "main", @turn, server: name)
      :sys.get_state(name)

      assert [record] = rows(base, @day, "agent_event.jsonl")
      assert record["event"] == "turn_complete"
      assert record["session_id"] == "main-7"
      refute Map.has_key?(record, "input")
      refute Map.has_key?(record, "output")

      assert [whole] = rows(base, @day, "agent_event.bodies.jsonl")
      assert whole["input"] == @turn.input
      assert whole["output"] == @turn.output
      assert Map.delete(whole, "input") |> Map.delete("output") == record
    end

    test "every body field goes to the bodies file; the metadata stays with the record",
         %{base: base, clock: clock} do
      name = start_trace(base, clock, true)

      bodies = %{
        input: "the arguments",
        output: "the result",
        task_summary: "Compare two flats in Porto",
        query: "flats near the river",
        content: "Call the landlord at noon",
        context: "%{job: :rent_check}"
      }

      Trace.record(:tool_exec, "main", Map.merge(%{tool: "shell", success: true}, bodies),
        server: name
      )

      :sys.get_state(name)

      assert [record] = rows(base, @day, "tool_exec.jsonl")

      assert Map.take(record, ["tool", "success", "type", "agent"]) == %{
               "tool" => "shell",
               "success" => true,
               "type" => "tool_exec",
               "agent" => "main"
             }

      assert Map.keys(record) -- ["tool", "success", "type", "agent", "ts"] == []
      assert Enum.sort(Trace.body_keys()) == Enum.sort(Enum.map(Map.keys(bodies), &to_string/1))
    end

    test "a record without bodies is written once, to its own file", %{base: base, clock: clock} do
      name = start_trace(base, clock, true)
      Trace.record(:llm_call, "main", @call, server: name)
      :sys.get_state(name)

      assert [%{"provider" => "anthropic"}] = rows(base, @day, "llm_call.jsonl")
      assert rows(base, @day, "llm_call.bodies.jsonl") == :absent
    end
  end

  test "anywhere else a record is written whole to its own file, and no bodies file",
       %{base: base, clock: clock} do
    name = start_trace(base, clock, false)
    Trace.record(:agent_event, "main", @turn, server: name)
    :sys.get_state(name)

    assert [%{"input" => input, "output" => output}] = rows(base, @day, "agent_event.jsonl")
    assert {input, output} == {@turn.input, @turn.output}
    assert rows(base, @day, "agent_event.bodies.jsonl") == :absent
  end

  test "a server keeps bodies through yesterday, and the records 14 days",
       %{base: base, clock: clock} do
    name = start_trace(base, clock, true)
    Trace.record(:agent_event, "main", @turn, server: name)
    Trace.record(:llm_call, "main", Map.put(@call, :output, "Three days."), server: name)
    # Written on the day before the clock moves on.
    :sys.get_state(name)

    pass(name, clock, Date.add(@day, 1))
    assert [%{"input" => _}] = rows(base, @day, "agent_event.bodies.jsonl")
    assert [%{"output" => _}] = rows(base, @day, "llm_call.bodies.jsonl")

    pass(name, clock, Date.add(@day, 2))
    assert rows(base, @day, "agent_event.bodies.jsonl") == :absent
    assert rows(base, @day, "llm_call.bodies.jsonl") == :absent

    assert [%{"event" => "turn_complete", "session_id" => "main-7"}] =
             rows(base, @day, "agent_event.jsonl")

    assert [%{"provider" => "anthropic", "tokens" => %{"prompt" => 1200}}] =
             rows(base, @day, "llm_call.jsonl")

    pass(name, clock, Date.add(@day, 14))
    assert [_record] = rows(base, @day, "agent_event.jsonl")

    pass(name, clock, Date.add(@day, 15))
    refute File.exists?(Path.join(base, Date.to_iso8601(@day)))
  end

  test "anywhere else the whole record, bodies included, is kept 14 days",
       %{base: base, clock: clock} do
    name = start_trace(base, clock, false)
    Trace.record(:agent_event, "main", @turn, server: name)
    :sys.get_state(name)

    pass(name, clock, Date.add(@day, 2))
    assert [%{"input" => _, "output" => _}] = rows(base, @day, "agent_event.jsonl")

    pass(name, clock, Date.add(@day, 14))
    assert [%{"input" => _, "output" => _}] = rows(base, @day, "agent_event.jsonl")

    pass(name, clock, Date.add(@day, 15))
    refute File.exists?(Path.join(base, Date.to_iso8601(@day)))
  end
end
