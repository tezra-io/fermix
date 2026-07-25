defmodule FermixCore.Harness.EventStream do
  @moduledoc """
  Pure, process-free line-reassembly accumulator for a vendor CLI JSONL stream.

  One job: turn a sequence of raw byte chunks (stdout with stderr merged, exactly
  as the port delivers them) into typed events, bounded diagnostics, framing
  accounting, and a terminal outcome. No processes, no I/O, no timers — the owner
  (the future `Harness.Run`) feeds chunks in and asks for the outcome at exit.

  Framing (design §6.1, pinned by the P0 spec):

    * Lines are spliced on the `\\n` byte. Splitting is byte-level, so a chunk that
      cuts a multi-byte UTF-8 sequence simply leaves an incomplete line in the
      buffer that the next chunk completes.
    * A completed line larger than `max_event_bytes` (default 1 MiB) is the ONLY
      framing violation. Once `framing_errors` exceeds `max_framing_errors`
      (default 20), `push/2` returns `{:error, {:protocol, _}, t}` and the caller
      kills the run.
    * A completed line that is a JSON object is an `{:event, map}`; any other
      completed, non-empty line (valid JSON non-object, or non-JSON stderr noise)
      is a `{:diagnostic, line}` — never a framing error. Empty lines are ignored.
    * At `finalize/2` a non-empty trailing partial line is parsed once: a JSON
      object becomes an event (checked for terminal), anything else a diagnostic.
      A truncated final line is never a framing error.

  Outcome matrix (design §12.1, exact): a non-zero exit is always
  `{:failed, {:exit, code}}` regardless of events; exit 0 with the vendor terminal
  event seen is `:completed`; exit 0 without it is `{:failed, :protocol}` — success
  is never inferred from silence. The vendor `terminal?/1` predicate is injected at
  `new/1`; EventStream is otherwise vendor-agnostic and emits every JSON object.
  """

  @default_max_event_bytes 1_048_576
  @default_max_framing_errors 20
  @diagnostics_tail_max 50
  @newline "\n"

  @type emitted :: {:event, map()} | {:diagnostic, String.t()}
  @type outcome :: :completed | {:failed, {:exit, integer()}} | {:failed, :protocol}
  @type terminal_fun :: (map() -> boolean())

  @type summary :: %{
          outcome: outcome(),
          events: non_neg_integer(),
          framing_errors: non_neg_integer(),
          diagnostics_tail: [String.t()],
          terminal_seen?: boolean()
        }

  @type opt ::
          {:max_event_bytes, pos_integer()}
          | {:max_framing_errors, non_neg_integer()}
          | {:terminal?, terminal_fun()}

  defstruct buffer: "",
            max_event_bytes: @default_max_event_bytes,
            max_framing_errors: @default_max_framing_errors,
            terminal_fun: nil,
            events: 0,
            framing_errors: 0,
            terminal_seen?: false,
            diagnostics: []

  @opaque t :: %__MODULE__{
            buffer: binary(),
            max_event_bytes: pos_integer(),
            max_framing_errors: non_neg_integer(),
            terminal_fun: terminal_fun(),
            events: non_neg_integer(),
            framing_errors: non_neg_integer(),
            terminal_seen?: boolean(),
            diagnostics: [String.t()]
          }

  @doc """
  Builds a fresh accumulator.

  `:terminal?` is the vendor predicate over a decoded event map (default: never
  terminal). `:max_event_bytes` (default #{@default_max_event_bytes}) caps a single
  line; `:max_framing_errors` (default #{@default_max_framing_errors}) caps
  oversized-line violations before the stream is declared a protocol failure.
  Invalid options fail loud.
  """
  @spec new([opt()]) :: t()
  def new(opts \\ []) when is_list(opts) do
    %__MODULE__{
      max_event_bytes: validate_pos_int!(opts, :max_event_bytes, @default_max_event_bytes),
      max_framing_errors:
        validate_non_neg_int!(opts, :max_framing_errors, @default_max_framing_errors),
      terminal_fun: validate_terminal_fun!(opts)
    }
  end

  @doc """
  Feeds one raw chunk, returning the events/diagnostics it completed (in order)
  and the advanced accumulator.

  Returns `{:error, {:protocol, detail}, t}` when the oversized-line budget is
  exceeded within this chunk; the caller must terminate the run.
  """
  @spec push(t(), binary()) :: {:ok, [emitted()], t()} | {:error, {:protocol, term()}, t()}
  def push(%__MODULE__{} = state, chunk) when is_binary(chunk) do
    combined = state.buffer <> chunk
    parts = :binary.split(combined, @newline, [:global])
    {lines, buffer} = split_trailing(parts)
    consume_lines(lines, %{state | buffer: buffer})
  end

  @doc """
  Flushes any trailing partial line and resolves the terminal outcome for the
  given process exit code. Pure — does not mutate the caller's accumulator.
  """
  @spec finalize(t(), integer()) :: summary()
  def finalize(%__MODULE__{} = state, exit_code) when is_integer(exit_code) do
    final = flush_buffer(state)

    %{
      outcome: outcome(exit_code, final.terminal_seen?),
      events: final.events,
      framing_errors: final.framing_errors,
      diagnostics_tail: Enum.reverse(final.diagnostics),
      terminal_seen?: final.terminal_seen?
    }
  end

  # `:binary.split` always yields at least one element; the last is the trailing
  # (possibly empty) incomplete line, the rest are completed lines.
  defp split_trailing(parts) do
    {lines, [buffer]} = Enum.split(parts, length(parts) - 1)
    {lines, buffer}
  end

  defp consume_lines(lines, state) do
    lines
    |> Enum.reduce_while({state, []}, &fold_line/2)
    |> finish_consume()
  end

  defp fold_line(line, {state, emitted}) do
    case classify_line(line, state) do
      {:ok, next, nil} -> {:cont, {next, emitted}}
      {:ok, next, item} -> {:cont, {next, [item | emitted]}}
      {:breach, next} -> {:halt, {:breach, next}}
    end
  end

  defp finish_consume({:breach, state}) do
    {:error, {:protocol, {:framing_budget_exceeded, state.framing_errors}}, state}
  end

  defp finish_consume({state, emitted}), do: {:ok, Enum.reverse(emitted), state}

  # Empty segments between newlines carry no event and no diagnostic value.
  defp classify_line("", state), do: {:ok, state, nil}

  defp classify_line(line, state) do
    if byte_size(line) > state.max_event_bytes do
      over_budget(state)
    else
      parse_line(line, state)
    end
  end

  defp over_budget(state) do
    counted = %{state | framing_errors: state.framing_errors + 1}

    if counted.framing_errors > counted.max_framing_errors do
      {:breach, counted}
    else
      {:ok, counted, nil}
    end
  end

  defp parse_line(line, state) do
    case Jason.decode(line) do
      {:ok, map} when is_map(map) -> {:ok, record_event(state, map), {:event, map}}
      {:ok, _non_object} -> {:ok, record_diagnostic(state, line), {:diagnostic, line}}
      {:error, _not_json} -> {:ok, record_diagnostic(state, line), {:diagnostic, line}}
    end
  end

  defp flush_buffer(%__MODULE__{buffer: ""} = state), do: state

  defp flush_buffer(%__MODULE__{buffer: buffer} = state) do
    cleared = %{state | buffer: ""}

    case Jason.decode(buffer) do
      {:ok, map} when is_map(map) -> record_event(cleared, map)
      {:ok, _non_object} -> record_diagnostic(cleared, buffer)
      {:error, _not_json} -> record_diagnostic(cleared, buffer)
    end
  end

  defp record_event(state, map) do
    %{
      state
      | events: state.events + 1,
        terminal_seen?: state.terminal_seen? or state.terminal_fun.(map)
    }
  end

  defp record_diagnostic(state, line) do
    %{state | diagnostics: Enum.take([line | state.diagnostics], @diagnostics_tail_max)}
  end

  defp outcome(exit_code, _terminal_seen?) when exit_code != 0, do: {:failed, {:exit, exit_code}}
  defp outcome(0, true), do: :completed
  defp outcome(0, false), do: {:failed, :protocol}

  defp validate_pos_int!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      other -> raise ArgumentError, "#{key} must be a positive integer, got: #{inspect(other)}"
    end
  end

  defp validate_non_neg_int!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value >= 0 ->
        value

      other ->
        raise ArgumentError, "#{key} must be a non-negative integer, got: #{inspect(other)}"
    end
  end

  defp validate_terminal_fun!(opts) do
    case Keyword.get(opts, :terminal?, fn _event -> false end) do
      fun when is_function(fun, 1) -> fun
      other -> raise ArgumentError, "terminal? must be a 1-arity function, got: #{inspect(other)}"
    end
  end
end
