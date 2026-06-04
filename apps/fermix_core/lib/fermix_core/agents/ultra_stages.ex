defmodule FermixCore.Agents.UltraStages do
  @moduledoc """
  Pure stage logic for the `/ultra` orchestrator (§17.11): the per-stage system
  prompts and the parsers that turn raw LLM/subagent output into the typed shapes
  `UltraOrchestrator` expects. Kept separate from `TurnRunner` (which owns the
  route resolution and the actual `adapter.chat` / `Subagents` calls) so the
  parsing — the fragile part — is unit-testable without a provider.
  """

  @type subtask :: %{id: String.t(), task: String.t()}
  @type finding :: %{id: String.t(), output: String.t()}

  @doc """
  Parse the decompose stage's raw text into the orchestrator's contract:
  `{:fanout, subtasks}` or `{:clarify, question}`.

  Accepts a JSON array of `{"id","task"}` (tolerating prose around it), or a line
  beginning `CLARIFY:`. Defensive: a malformed/empty response degrades to a single
  subtask (the whole prompt) so it can never crash the turn.
  """
  @spec parse_decomposition(String.t(), String.t(), pos_integer()) ::
          {:fanout, [subtask()]} | {:clarify, String.t()}
  def parse_decomposition(text, prompt, max_subtasks)
      when is_binary(text) and is_binary(prompt) and is_integer(max_subtasks) and
             max_subtasks > 0 do
    trimmed = String.trim(text)

    if String.starts_with?(trimmed, "CLARIFY:") do
      {:clarify, trimmed |> String.replace_prefix("CLARIFY:", "") |> String.trim()}
    else
      case decode_subtasks(trimmed) do
        [] -> {:fanout, [%{id: "1", task: prompt}]}
        subtasks -> {:fanout, Enum.take(subtasks, max_subtasks)}
      end
    end
  end

  @doc "Parse the subagents fan-out JSON output into findings."
  @spec parse_findings(String.t()) :: [finding()]
  def parse_findings(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{"results" => results}} when is_list(results) ->
        Enum.map(results, fn r ->
          %{
            id: to_string(Map.get(r, "id", "")),
            output: to_string(Map.get(r, "output") || Map.get(r, "error") || "")
          }
        end)

      _other ->
        []
    end
  end

  @doc """
  Whether the verify stage's answer keeps the finding. The verify prompt asks for a
  one-word yes/no; we keep a finding only when the answer carries an affirmative
  verdict AND no explicit negation. A bare keyword match wrongly kept negated forms
  like "not supported" or "no, this is not valid" (the word still matched), letting
  refuted findings reach synthesis. Bare "no" is not treated as a flip token (it is
  common in affirmative phrasing like "no issues"); the affirmative-keyword
  requirement already drops a plain "no" answer.
  """
  @spec verified?(String.t()) :: boolean()
  def verified?(text) when is_binary(text) do
    normalized = String.downcase(text)
    affirmative?(normalized) and not negated?(normalized)
  end

  defp affirmative?(text), do: Regex.match?(~r/\b(yes|supported|true|valid|keep)\b/, text)

  # Explicit negations that flip a verdict: "not"/"never"/"cannot", the "n't"
  # contraction, and negative verdict words. Deliberately excludes a bare "no".
  defp negated?(text) do
    Regex.match?(
      ~r/\b(not|never|cannot|unsupported|unverified|invalid|untrue|insufficient|reject|drop)\b|n't/,
      text
    )
  end

  @doc """
  User content for the synthesize stage. Tags each finding with its probe id and
  caps each finding's output at `max_finding_bytes` so a wide fan-out (e.g. /ultra
  at 50 probes) cannot blow the synthesis model's context window. The per-worker
  result budget already bounds raw output; this is the tighter synthesis-input cap.
  """
  @spec synthesize_user(String.t(), [finding()], pos_integer()) :: String.t()
  def synthesize_user(prompt, verified, max_finding_bytes)
      when is_integer(max_finding_bytes) and max_finding_bytes > 0 do
    findings =
      Enum.map_join(verified, "\n\n", fn f ->
        "- [#{f.id}] #{truncate_bytes(f.output, max_finding_bytes)}"
      end)

    "Original request:\n#{prompt}\n\nVerified findings:\n#{findings}"
  end

  @spec decompose_system(pos_integer()) :: String.t()
  def decompose_system(max_subtasks) when is_integer(max_subtasks) and max_subtasks > 0 do
    """
    You are the planning stage of a fixed-topology orchestrator. The coordinator
    (the main agent) owns all judgment, comparison, and synthesis; your only job is
    to design the parallel work that gathers the raw material it will reason over.

    Break the request into independent PROBES that run concurrently. A probe is a
    narrow, fully self-contained task one worker can finish in a few steps and
    return as evidence — not a whole subsystem to own end to end. Favor breadth:
    when a dimension of the request is worth exploring, fan it into several probes
    that differ only in their angle or criteria — different filters, sources,
    candidates, segments, hypotheses, or constraints — so the coordinator gets
    parallel results to compare. Many narrow probes beat a few broad ones; workers
    may be small models, so each probe must be specific enough to execute with no
    further planning and must state exactly what to return.

    Respond with ONLY a JSON array of objects, each
    {"id": "<short>", "task": "<one self-contained instruction, including what to return>"}.
    Use at most #{max_subtasks} probes; merge any that would return the same
    evidence. If the request is too ambiguous to scope, instead respond with a
    single line beginning "CLARIFY:" followed by the question(s) you need answered.
    """
    |> String.trim()
  end

  @spec verify_system() :: String.t()
  def verify_system do
    """
    You are the verification stage. Given a finding from a subagent, decide whether
    it is well-supported and trustworthy enough to include in the final answer.
    Answer with a single word: "yes" to keep it, "no" to drop it.
    """
    |> String.trim()
  end

  @spec synthesize_system() :: String.t()
  def synthesize_system do
    """
    You are the synthesis stage — the coordinator. You are given the original
    request and the verified findings from the parallel probes, each tagged with
    its probe id. The probes only gathered evidence; the reasoning is yours.
    Compare the findings across probes, resolve conflicts, select the
    best-supported answer, and compose one coherent response to the original
    request. Use only the verified findings — do not invent facts they do not
    contain — and state any gaps the probes did not cover.
    """
    |> String.trim()
  end

  defp decode_subtasks(text) do
    with {:ok, list} when is_list(list) <- Jason.decode(extract_json_array(text)) do
      list
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {item, i} -> subtask_from(item, i) end)
    else
      _other -> []
    end
  end

  defp subtask_from(%{"task" => task} = item, index) when is_binary(task) and task != "" do
    [%{id: to_string(Map.get(item, "id", index)), task: task}]
  end

  defp subtask_from(_item, _index), do: []

  # Tolerate prose wrapped around the JSON array (models often add it).
  defp extract_json_array(text) do
    case Regex.run(~r/\[.*\]/s, text) do
      [json] -> json
      _other -> text
    end
  end

  defp truncate_bytes(text, max) when is_binary(text) do
    if byte_size(text) > max, do: valid_prefix(binary_part(text, 0, max)), else: text
  end

  defp truncate_bytes(other, _max), do: to_string(other)

  # Trim trailing bytes (≤3 for UTF-8) so a multibyte char split at the byte
  # budget does not leave an invalid sequence.
  defp valid_prefix(binary) do
    if String.valid?(binary),
      do: binary,
      else: valid_prefix(binary_part(binary, 0, byte_size(binary) - 1))
  end
end
