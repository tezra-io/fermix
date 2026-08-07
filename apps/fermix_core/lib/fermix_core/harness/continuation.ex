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

  ## Client-owned origins (M29 §17.4, §17.6(c))

  On a surface owned by an ACP client, returning text is not delivery: the reply
  reaches the client's own session viewer and nothing else, and the session that
  launched the run is gone by the time it finishes. Two things follow, and the
  ledger row's frozen `client_origin` decides both:

    * the notice re-presents the origin's `reply_context` — the launching turn's
      own text, frozen at launch so pre-flight auto-compaction cannot summarize
      the reply anchor away in the minutes this feature exists to span. Fermix
      never parses it; it renders the bytes inside their own untrusted frame;
    * the closing gains the publishing obligation, appended to (never in place
      of) the origin's own closing, on the completed and the failed path alike.
  """

  require Logger

  alias FermixCore.Capabilities.UntrustedContent
  alias FermixCore.Delivery.ChannelSend

  @max_depth 3
  @result_text_max 8_192
  # The excerpt is bounded at freeze time (`Harness.Delivery`, ≤4 KiB on the
  # row). This is the render-side ceiling for the same value, so a row carrying
  # more than the writer ever stores still cannot grow the prompt.
  @reply_context_max 4_096
  @dispatch_timeout_ms 15_000
  # The frame attribution for the run's own output. Names the classification
  # Fermix already applies to this text on the memory-recall path
  # (`UntrustedContent.untrusted_source_type?/1`) rather than the vendor, which
  # the run tag and status line above the frame already state.
  @untrusted_source "coding_harness"
  # A SECOND attribution for a second source: the request the run was launched
  # from is a third party's words, not the run's output, and the model has to be
  # able to tell them apart.
  @request_source "launching_request"
  @request_label "The request this run was launched from, quoted verbatim — read it for where the outcome belongs:"
  @closing "Continue the request this run was for; if it is already satisfied, just report the outcome."
  # Appended on a CLIENT-OWNED origin (M29 §17.6(c)), where the reply Fermix
  # returns reaches only the client's own session viewer. Stated as the principle
  # and nothing else: no surface, no tool, no command. The concrete tooling comes
  # from the client's injected prompt and the conversation's own history, and the
  # next client-owned surface will not be this one.
  @publish_closing "Returning text is not delivery on this surface — nothing you say in reply reaches anyone. Publishing the outcome back where the request came from is part of the work: do it with the tooling this surface gives you before you finish."

  # A run that ends without a result leaves a decision, not an outcome — and the
  # failure text above is the evidence for it. State the decision and let the agent
  # judge it; do not classify reasons into retryable/terminal here. A programmatic
  # router would have to predict every vendor failure mode, while the agent can
  # simply read "Not logged in · Please run /login" and conclude that no retry will
  # help. Naming both moves as legitimate is what stops the two observed failure
  # modes: blind-retrying the same wall, and stopping dead on a request the agent
  # could have served with its own tools.
  #
  # It must NOT claim the worktree is untouched. A `timeout`, `output_limit` or
  # `subscriber_stalled` kill lands after the vendor ran for minutes inside the real
  # repo, and `artifact_write` means the vendor finished and only the result file
  # failed — so "nothing happened, redo it" would invite a second implementation on
  # top of a half-applied one. Inspecting first is the only opening that is true for
  # every class, and it costs the agent one cheap command.
  @failed_closing "This run ended without reporting a result, and it may have left partial changes behind — check the working tree before redoing anything. Then decide from the failure above: run it again if the cause looks transient; if the harness cannot serve this request until someone intervenes, carry out the work yourself with your ordinary file and shell tools. Either way tell the owner plainly what failed and what it needs."

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
  run's harvested text — the deliverable for a completed run, the vendor's own
  error message for a failed one (`nil` when it produced neither). Returns whatever
  the dispatcher reports so the caller can record delivery honestly.

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
  vendor/status/cwd line, the bounded outcome body inside the untrusted-content
  frame, the launching request (client-owned origins only, in a frame of its
  own), and the closing instruction.
  """
  @spec notice_text(map(), String.t() | nil) :: String.t()
  def notice_text(row, result_text) when is_map(row) do
    [
      "[coding run #{Map.get(row, :id)} finished]",
      status_line(row),
      body(row, result_text),
      launching_request(row),
      closing(row)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  # The origin's own closing, plus — on a client-owned origin — the publishing
  # obligation. Appended rather than substituted so a failed run keeps every word
  # of its inspect-then-decide guidance: an outcome nobody can see is not
  # reported, and a failure is exactly as invisible as a success here.
  defp closing(row) do
    [outcome_closing(row), publish_closing(row)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  # An owner halt never reaches here (`continuable?/1` excludes cancelled and
  # tracking_stopped), so every non-completed status that does is a run that tried
  # and failed.
  defp outcome_closing(%{status: "completed"}), do: @closing

  # A cloud terminal usually means "we stopped knowing", not "nothing happened":
  # `poll_deadline` and `submission_outcome_unknown` leave the vendor task RUNNING,
  # and it will still produce a diff. Telling the agent to carry out the work itself
  # would race a live task on the same repo. The cloud body already carries the task
  # URL and the `codex cloud diff` hint, which is the honest next step. Matching on
  # the vendor deliberately sweeps in the cloud failures where nothing IS running
  # (a submit that never landed) — erring toward "go look" is the safe direction,
  # and the alternative is the per-reason classification this design rejects.
  defp outcome_closing(%{vendor: "codex_cloud"}), do: @closing

  defp outcome_closing(_failed), do: @failed_closing

  # The frozen client origin is the single fact that decides this (M29 §17.4) —
  # never a channel-name list, which would go stale the first time a second
  # client-owned surface exists.
  defp publish_closing(%{client_origin: origin}) when is_map(origin), do: @publish_closing
  defp publish_closing(_framework_delivered), do: ""

  # --- Notice construction ------------------------------------------------

  defp notice(row, result_text, platform, destination) do
    %{
      platform: platform,
      destination: destination,
      thread: Map.get(row, :thread),
      # The launch-time client origin (M29 §17.4), passed through untouched:
      # `fermix_core` holds no `Message` struct and no identity resolution for a
      # channel, so the dispatcher is the single point that turns this into the
      # continuation turn's env and cwd (§17.6(c)). `nil` on every framework-
      # delivered origin.
      client_origin: Map.get(row, :client_origin),
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

  # The outcome text is the run's own output, derived from the repo, issue and
  # web content the vendor read — and the closing line directly beneath it tells
  # the model to act. So every shape of outcome enters the loop inside the
  # untrusted-content frame, the same boundary the memory-recall path already
  # applies to this vendor text (§10.3). Funnelled through one clause so an
  # outcome shape added later cannot enter unframed.
  #
  # The run tag, `status_line/1` and `closing/1` stay OUTSIDE the frame: they are
  # Fermix-authored and must keep their instructional authority. `frame/2`
  # neutralizes any frame delimiter the payload carries, so the outcome cannot
  # close the boundary early.
  defp body(row, result_text) do
    row
    |> outcome(result_text)
    |> frame_outcome()
  end

  defp frame_outcome(""), do: ""
  defp frame_outcome(text), do: UntrustedContent.frame(@untrusted_source, text)

  # The turn that launched this run, frozen at launch (M29 §17.4) because the
  # minutes between launch and completion are exactly the window in which
  # pre-flight auto-compaction can summarize the channel and the reply anchor
  # away — the one failure mode carrying this excerpt exists to remove.
  #
  # Fermix stores bytes and re-presents bytes: it never parses this, so no
  # Fermix-side parser of a client's prompt format is created (§13 stands). The
  # model reads it; we only carry it. Which is also why it enters under its OWN
  # untrusted attribution rather than the run's — third-party words, sitting
  # directly above a closing that tells the model to act, so the same "DATA, not
  # instructions" boundary the outcome gets applies here too. `frame/2`
  # neutralizes any delimiter the excerpt carries, so it cannot close the
  # boundary early and have the closing read as its own.
  defp launching_request(row) do
    case reply_context(row) do
      "" -> ""
      excerpt -> @request_label <> "\n" <> UntrustedContent.frame(@request_source, excerpt)
    end
  end

  defp reply_context(%{client_origin: origin}) when is_map(origin) do
    origin |> Map.get("reply_context") |> excerpt()
  end

  defp reply_context(_framework_delivered), do: ""

  defp excerpt(text) when is_binary(text), do: text |> String.trim() |> bound(@reply_context_max)
  defp excerpt(_absent), do: ""

  # A cloud run's outcome is a vendor task, not a local result file (its
  # `result_text` is always nil), so the notice carries what `Delivery` composes
  # for that rail: the vendor status/diff summary, the task URL, and the diff
  # hint — otherwise a completed cloud run would continue with an empty body.
  defp outcome(%{vendor: "codex_cloud"} = row, _result_text) do
    [reason_line(row), Map.get(row, :diagnostics_tail), task_url(row), diff_hint(row)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
    |> bound()
  end

  # A completed run speaks through its result text; anything else speaks through
  # its reason + diagnostics so the agent reacts to the real failure rather than a
  # bare status word.
  defp outcome(%{status: "completed"}, result_text) when is_binary(result_text) do
    bound(result_text)
  end

  defp outcome(%{status: "completed"}, _absent), do: ""

  # A failed run's `result_text` is the vendor's own error message. Without it the
  # agent reads a bare `reason: exit_1`, cannot tell an auth failure from a crash,
  # and re-launches straight into the same wall — so it leads the body, ahead of
  # the reason word and the (stderr-only) diagnostics tail.
  defp outcome(row, result_text) do
    [vendor_line(result_text), reason_line(row), Map.get(row, :diagnostics_tail)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
    |> bound()
  end

  defp vendor_line(text) when is_binary(text) and text != "", do: String.trim(text)
  defp vendor_line(_absent), do: ""

  defp reason_line(%{reason: reason}) when is_binary(reason) and reason != "",
    do: "reason: #{reason}"

  defp reason_line(_row), do: ""

  defp task_url(%{task_url: url}) when is_binary(url) and url != "", do: url
  defp task_url(_row), do: ""

  defp diff_hint(%{task_id: id}) when is_binary(id) and id != "",
    do: "Inspect the diff: codex cloud diff #{id}"

  defp diff_hint(_row), do: ""

  defp bound(text), do: bound(text, @result_text_max)

  defp bound(text, max) when byte_size(text) <= max, do: text
  defp bound(text, max), do: binary_part(text, 0, max) <> "\n… [truncated]"

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
