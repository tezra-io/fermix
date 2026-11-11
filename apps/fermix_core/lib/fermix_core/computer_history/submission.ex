defmodule FermixCore.ComputerHistory.Submission do
  @moduledoc """
  The home's half of computer history (M97 §8.1): what a machine's finished
  sitting becomes. A machine sends each closed sitting with `history.submit`,
  through the link from a computer (`ComputerHistory.HomeService`) or in
  process on a home that records itself; `accept/3` answers it.

  - **Its text is never written down.** The submitted text lives in this call's
    memory alone: the summarizer reads it, the verbatim guard reads its field
    text (`EventRender.field_texts/1`), and the note is the only thing stored.
    The summarizer's request and reply are kept out of every trace and export
    (`Providers.Telemetry`, M97 D10), and nothing here logs content.
  - **A purged or paused window never gains a note** (§8.5): a sitting of a
    machine that reaches one of its purge or pause intervals, or one of every
    machine's, is refused with those intervals, so the machine applies them
    and sends what is left; the note write checks again in its own transaction
    (`ComputerHistorySql.insert_note/5`), so a purge that lands while the
    summarizer runs refuses it too.
  - **One note per sitting.** A sitting sent again (its answer was lost) is
    answered `summarized` from the note it already made.
  - **The signal gate runs here too** (`Summarizer.signal?/2`): a sitting with
    nothing typed and at most one title is `no_signal`, with no call.
  - A machine that summarizes on its own device sends the note alone, and the
    home stores it under the same checks.

  The answer is `summarized`, `abstained`, `no_signal` or `refused` with its
  reason: `purged` or `paused` (with the intervals to apply), `invalid` (never
  sent again), or `no_summarizer`, `route_not_permitted`,
  `summarizer_unavailable` or `store` (sent again later).

  Options: `:repo`, `:config` (the home's history settings, `Config.current/0`),
  `:now`, and a test's `:adapter` (its provider) and `:route_opts` (what the
  route resolves with).
  """

  require Logger

  alias FermixCore.ComputerHistory.Config
  alias FermixCore.ComputerHistory.Gate
  alias FermixCore.ComputerHistory.Summarizer
  alias FermixCore.ComputerHistory.Summarizer.EventRender
  alias FermixCore.Memory.Repo

  @version 1
  @artifact_keys ~w(apps sites titles urls)
  @keys ~w(v sitting from_ts to_ts event_count field_values mark text note) ++ @artifact_keys
  {max_artifacts, max_artifact_chars} = Summarizer.artifact_bounds()
  @max_artifacts max_artifacts
  @max_artifact_chars max_artifact_chars
  @max_key_bytes 128
  @max_model_bytes 200
  # As many as one answer names (and `from_wire/1` takes): the oldest first, so
  # the machine's mark stays a true prefix and the rest come with the next one.
  @max_refused_intervals 256

  @typedoc "What the home answers a sitting."
  @type status :: :summarized | :abstained | :no_signal | :refused
  @type reason ::
          :purged
          | :paused
          | :invalid
          | :no_summarizer
          | :route_not_permitted
          | :summarizer_unavailable
          | :store
  @type answer :: %{status: status(), reason: reason() | nil, intervals: [map()]}

  @doc "The submission format's version."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc """
  Answer the sitting `payload` (the wire's JSON object) from the machine
  `computer` (its id, `""` for the home's own).
  """
  @spec accept(String.t(), map(), keyword()) :: answer()
  def accept(computer, payload, opts \\ [])
      when is_binary(computer) and is_map(payload) and is_list(opts) do
    repo = Keyword.get(opts, :repo, Repo)

    with :ok <- valid(payload),
         :ok <- unnoted(repo, computer, payload),
         :ok <- unrefused(repo, computer, payload),
         :ok <- with_signal(payload) do
      payload |> make(computer, repo, opts) |> logged(computer, payload)
    else
      {:answer, answer} -> logged(answer, computer, payload)
    end
  end

  @doc """
  Whether `payload` is a sitting this home takes: the format's version, its
  key, its time range and counts, at most #{@max_artifacts} artifacts of each
  kind, and either its rendered text (at most the renderer's budget) or a
  note made on the machine. `:ok` or the sentence why not.
  """
  @spec validate(map()) :: :ok | {:error, String.t()}
  def validate(payload) when is_map(payload) do
    cond do
      Map.keys(payload) -- @keys != [] -> {:error, "A sitting carries a field it should not."}
      payload["v"] != @version -> {:error, "A sitting of another format version."}
      not key?(payload["sitting"]) -> {:error, "A sitting needs its key."}
      not range?(payload["from_ts"], payload["to_ts"]) -> {:error, "A sitting needs its times."}
      true -> counts(payload)
    end
  end

  defp counts(payload) do
    cond do
      not count?(payload["event_count"]) -> {:error, "A sitting needs its event count."}
      not count?(payload["field_values"]) -> {:error, "A sitting needs its typed-text count."}
      not count?(Map.get(payload, "mark", 0)) -> {:error, "A sitting's mark is a count."}
      not Enum.all?(@artifact_keys, &artifacts?(payload[&1])) -> {:error, "A sitting's lists."}
      true -> content(payload["text"], payload["note"])
    end
  end

  defp key?(key), do: is_binary(key) and key != "" and byte_size(key) <= @max_key_bytes
  defp range?(from, to), do: is_integer(from) and is_integer(to) and from <= to
  defp count?(count), do: is_integer(count) and count >= 0

  defp artifacts?(nil), do: true

  defp artifacts?(list) when is_list(list) and length(list) <= @max_artifacts,
    do: Enum.all?(list, &(is_binary(&1) and String.length(&1) <= @max_artifact_chars))

  defp artifacts?(_other), do: false

  defp content(text, nil) when is_binary(text) do
    if String.valid?(text) and String.length(text) <= EventRender.default_budget(),
      do: :ok,
      else: {:error, "A sitting's text is longer than the summarizer reads."}
  end

  defp content(nil, %{"summary" => summary, "model" => model} = note)
       when map_size(note) == 2 and is_binary(summary) and is_binary(model) do
    if summary != "" and String.length(summary) <= Summarizer.note_max_chars() and
         byte_size(model) <= @max_model_bytes,
       do: :ok,
       else: {:error, "A sitting's note is empty or longer than a note may be."}
  end

  defp content(_text, _note), do: {:error, "A sitting carries its text or its note."}

  # -- the checks ------------------------------------------------------------------

  # A sitting this home cannot read is never sent again: the machine moves past
  # it, loudly (`Sittings`).
  defp valid(payload) do
    case validate(payload) do
      :ok ->
        :ok

      {:error, sentence} ->
        Logger.warning("computer_history: a sitting was refused as invalid: #{sentence}")
        {:answer, refused(:invalid)}
    end
  end

  defp unnoted(repo, computer, %{"sitting" => key}) do
    case Repo.computer_history_home(:noted, [computer, key], server: repo) do
      {:ok, nil} -> :ok
      {:ok, _id} -> {:answer, answer(:summarized)}
      {:error, reason} -> {:answer, store_error(reason)}
    end
  end

  # Only intervals the machine had not applied when it read the sitting: one it
  # applied left no event inside it (its mark, M97 §8.5).
  defp unrefused(repo, computer, %{"from_ts" => from_ts, "to_ts" => to_ts} = payload) do
    args = [computer, from_ts, to_ts, Map.get(payload, "mark", 0)]

    case Repo.computer_history_home(:reaching_intervals, args, server: repo) do
      {:ok, []} -> :ok
      {:ok, reaching} -> {:answer, refused_by(reaching, repo, computer, payload)}
      {:error, reason} -> {:answer, store_error(reason)}
    end
  end

  # A pause in what reaches the sitting decides the word. The refusal names
  # EVERY interval of the machine above its mark, oldest first, not only those
  # that reach this sitting: the machine records the highest one it applies as
  # its mark, so the mark must never step over one it was not given
  # (history_submit's RefusalNamesAllPending).
  defp refused_by(reaching, repo, computer, payload) do
    reason = if Enum.any?(reaching, &(&1.kind == "pause")), do: :paused, else: :purged
    args = [computer, Map.get(payload, "mark", 0), @max_refused_intervals]

    case Repo.computer_history_home(:intervals_after, args, server: repo) do
      {:ok, pending} -> %{status: :refused, reason: reason, intervals: pending}
      {:error, error} -> store_error(error)
    end
  end

  defp with_signal(%{"note" => %{}}), do: :ok

  defp with_signal(payload) do
    titles = Map.get(payload, "titles", [])

    if Summarizer.signal?(payload["field_values"], titles),
      do: :ok,
      else: {:answer, answer(:no_signal)}
  end

  # -- the note ----------------------------------------------------------------------

  defp make(
         %{"note" => %{"summary" => summary, "model" => model}} = payload,
         computer,
         repo,
         opts
       ),
       do: write(payload, {summary, model}, computer, repo, opts)

  defp make(%{"text" => text} = payload, computer, repo, opts) do
    config = Keyword.get_lazy(opts, :config, &Config.current/0)

    with {:ok, {route_key, _adapter_opts} = route} <- route(config, opts),
         {:ok, summary} <- summarize(route, text, payload, computer, repo, opts) do
      write(payload, {summary, route_key.model}, computer, repo, opts)
    else
      {:answer, answer} -> answer
    end
  end

  defp route(config, opts) do
    case Summarizer.route(Config.summarizer(config), Keyword.get(opts, :route_opts, [])) do
      {:ok, route} ->
        if Gate.summarizer_permitted?(route, config),
          do: {:ok, route},
          else: {:answer, refused(:route_not_permitted)}

      {:error, reason} ->
        Logger.warning("computer_history: the home has no summarizer route: #{inspect(reason)}")
        {:answer, refused(:no_summarizer)}
    end
  end

  defp summarize(route, text, payload, computer, repo, opts) do
    call_opts =
      opts
      |> Keyword.take([:adapter, :now])
      |> Keyword.put(:note, Summarizer.continuity(repo, computer, payload["from_ts"]))

    case Summarizer.summarize(route, text, EventRender.field_texts(text), call_opts) do
      {:ok, summary, _redactions} ->
        {:ok, summary}

      {:empty, _kind} ->
        {:answer, recorded(repo, computer, answer(:abstained), opts)}

      {:error, reason} ->
        Logger.error("computer_history summarizer route down: #{inspect(reason)}")
        {:answer, refused(:summarizer_unavailable)}
    end
  end

  defp write(payload, {summary, model}, computer, repo, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    memory = Summarizer.note(payload, summary, model, now)

    args = [
      memory,
      computer,
      payload["sitting"],
      DateTime.to_unix(now, :millisecond),
      Map.get(payload, "mark", 0)
    ]

    case Repo.computer_history_home(:insert_note, args, server: repo) do
      {:ok, {:written, _id}} -> answer(:summarized)
      {:ok, :duplicate} -> answer(:summarized)
      {:ok, {:refused, _reason, reaching}} -> refused_by(reaching, repo, computer, payload)
      {:error, reason} -> store_error(reason)
    end
  end

  # An outcome that writes no note is still the machine's latest.
  defp recorded(repo, computer, answer, opts) do
    now_ms = opts |> Keyword.get(:now, DateTime.utc_now()) |> DateTime.to_unix(:millisecond)
    args = [computer, Atom.to_string(answer.status), nil, now_ms]

    case Repo.computer_history_home(:record_submission, args, server: repo) do
      :ok -> answer
      {:error, reason} -> store_error(reason)
    end
  end

  defp answer(status), do: %{status: status, reason: nil, intervals: []}
  defp refused(reason), do: %{status: :refused, reason: reason, intervals: []}

  defp store_error(reason) do
    Logger.error("computer_history: the home's store refused a sitting: #{inspect(reason)}")
    refused(:store)
  end

  # Counts and words only, never content (§15.1).
  defp logged(answer, computer, payload) do
    Logger.info(
      "computer_history sitting from #{machine_label(computer)}: #{answer.status}" <>
        reason_clause(answer.reason) <> ", #{event_count(payload)} event(s)"
    )

    answer
  end

  # An invalid sitting's count may be anything; the log says only a number.
  defp event_count(%{"event_count" => count}) when is_integer(count), do: count
  defp event_count(_payload), do: 0

  defp machine_label(""), do: "this machine"
  defp machine_label(computer), do: "computer #{computer}"

  defp reason_clause(nil), do: ""
  defp reason_clause(reason), do: " (#{reason})"

  @statuses [:summarized, :abstained, :no_signal, :refused]
  @reasons [
    :purged,
    :paused,
    :invalid,
    :no_summarizer,
    :route_not_permitted,
    :summarizer_unavailable,
    :store
  ]
  @status_words Map.new(@statuses, &{Atom.to_string(&1), &1})
  @reason_words Map.new(@reasons, &{Atom.to_string(&1), &1})
  @max_intervals 256

  @doc """
  The answer the wire carried back to a machine (`to_wire/1`'s inverse), or
  why it cannot be read: a word outside the closed sets, or an interval that is
  not one.
  """
  @spec from_wire(map()) :: {:ok, answer()} | {:error, term()}
  def from_wire(%{"status" => status, "intervals" => intervals} = wire)
      when is_list(intervals) and length(intervals) <= @max_intervals do
    with {:ok, status} <- Map.fetch(@status_words, status),
         {:ok, reason} <- wire_reason(wire["reason"]),
         {:ok, intervals} <- wire_intervals(intervals) do
      {:ok, %{status: status, reason: reason, intervals: intervals}}
    else
      :error -> {:error, {:answer, wire}}
      {:error, _reason} = error -> error
    end
  end

  def from_wire(wire), do: {:error, {:answer, wire}}

  defp wire_reason(nil), do: {:ok, nil}
  defp wire_reason(word), do: Map.fetch(@reason_words, word)

  defp wire_intervals(intervals) do
    Enum.reduce_while(intervals, {:ok, []}, fn interval, {:ok, acc} ->
      case wire_interval(interval) do
        {:ok, read} -> {:cont, {:ok, [read | acc]}}
        :error -> {:halt, {:error, {:interval, interval}}}
      end
    end)
    |> then(fn
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end)
  end

  defp wire_interval(%{"id" => id, "from_ts" => from, "to_ts" => to, "kind" => kind} = interval)
       when is_integer(id) and id > 0 and is_integer(from) and is_integer(to) and from <= to and
              kind in ["purge", "pause"] do
    issued_at = Map.get(interval, "issued_at", from)

    if is_integer(issued_at),
      do: {:ok, %{id: id, from_ts: from, to_ts: to, issued_at: issued_at, kind: kind}},
      else: :error
  end

  defp wire_interval(_other), do: :error

  @doc "An answer as the wire carries it (string keys and words)."
  @spec to_wire(answer()) :: map()
  def to_wire(%{status: status, reason: reason, intervals: intervals}) do
    %{
      "status" => Atom.to_string(status),
      "reason" => reason && Atom.to_string(reason),
      "intervals" =>
        Enum.map(intervals, fn interval ->
          Map.new(interval, fn {key, value} -> {Atom.to_string(key), value} end)
        end)
    }
  end
end
