defmodule Mix.Tasks.FermixBenchTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Fermix.Bench, as: BenchTask

  test "mix task writes the requested report" do
    Mix.Task.clear()
    dir = FermixTestSupport.SafeRm.make_tmp_dir!("fermix-bench-task")
    output = Path.join(dir, "current.json")

    try do
      text =
        capture_io(fn ->
          BenchTask.run([
            "--scenarios=shared_text_minimal",
            "--samples=1",
            "--warmup=0",
            "--output=#{output}"
          ])
        end)

      assert text =~ "shared_text_minimal"
      assert before?(text, "  dispatcher_normalize:", "  ingress_authorize:")
      assert before?(text, "  ingress_authorize:", "  agent_mailbox:")
      assert File.exists?(output)

      assert %{"scenarios" => %{"shared_text_minimal" => _scenario}} =
               Jason.decode!(File.read!(output))
    after
      FermixTestSupport.SafeRm.rm_rf!(dir)
    end
  end

  defp before?(text, left, right) do
    lines = String.split(text, "\n")
    line_index(lines, left) < line_index(lines, right)
  end

  defp line_index(lines, needle), do: Enum.find_index(lines, &String.starts_with?(&1, needle))
end
