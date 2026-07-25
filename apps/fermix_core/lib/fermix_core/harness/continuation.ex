defmodule FermixCore.Harness.Continuation do
  @moduledoc """
  Completion continuation for chat-origin coding runs (design §23.2).

  Runs are background-only (§23.1), so the turn that launched one ends before it
  finishes. On terminalization of a **chat-origin** run this module synthesizes a
  system-voiced notice carrying the outcome and hands it to the injected
  `Harness.ContinuationDispatcher`, which re-ingests it into the origin
  conversation — the agent then takes one turn and either reports the result in
  its own voice or continues the work. It generalizes the sandbox-grant
  `/confirm` auto-resume, the codebase's only continuation precedent.

  Two bounds and one guarantee:

    * **Chain depth (Code Rule 2).** A run launched from a continuation turn
      inherits `depth + 1` on its ledger row. At `max_depth/0` the chain stops:
      `continuable?/1` is false, so the outcome is delivered as ordinary text
      with `note/1` appended (a defined cap behavior, never silent).
    * **Scheduled origins never continue.** They have no channel conversation to
      re-enter and keep the plain durable delivery of §9.1 — two legitimate
      configurations, not two mechanisms for one.
    * **At most once.** Terminalization is already once-only (the ledger's
      guarded terminal write), so dispatch rides that guarantee without a second
      flag. On success the caller marks the row delivered (the agent's turn *is*
      the notification); on failure the row stays `pending` and the existing
      `DeliveryWorker` delivers the text.
  """

  require Logger

  alias FermixCore.Delivery.ChannelSend

  @max_depth 3
  @result_text_max 8_192
  @dispatch_timeout_ms 15_000
  @closing "Continue the request this run was for; if it is already satisfied, just report the outcome."

  @doc "Maximum continuation chain depth (design §23.2)."
  @spec max_depth() :: pos_integer()
  def max_depth, do: @max_depth

  @doc """
  Whether `row`'s terminal outcome may re-enter its conversation: a chat origin
  still inside the depth cap whose terminal is a *result*. A scheduled origin, a
  depth-capped chain, and an owner halt are all false.
  """
  @spec continuable?(map()) :: boolean()
  def continuable?(row) when is_map(row) do
    chat_origin?(row) and depth(row) < @max_depth and result_terminal?(row)
  end

  @doc """
  Whether `row` is a chat-origin run whose chain hit the cap, so its outcome was
  delivered as text instead of continuing. `Harness.Delivery` reads this to append
  `note/1`.
  """
  @spec depth_capped?(map()) :: boolean()
  def depth_capped?(row) when is_map(row) do
    chat_origin?(row) and depth(row) >= @max_depth
  end

  @doc "The owner-facing note stating that automatic follow-up stopped at the cap."
  @spec note() :: String.t()
  def note do
    "Automatic follow-up stopped here — this run is #{@max_depth} continuations deep, " <>
      "so its outcome was delivered as a message instead of continuing the work."
  end

  @doc """
  Resolves the configured dispatcher module: `opts[:dispatcher]` (the test seam)
  or `config :fermix_core, :harness_continuation_dispatcher`. `:none` when no
  dispatcher is configured (continuation is off) or the configured module cannot
  serve the behaviour — the latter logs loud.
  """
  @spec dispatcher(keyword()) :: {:ok, module()} | :none
  def dispatcher(opts) when is_list(opts) do
    case Keyword.get(opts, :dispatcher) || configured_dispatcher() do
      nil -> :none
      module -> validate_dispatcher(module)
    end
  end

  @doc """
  Dispatches `row`'s completion notice through `dispatcher`. `result_text` is the
  completed run's harvested output (`nil` otherwise). Returns whatever the
  dispatcher reports so the caller can record delivery honestly.

  The dispatcher runs under the same monitored watchdog the delivery path uses
  (`opts[:timeout_ms]`, default #{@dispatch_timeout_ms}ms), because the caller is
  the harness Manager: a wedged or crashing re-ingest must not block it. Cap
  behavior is the honest one — a timeout/crash is an `{:error, _}` dispatch, so
  the row stays `pending` and the `DeliveryWorker` delivers the outcome as text.
  """
  @spec dispatch(module(), map(), String.t() | nil, keyword()) :: :ok | {:error, term()}
  def dispatch(dispatcher, row, result_text, opts \\ [])
      when is_atom(dispatcher) and is_map(row) and is_list(opts) do
    case destination(row) do
      {:ok, platform, target} ->
        notice = notice(row, result_text, platform, target)
        timeout_ms = Keyword.get(opts, :timeout_ms, @dispatch_timeout_ms)
        ChannelSend.with_timeout(timeout_ms, fn -> dispatcher.dispatch(notice) end)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  The depth a run launched from a continuation-carrying turn inherits, and the
  depth stamped on the notice this run produces: `row`'s depth plus one.
  """
  @spec next_depth(map()) :: pos_integer()
  def next_depth(row) when is_map(row), do: depth(row) + 1

  @doc """
  The system-voiced notice text (pure, golden-tested): the run tag, the
  vendor/status/cwd line, the bounded outcome body, and the closing instruction.
  """
  @spec notice_text(map(), String.t() | nil) :: String.t()
  def notice_text(row, result_text) when is_map(row) do
    [
      "[coding run #{Map.get(row, :id)} finished]",
      status_line(row),
      body(row, result_text),
      @closing
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  # --- Notice construction ------------------------------------------------

  defp notice(row, result_text, platform, destination) do
    %{
      platform: platform,
      destination: destination,
      thread: Map.get(row, :thread),
      content: notice_text(row, result_text),
      metadata: %{
        harness_continuation: true,
        harness_run_id: Map.get(row, :id),
        harness_continuation_depth: next_depth(row)
      }
    }
  end

  defp destination(row) do
    case {Map.get(row, :platform), Map.get(row, :destination)} do
      {platform, target} when is_binary(platform) and is_binary(target) -> {:ok, platform, target}
      other -> {:error, {:unresolvable_continuation_target, other}}
    end
  end

  defp status_line(row) do
    [Map.get(row, :vendor), Map.get(row, :status), Map.get(row, :cwd)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  # A cloud run's outcome is a vendor task, not a local result file (its
  # `result_text` is always nil), so the notice carries what `Delivery` composes
  # for that rail: the vendor status/diff summary, the task URL, and the diff
  # hint — otherwise a completed cloud run would continue with an empty body.
  defp body(%{vendor: "codex_cloud"} = row, _result_text) do
    [reason_line(row), Map.get(row, :diagnostics_tail), task_url(row), diff_hint(row)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
    |> bound()
  end

  # A completed run speaks through its result text; anything else speaks through
  # its reason + diagnostics so the agent reacts to the real failure rather than a
  # bare status word.
  defp body(%{status: "completed"}, result_text) when is_binary(result_text) do
    bound(result_text)
  end

  defp body(%{status: "completed"}, _absent), do: ""

  defp body(row, _result_text) do
    [reason_line(row), Map.get(row, :diagnostics_tail)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
    |> bound()
  end

  defp reason_line(%{reason: reason}) when is_binary(reason) and reason != "",
    do: "reason: #{reason}"

  defp reason_line(_row), do: ""

  defp task_url(%{task_url: url}) when is_binary(url) and url != "", do: url
  defp task_url(_row), do: ""

  defp diff_hint(%{task_id: id}) when is_binary(id) and id != "",
    do: "Inspect the diff: codex cloud diff #{id}"

  defp diff_hint(_row), do: ""

  defp bound(text) when byte_size(text) <= @result_text_max, do: text
  defp bound(text), do: binary_part(text, 0, @result_text_max) <> "\n… [truncated]"

  # --- Dispatcher resolution ----------------------------------------------

  defp configured_dispatcher do
    Application.get_env(:fermix_core, :harness_continuation_dispatcher)
  end

  defp validate_dispatcher(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :dispatch, 1) do
      {:ok, module}
    else
      Logger.error(
        "harness continuation dispatcher #{inspect(module)} does not export dispatch/1; " <>
          "run outcomes are delivered as text instead of continuing the conversation"
      )

      :none
    end
  end

  defp chat_origin?(row), do: Map.get(row, :origin_kind) == "chat"

  # An owner halt is not a result. `/stop`, `cancel_coding_run`, and
  # `stop_tracking_coding_run` each terminalize a run the owner just stopped, so
  # re-entering the conversation with "continue the request this run was for"
  # would relaunch the work the kill switch ended. Those outcomes take the plain
  # durable delivery path instead — derived from the row, so it survives a retry.
  defp result_terminal?(row) do
    Map.get(row, :status) != "cancelled" and Map.get(row, :reason) != "tracking_stopped"
  end

  defp depth(row) do
    case Map.get(row, :continuation_depth) do
      value when is_integer(value) and value > 0 -> value
      _absent_or_zero -> 0
    end
  end
end
