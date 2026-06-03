defmodule FermixCore.Agents.UltraOrchestrator do
  @moduledoc """
  Fixed-topology orchestrator for `/ultra` (§17.11).

  A four-stage Elixir pipeline — **decompose → fan out → verify → synthesize** —
  where the plan and all intermediate results live in Elixir variables, never in
  a single growing LLM context. That is what lets a wide fan-out scale past one
  model's context window, and it makes verification *structural* (guaranteed by
  the topology, not hoped for from a prompt).

  The LLM stages and the parallel fan-out are injected as `deps` functions, so
  the pipeline is fully testable and route/provider resolution stays with the
  caller (`TurnRunner`). The orchestrator owns only the topology, the stage
  ordering, the progress narration, and the verify-then-synthesize discipline.

  `decompose` may instead return `{:clarify, questions}`: if the task is too
  ambiguous to scope, the turn ends with clarifying questions *before* spending
  on the fan-out (clarify-before-fanout, foreground only).
  """

  @type subtask :: %{required(:id) => String.t(), required(:task) => String.t()}
  @type finding :: %{required(:id) => String.t(), required(:output) => String.t()}

  @type deps :: %{
          required(:decompose) => (String.t() -> {:fanout, [subtask()]} | {:clarify, String.t()}),
          required(:fanout) => ([subtask()] -> [finding()]),
          required(:verify) => (finding() -> boolean()),
          required(:synthesize) => (String.t(), [finding()] -> String.t()),
          optional(:deliver) => (term() -> any())
        }

  @spec run(String.t(), deps()) :: {:ok, String.t()}
  def run(prompt, deps) when is_binary(prompt) and is_map(deps) do
    deliver = Map.get(deps, :deliver, fn _part -> :ok end)

    progress(deliver, "🧭 Planning — decomposing into independent subtasks…")

    case deps.decompose.(prompt) do
      {:clarify, questions} ->
        # Too ambiguous to scope: end the turn with questions, no fan-out spend.
        {:ok, questions}

      {:fanout, []} ->
        {:ok, deps.synthesize.(prompt, [])}

      {:fanout, subtasks} ->
        run_pipeline(prompt, subtasks, deps, deliver)
    end
  end

  defp run_pipeline(prompt, subtasks, deps, deliver) do
    progress(deliver, "⚡ Running #{length(subtasks)} subtasks in parallel…")
    findings = deps.fanout.(subtasks)

    progress(deliver, "🔎 Verifying #{length(findings)} findings…")
    verified = Enum.filter(findings, &deps.verify.(&1))

    progress(
      deliver,
      "🧩 Synthesizing #{length(verified)} verified finding(s) " <>
        "(#{length(findings) - length(verified)} dropped)…"
    )

    {:ok, deps.synthesize.(prompt, verified)}
  end

  defp progress(deliver, text) when is_function(deliver, 1), do: deliver.({:text, text})
end
