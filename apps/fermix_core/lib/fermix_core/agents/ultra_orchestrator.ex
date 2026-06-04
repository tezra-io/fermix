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

  require Logger

  @type subtask :: %{required(:id) => String.t(), required(:task) => String.t()}
  @type finding :: %{required(:id) => String.t(), required(:output) => String.t()}

  @type decomposition :: {:fanout, [subtask()]} | {:clarify, String.t()} | {:error, term()}

  @type deps :: %{
          required(:decompose) => (String.t() -> decomposition()),
          required(:fanout) => ([subtask()] -> [finding()]),
          required(:verify) => (finding() -> boolean()),
          required(:synthesize) => (String.t(), [finding()] ->
                                      {:ok, String.t()} | {:error, term()}),
          optional(:verify_concurrency) => pos_integer(),
          optional(:deliver) => (term() -> any())
        }

  @spec run(String.t(), deps()) :: {:ok, String.t()} | {:error, term()}
  def run(prompt, deps) when is_binary(prompt) and is_map(deps) do
    deliver = Map.get(deps, :deliver, fn _part -> :ok end)

    progress(deliver, "🧭 Planning — decomposing into independent subtasks…")

    case deps.decompose.(prompt) do
      {:clarify, questions} ->
        # Too ambiguous to scope: end the turn with questions, no fan-out spend.
        {:ok, questions}

      {:error, reason} ->
        # A decompose provider/auth failure surfaces as an error (→ error_reply),
        # not an empty success — the caller must not deliver a blank turn.
        {:error, reason}

      {:fanout, []} ->
        deps.synthesize.(prompt, [])

      {:fanout, subtasks} ->
        run_pipeline(prompt, subtasks, deps, deliver)
    end
  end

  defp run_pipeline(prompt, subtasks, deps, deliver) do
    progress(deliver, "⚡ Running #{length(subtasks)} subtasks in parallel…")
    findings = deps.fanout.(subtasks)

    progress(deliver, "🔎 Verifying #{length(findings)} findings…")
    verified = verify_findings(findings, deps)

    progress(
      deliver,
      "🧩 Synthesizing #{length(verified)} verified finding(s) " <>
        "(#{length(findings) - length(verified)} dropped)…"
    )

    # Returns {:ok, answer} | {:error, reason}; a synthesis provider/auth failure
    # propagates rather than collapsing to an empty answer.
    deps.synthesize.(prompt, verified)
  end

  # Verify each finding, keeping only those the verifier accepts. One code path:
  # `Task.async_stream` at the configured concurrency — `verify_concurrency` of 1
  # (the default) is sequential. A wide fan-out (e.g. /ultra at 50) would otherwise
  # pay one verify round-trip per finding in series. `ordered: true` preserves probe
  # order into synthesis. Crash handling is in `safe_verify/2`.
  defp verify_findings(findings, deps) do
    concurrency = Map.get(deps, :verify_concurrency, 1)

    findings
    |> Task.async_stream(fn finding -> {finding, safe_verify(deps, finding)} end,
      max_concurrency: concurrency,
      ordered: true,
      timeout: :infinity
    )
    |> Enum.flat_map(fn
      {:ok, {finding, true}} -> [finding]
      {:ok, {_finding, false}} -> []
      {:exit, reason} -> log_verify_exit(reason)
    end)
  end

  # A verify that raises drops the finding (unverified ⇒ excluded) and is logged,
  # never silently swallowed. Rescuing INSIDE the task is what makes that true: the
  # `Task.async_stream` tasks are linked to this coordinator, so an unrescued raise
  # would propagate a linked EXIT and crash the whole /ultra turn. Rescuing here
  # contains it to one finding, while a genuine coordinator kill (/stop) still
  # reaps these linked tasks.
  defp safe_verify(deps, finding) do
    deps.verify.(finding)
  rescue
    error ->
      Logger.warning("ultra verify raised, dropping finding: #{Exception.message(error)}")
      false
  end

  defp log_verify_exit(reason) do
    Logger.warning("ultra verify task exited, dropping finding: #{inspect(reason)}")
    []
  end

  defp progress(deliver, text) when is_function(deliver, 1), do: deliver.({:text, text})
end
