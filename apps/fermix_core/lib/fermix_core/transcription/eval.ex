defmodule FermixCore.Transcription.Eval do
  @moduledoc """
  Live end-to-end transcription eval: runs the sample audio fixtures through the
  operator's configured speech-to-text backend(s) and grades each transcript by
  **keyword recall**.

  ## Method

  Each fixture declares a small set of lowercase content keywords drawn from its
  spoken phrase. `grade/2` downcases the transcript, strips punctuation, and
  counts a keyword as *matched* when it appears as a substring of the cleaned
  text. `recall` is `matched / total` and a fixture *passes* when `recall`
  clears the threshold. Recall (not exact-string equality) is the metric because
  every hosted backend punctuates, capitalizes, and word-breaks slightly
  differently — a rigid string match would fail on cosmetics, not content.

  The default pass threshold is `0.8` (`@threshold`); `run/1` accepts a
  `:threshold` override (the `mix fermix.eval.transcription --threshold` flag).

  ## Boundaries

  `grade/2` and `fixtures/0` are pure and deterministic — no I/O — so the
  hermetic suite exercises them without a network. `available_backends/0` reads
  Application env (which backends have a resolvable key) but performs no network
  I/O. Only `run/1` reaches the live STT APIs, so it is intentionally never part
  of `mix test`; the thin `mix fermix.eval.transcription` task is its only caller.

  One fixture's failure is one failing row — a backend error is captured in the
  result's `:error` field, never raised past the run (no fallback backend, no
  silent skip).
  """

  alias FermixCore.Transcription
  alias FermixCore.Transcription.Registry

  @threshold 0.8

  @fixtures [
    %{
      file: "pangram.mp3",
      phrase: "The quick brown fox jumps over the lazy dog.",
      keywords: ~w(quick brown fox jumps lazy dog)
    },
    %{
      file: "privacy.mp3",
      phrase: "This assistant runs entirely on your own computer and keeps your data private.",
      keywords: ~w(assistant runs computer data private)
    },
    %{
      file: "reminder.mp3",
      phrase: "Please remind me to call the dentist tomorrow morning at nine.",
      # "nine" is intentionally omitted from the graded keywords: STT engines
      # routinely render it as the digit "9", which would drop recall below
      # threshold on an otherwise-perfect transcript. The remaining words are
      # reliably transcribed as words.
      keywords: ~w(remind call dentist tomorrow morning)
    }
  ]

  @typedoc "A single fixture: audio file, resolved on-disk path, spoken phrase, and content keywords."
  @type fixture :: %{
          file: String.t(),
          path: String.t(),
          phrase: String.t(),
          keywords: [String.t()]
        }

  @typedoc "The graded outcome for one keyword set."
  @type grade :: %{
          recall: float(),
          matched: [String.t()],
          missing: [String.t()],
          pass?: boolean()
        }

  @typedoc "One backend × fixture eval row. `transcript`/`error` are mutually exclusive."
  @type result :: %{
          backend: atom(),
          file: String.t(),
          transcript: String.t() | nil,
          recall: float(),
          pass?: boolean(),
          error: term() | nil
        }

  @typedoc "Run tallies: per-backend pass/total, overall pass/total, and the applied threshold."
  @type summary :: %{
          per_backend: %{
            optional(atom()) => %{passed: non_neg_integer(), total: non_neg_integer()}
          },
          passed: non_neg_integer(),
          total: non_neg_integer(),
          threshold: float()
        }

  @doc "The default keyword-recall pass threshold used when `run/1` is given no `:threshold`."
  @spec default_threshold() :: float()
  def default_threshold, do: @threshold

  @doc """
  The fixture manifest with each `:path` resolved under the app's `priv`
  directory. Pure — reads no config and touches no disk.
  """
  @spec fixtures() :: [fixture()]
  def fixtures do
    Enum.map(@fixtures, fn fixture -> Map.put(fixture, :path, fixture_path(fixture.file)) end)
  end

  @doc """
  Grades `transcript` against `keywords` by keyword recall. Case-insensitive:
  the transcript is downcased and stripped of punctuation, then each (downcased)
  keyword is matched as a substring. Pure and deterministic.
  """
  @spec grade(String.t(), [String.t()]) :: grade()
  def grade(transcript, keywords)
      when is_binary(transcript) and is_list(keywords) and keywords != [] do
    cleaned = normalize_transcript(transcript)
    {matched, missing} = Enum.split_with(keywords, &keyword_present?(cleaned, &1))
    recall = length(matched) / length(keywords)

    %{recall: recall, matched: matched, missing: missing, pass?: recall >= @threshold}
  end

  @doc """
  The shipped backends whose credential resolves right now (`configured?([]) ==
  :ok`), in name order. Empty when none is configured — the eval then SKIPs.
  Reads Application env only; no network I/O.
  """
  @spec available_backends() :: [{atom(), module()}]
  def available_backends do
    Enum.filter(Registry.backends(), fn {_name, module} -> module.configured?([]) == :ok end)
  end

  @doc """
  Transcribes every fixture through every available backend (or only
  `opts[:backend]` when given as an atom) and grades each transcript.

  Options:
    * `:backend` — restrict the run to this backend name atom.
    * `:threshold` — pass threshold in `[0, 1]`; defaults to `default_threshold/0`.

  Each fixture is one row: a `{:error, reason}` from a backend becomes a failing
  row with `:error` set (never a raised run). Bounded by the backend's own
  `TimeoutPolicy` receive timeout — no unbounded loops here.
  """
  @spec run(keyword()) :: %{results: [result()], summary: summary()}
  def run(opts \\ []) when is_list(opts) do
    threshold = validate_threshold(Keyword.get(opts, :threshold, @threshold))
    backends = selected_backends(Keyword.get(opts, :backend))

    results =
      for {name, module} <- backends,
          fixture <- fixtures(),
          do: eval_fixture(name, module, fixture, threshold)

    %{results: results, summary: summarize(results, backends, threshold)}
  end

  defp selected_backends(nil), do: available_backends()

  defp selected_backends(backend) when is_atom(backend) do
    Enum.filter(available_backends(), fn {name, _module} -> name == backend end)
  end

  defp eval_fixture(name, module, %{path: path, file: file, keywords: keywords}, threshold) do
    case Transcription.transcribe(path, backend: module) do
      {:ok, transcript} ->
        recall = grade(transcript, keywords).recall

        %{
          backend: name,
          file: file,
          transcript: transcript,
          recall: recall,
          pass?: recall >= threshold,
          error: nil
        }

      {:error, reason} ->
        %{backend: name, file: file, transcript: nil, recall: 0.0, pass?: false, error: reason}
    end
  end

  defp summarize(results, backends, threshold) do
    per_backend =
      Map.new(backends, fn {name, _module} ->
        rows = Enum.filter(results, &(&1.backend == name))
        {name, %{passed: Enum.count(rows, & &1.pass?), total: length(rows)}}
      end)

    %{
      per_backend: per_backend,
      passed: Enum.count(results, & &1.pass?),
      total: length(results),
      threshold: threshold
    }
  end

  defp fixture_path(file) do
    Application.app_dir(:fermix_core, "priv/eval/transcription/#{file}")
  end

  defp normalize_transcript(transcript) do
    transcript
    |> String.downcase()
    |> String.replace(~r/[[:punct:]]/u, "")
  end

  defp keyword_present?(cleaned, keyword) do
    String.contains?(cleaned, String.downcase(keyword))
  end

  defp validate_threshold(value) when is_number(value) and value >= 0 and value <= 1,
    do: value / 1

  defp validate_threshold(value) do
    raise ArgumentError, "threshold must be a number in [0, 1], got: #{inspect(value)}"
  end
end
