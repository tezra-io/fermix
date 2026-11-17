defmodule FermixCore.Harness.Delivery do
  @moduledoc """
  Message composition and one bounded send attempt for coding-harness runs
  (design §9.1, §10).

  Its responsibilities:

    * where a run's terminal message must go is frozen at tool-execute time
      by `Delivery.FrozenOrigin.resolve/2`, the rule every run kind that
      outlives its turn shares, and persisted on the ledger row so a later
      config edit can never retarget an in-flight run.
    * `deliver/2` — compose the message and make exactly ONE send attempt through
      the shared `Delivery.ChannelSend` seam, bounded by a spawn-monitor watchdog.
      `Harness.Manager` makes the first attempt inline on terminalization;
      `Harness.DeliveryWorker` owns every subsequent attempt. Mode `none` skips;
      mode `local` is "sent" without a channel send (jobs precedent).
    * `notice/2` — a best-effort advisory send (watchdog escalation / milestone),
      never retried, never recorded in `delivery_status`.

  Composition is a single pure function (`compose/2`, golden-tested): every
  message begins with `[run <id>]` (at-least-once run-id dedup), carries a status
  line (vendor · cwd tail · duration), and — on a non-completing run — the
  vendor's own error text (when it reported one), the reason, a diagnostics tail,
  and the vendor resume hint (or an explicit "not resumable (ephemeral)" line).
  A run that changed auto-executing vendor config names those files
  (`Harness.VendorConfig.note/1`). A chat-origin run whose continuation chain
  hit its cap closes with `Harness.Continuation.note/0`, so the owner is told
  the automatic follow-up stopped (§23.2) rather than wondering why nothing
  happened.
  """

  require Logger

  alias FermixCore.Delivery.ChannelSend
  alias FermixCore.Delivery.FrozenSend
  alias FermixCore.Harness.Adapters.ClaudeHeadless
  alias FermixCore.Harness.Adapters.CodexExec
  alias FermixCore.Harness.Artifacts
  alias FermixCore.Harness.Continuation
  alias FermixCore.Harness.SignIn
  alias FermixCore.Harness.VendorConfig

  # Compose ceiling: adapters chunk long text themselves, so the composed body
  # stays bounded (§C2) and is passed as raw text.
  @result_text_max 16_384
  @deliver_timeout_ms 60_000

  @doc """
  The watchdog bound on one `deliver/2` channel send (unless `opts[:timeout_ms]`
  overrides it). The Manager's hand-off lease is sized against it.
  """
  @spec deliver_timeout_ms() :: pos_integer()
  def deliver_timeout_ms, do: @deliver_timeout_ms

  @doc """
  Whether `row`'s origin is owned by a client (M29 §17.6(d)): the frozen origin
  snapshot the launch wrote carries a client origin (§17.4). Such an origin has
  no framework text path. The one source the Manager and the DeliveryWorker
  both read; never a channel-name list.
  """
  @spec client_owned?(map()) :: boolean()
  def client_owned?(row) when is_map(row), do: is_map(Map.get(row, :client_origin))

  @doc """
  Makes ONE bounded send attempt for `row`, returning `{:ok, :sent | :skipped}`
  or `{:error, reason}` for the caller (Manager inline / DeliveryWorker) to
  record. Mode `none` → `:skipped`; `local` → `:sent` without a channel send.
  """
  @spec deliver(map(), keyword()) :: {:ok, :sent | :skipped} | {:error, term()}
  def deliver(row, opts \\ []) when is_map(row) and is_list(opts) do
    case Map.get(row, :delivery_mode) do
      "none" -> {:ok, :skipped}
      "local" -> {:ok, :sent}
      mode when mode in ["origin", "channel"] -> deliver_to_channel(row, opts)
      other -> {:error, {:unsupported_delivery_mode, other}}
    end
  end

  @doc """
  Sends `text` as a best-effort advisory to `row`'s destination — one attempt, no
  retry, not recorded in `delivery_status`. Always returns `:ok`; a send failure
  is logged, never raised (the run must not be blocked by a notice).
  """
  @spec notice(map(), String.t(), keyword()) :: :ok
  def notice(row, text, opts \\ []) when is_map(row) and is_binary(text) and is_list(opts) do
    case Map.get(row, :delivery_mode) do
      mode when mode in ["origin", "channel"] -> send_notice(row, text, opts)
      _no_channel -> :ok
    end
  end

  @doc """
  Composes the terminal message for `row`. `result_text` is the run's harvested
  text — the deliverable for a completed run, the vendor's own error message for a
  failed one (`nil` when the run produced neither). Pure and golden-tested. A run
  that failed to sign in carries, after the vendor's words, the sentence naming
  the agent and this machine (`Harness.SignIn`, M98 D10): `opts[:machine]` names
  the machine, else that sentence reads it off this host.
  """
  @spec compose(map(), String.t() | nil, keyword()) :: String.t()
  def compose(row, result_text, opts \\ []) when is_map(row) and is_list(opts) do
    [header_line(row), body(row, result_text, opts), VendorConfig.note(row), cap_note(row)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  # --- One bounded send ---------------------------------------------------

  # One bounded send through the frozen-destination rule every run kind shares
  # (`Delivery.FrozenSend`), under this run kind's watchdog unless the caller
  # names one.
  defp deliver_to_channel(row, opts) do
    FrozenSend.send_text(
      row,
      compose(row, result_text_for(row), opts),
      Keyword.put_new(opts, :timeout_ms, deliver_timeout_ms())
    )
  end

  defp send_notice(row, text, opts) do
    result =
      ChannelSend.send(
        Map.get(row, :platform) || "",
        Map.get(row, :destination) || "",
        text,
        FrozenSend.send_opts(row),
        Keyword.put(opts, :delivery_max_attempts, 1)
      )

    case result do
      :ok -> :ok
      {:error, reason} -> log_notice_failure(row, reason)
    end
  end

  defp log_notice_failure(row, reason) do
    Logger.debug("harness notice send failed for #{Map.get(row, :id)}: #{inspect(reason)}")
    :ok
  end

  # --- Result harvest -----------------------------------------------------

  # A delivery retried long after terminalization sees only the ledger row, so the
  # text comes back off disk through the shared reader — the deliverable for a
  # completed run, the vendor's error message for a failed one.
  defp result_text_for(%{artifacts_dir: dir}), do: Artifacts.read_result(dir)
  defp result_text_for(_row), do: nil

  # --- Composition (pure) -------------------------------------------------

  defp header_line(row) do
    "[run #{Map.get(row, :id)}] #{Map.get(row, :status)}#{status_suffix(row)}"
  end

  defp status_suffix(row) do
    [vendor_part(row), cwd_tail(Map.get(row, :cwd)), duration(row)]
    |> Enum.reject(&(&1 == ""))
    |> join_suffix()
  end

  defp join_suffix([]), do: ""
  defp join_suffix(parts), do: " — " <> Enum.join(parts, " · ")

  defp vendor_part(row), do: Map.get(row, :vendor) || ""

  defp cwd_tail(cwd) when is_binary(cwd) and cwd != "" do
    case cwd |> Path.split() |> Enum.reject(&(&1 == "/")) do
      [] -> cwd
      [single] -> single
      segments -> "…/" <> (segments |> Enum.take(-2) |> Enum.join("/"))
    end
  end

  defp cwd_tail(_cwd), do: ""

  defp duration(row) do
    start = Map.get(row, :started_at) || Map.get(row, :created_at)
    finish = Map.get(row, :completed_at)
    format_duration(start, finish)
  end

  defp format_duration(%DateTime{} = start, %DateTime{} = finish) do
    case DateTime.diff(finish, start, :second) do
      seconds when seconds >= 0 -> human_duration(seconds)
      _negative -> ""
    end
  end

  defp format_duration(_start, _finish), do: ""

  defp human_duration(seconds) when seconds < 60, do: "#{seconds}s"

  defp human_duration(seconds) do
    minutes = div(seconds, 60)
    rest = rem(seconds, 60)
    "#{minutes}m#{rest}s"
  end

  # A cloud run's outcome is a vendor task, not a local result file: its message
  # carries the vendor status/diff summary (persisted as `diagnostics_tail`), the
  # task URL, and a `codex cloud diff` hint — never a "resume" line (no exec-resume
  # applies) and never a `result.txt` body.
  defp body(%{vendor: "codex_cloud"} = row, _result_text, _opts), do: cloud_body(row)

  defp body(%{status: "completed"} = _row, result_text, _opts), do: completed_body(result_text)

  defp body(row, result_text, opts) when is_map(row), do: failed_body(row, result_text, opts)

  defp completed_body(nil), do: ""
  defp completed_body(text) when is_binary(text), do: bound_text(text)

  defp cloud_body(row) do
    [reason_line(row), diagnostics_line(row), task_url_line(row), diff_hint_line(row)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp task_url_line(%{task_url: url}) when is_binary(url) and url != "", do: url
  defp task_url_line(_row), do: ""

  defp diff_hint_line(%{task_id: id}) when is_binary(id) and id != "",
    do: "Inspect the diff: codex cloud diff #{id}"

  defp diff_hint_line(_row), do: ""

  # The vendor's own error text is the whole diagnosis when it has one: "reason:
  # exit_1" tells the owner nothing, and the row's stderr tail repeats it beside
  # noise such as Codex's "Reading additional input from stdin..." (2026-11-03).
  # Both stay on the ledger row for `get_coding_run`; without the vendor's words
  # they are all there is, so the message carries them. A run that failed to
  # sign in adds Fermix's sentence after the vendor's words (M98 D10).
  defp failed_body(row, result_text, opts) do
    [diagnosis_lines(row, result_text), SignIn.run_note(row, opts), resume_line(row)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp diagnosis_lines(_row, text) when is_binary(text) and text != "",
    do: bound_text(String.trim(text))

  defp diagnosis_lines(row, _absent) do
    [reason_line(row), diagnostics_line(row)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp reason_line(%{reason: reason}) when is_binary(reason) and reason != "",
    do: "reason: #{reason}"

  defp reason_line(_row), do: ""

  defp diagnostics_line(%{diagnostics_tail: tail}) when is_binary(tail) and tail != "", do: tail
  defp diagnostics_line(_row), do: ""

  defp resume_line(%{resumable: false}), do: "Not resumable (ephemeral)."

  defp resume_line(row), do: hint_to_line(resume_hint(row))

  defp resume_hint(%{vendor: "codex"} = row), do: CodexExec.resume_hint(row)
  defp resume_hint(%{vendor: "claude"} = row), do: ClaudeHeadless.resume_hint(row)
  defp resume_hint(_row), do: nil

  defp hint_to_line(nil), do: ""
  defp hint_to_line(hint) when is_binary(hint), do: "Resume: #{hint}"

  defp bound_text(text) when byte_size(text) <= @result_text_max, do: text

  defp bound_text(text) do
    binary_part(text, 0, @result_text_max) <> "\n… [truncated]"
  end

  # The chain cap is a run-row property, so the note is derived here (pure) and
  # survives every delivery retry — never stitched on by the caller.
  defp cap_note(row) do
    if Continuation.depth_capped?(row), do: Continuation.note(), else: ""
  end
end
