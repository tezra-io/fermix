defmodule FermixCore.Harness.Delivery do
  @moduledoc """
  Message composition and one bounded send attempt for coding-harness runs
  (design §9.1, §10).

  Three responsibilities:

    * `resolve_snapshot/2` — at tool-execute time, freeze where a run's terminal
      message must go. A chat turn derives `{platform, destination, thread}` from
      the conversation the same way `DeliveryDefaults` derives `origin_target`; a
      scheduled launch copies the parent job's already-resolved
      `delivery_mode`/`delivery_target` (never the synthetic cron key), splitting
      it into the three ledger columns. The snapshot is persisted on the ledger
      row so a later config edit can never retarget an in-flight run.
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
  A chat-origin run whose continuation chain hit its cap closes with
  `Harness.Continuation.note/0`, so the owner is told the automatic follow-up
  stopped (§23.2) rather than wondering why nothing happened.
  """

  require Logger

  alias FermixCore.Acp.Identity
  alias FermixCore.Delivery.ChannelSend
  alias FermixCore.Harness.Adapters.ClaudeHeadless
  alias FermixCore.Harness.Adapters.CodexExec
  alias FermixCore.Harness.Artifacts
  alias FermixCore.Harness.Continuation
  alias FermixCore.Jobs.Registry, as: JobsRegistry
  alias FermixCore.Memory.ConversationStore
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Scope

  # Compose ceiling: adapters chunk long text themselves, so the composed body
  # stays bounded (§C2) and is passed as raw text.
  @result_text_max 16_384
  @deliver_timeout_ms 60_000
  # The launching turn's excerpt is bounded on the row (M29 §17.4) and read from
  # the tail of the conversation, not its whole history.
  @reply_context_max 4_096
  @reply_context_scan 10

  @type snapshot :: %{
          origin_kind: String.t(),
          delivery_mode: String.t(),
          platform: String.t() | nil,
          destination: String.t() | nil,
          thread: String.t() | nil,
          send_opts: map() | nil,
          parent_job_id: String.t() | nil,
          client_origin: map() | nil
        }

  @doc """
  Freezes the delivery snapshot for a run launched from `ctx`.

  `ctx.conversation_key` selects the origin: a `{:scheduled_job, job_id, _}` key
  copies the parent job's frozen delivery (fetched via `Jobs.Registry`, server
  from `ctx.memory_repo` or `opts[:registry_server]`); a `{channel, chat_id, _}`
  key derives an `origin`-mode chat snapshot. Any other key is unresolvable.

  A chat snapshot additionally freezes the **client origin** when the turn carries
  a client-presented identity (M29 §17.4) — see `client_origin/2`.
  """
  @spec resolve_snapshot(map(), keyword()) :: {:ok, snapshot()} | {:error, term()}
  def resolve_snapshot(ctx, opts \\ []) when is_map(ctx) and is_list(opts) do
    case Map.get(ctx, :conversation_key) do
      {:scheduled_job, job_id, _run_id} when is_binary(job_id) ->
        resolve_scheduled(job_id, ctx, opts)

      {channel, chat_id, thread_scope} when is_binary(channel) and is_binary(chat_id) ->
        {:ok, chat_snapshot(channel, chat_id, thread_scope, ctx, opts)}

      {channel, chat_id} when is_binary(channel) and is_binary(chat_id) ->
        {:ok, chat_snapshot(channel, chat_id, :root, ctx, opts)}

      other ->
        {:error, {:unresolvable_delivery_origin, other}}
    end
  end

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
  failed one (`nil` when the run produced neither). Pure and golden-tested.
  """
  @spec compose(map(), String.t() | nil) :: String.t()
  def compose(row, result_text) when is_map(row) do
    [header_line(row), body(row, result_text), cap_note(row)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  # --- Snapshot derivation ------------------------------------------------

  defp chat_snapshot(channel, chat_id, thread_scope, ctx, opts) do
    %{
      origin_kind: "chat",
      delivery_mode: "origin",
      platform: channel,
      destination: chat_id,
      thread: chat_thread(thread_scope),
      send_opts: nil,
      parent_job_id: nil,
      # The conversation key is rebuilt here rather than re-read from `ctx`, so the
      # excerpt read below always addresses a well-formed three-element key — the
      # same normalization the two-element clause above already applies.
      client_origin: client_origin({channel, chat_id, thread_scope}, ctx, opts)
    }
  end

  defp chat_thread(:root), do: nil
  defp chat_thread(scope), do: Scope.normalize_thread_scope(scope)

  # A CLIENT-OWNED origin (M29 §17.4). The ACP session that launched this run is
  # gone by the time it finishes, so freeze the three things the continuation
  # cannot recover from a dead session:
  #
  #   * `identity` — derived by the SAME `Identity.id_from_env/1` the Peer used at
  #     hello, so launch and hello can never disagree about whose run this is. It
  #     is what lets a continuation find credentials for a session id that no
  #     longer resolves.
  #   * `cwd` — the working directory the launching turn ran under, so the
  #     continuation turn reproduces it instead of falling to the sandbox default.
  #   * `reply_context` — a bounded, OPAQUE excerpt of the launching user turn.
  #     Fermix stores bytes and re-presents them; it never parses them, so no
  #     Fermix-side parser of a client's prompt format is created (§13 stands).
  #     History alone is not enough: pre-flight auto-compaction can summarize a
  #     high-entropy reply anchor away in the minutes this feature exists to span.
  #
  # No derivable identity ⇒ not a client-owned origin, which is the ordinary
  # answer on every framework-delivered channel: nothing but `Identity.to_env/1`
  # ever populates `session_env` (§17.1), and by the drop rule (§17.2) a key that
  # will not derive is not carried at all.
  defp client_origin(key, ctx, opts) do
    case Identity.id_from_env(Map.get(ctx, :session_env) || %{}) do
      {:ok, id} -> frozen_origin(id, key, ctx, opts)
      {:error, _no_identity} -> nil
    end
  end

  defp frozen_origin(id, key, ctx, opts) do
    %{
      "identity" => id,
      "cwd" => Map.get(ctx, :cwd),
      "reply_context" => reply_context(key, ctx, opts)
    }
  end

  defp reply_context(key, ctx, opts) do
    server =
      Keyword.get(opts, :conversation_store) ||
        Map.get(ctx, :conversation_store, ConversationStore)

    key
    |> ConversationStore.get_history(server: server, limit: @reply_context_scan)
    |> last_user_text()
    |> bound_context()
  end

  defp last_user_text(history) when is_list(history) do
    history |> Enum.reverse() |> Enum.find_value(&user_text/1)
  end

  defp user_text(%{role: "user", content: content}) when is_binary(content) and content != "",
    do: content

  defp user_text(_message), do: nil

  defp bound_context(nil), do: nil
  defp bound_context(text) when byte_size(text) <= @reply_context_max, do: text
  defp bound_context(text), do: utf8_prefix(text, @reply_context_max, 3)

  # A byte cut can land inside a multibyte codepoint, and this value is
  # `Jason.encode!`d onto the ledger row — invalid UTF-8 would raise there and
  # take the launch down. A UTF-8 codepoint is at most 4 bytes, so at most three
  # bytes are ever shaved (Code Rule 2: the loop is explicitly bounded).
  defp utf8_prefix(text, size, shaves) when shaves >= 0 do
    prefix = binary_part(text, 0, size)

    if String.valid?(prefix), do: prefix, else: utf8_prefix(text, size - 1, shaves - 1)
  end

  defp utf8_prefix(_text, _size, _shaves), do: ""

  defp resolve_scheduled(job_id, ctx, opts) do
    server = Keyword.get(opts, :registry_server, Map.get(ctx, :memory_repo, Repo))

    case JobsRegistry.get_job(job_id, server: server) do
      {:ok, job} -> {:ok, scheduled_snapshot(job)}
      {:error, reason} -> {:error, {:parent_job_lookup_failed, reason}}
    end
  end

  defp scheduled_snapshot(job) do
    target = job.delivery_target || %{}

    %{
      origin_kind: "scheduled",
      delivery_mode: job.delivery_mode,
      platform: target_field(target, ["platform", "channel"]),
      # Same key precedence as `Jobs.Delivery.normalize_target` so both rails
      # resolve one identical destination from the same frozen job target.
      destination:
        target_field(target, ["chat_id", "reply_target", "target", "recipient", "channel_id"]),
      thread: target_field(target, ["thread_ts", "message_thread_id"]),
      send_opts: target_extra_opts(target),
      parent_job_id: job.id,
      # A scheduled origin has no client session to belong to, by construction.
      client_origin: nil
    }
  end

  defp target_field(target, keys) do
    Enum.find_value(keys, fn key -> target_string(Map.get(target, key)) end)
  end

  defp target_string(value) when is_binary(value) and value != "", do: value
  defp target_string(_value), do: nil

  defp target_extra_opts(target) do
    extras =
      target
      |> Map.take(["reply_to", "req_options"])
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    if map_size(extras) == 0, do: nil, else: extras
  end

  # --- One bounded send ---------------------------------------------------

  defp deliver_to_channel(row, opts) do
    text = compose(row, result_text_for(row))
    timeout_ms = Keyword.get(opts, :timeout_ms, @deliver_timeout_ms)

    result =
      ChannelSend.with_timeout(timeout_ms, fn ->
        ChannelSend.send(
          Map.get(row, :platform) || "",
          Map.get(row, :destination) || "",
          text,
          build_send_opts(row),
          Keyword.put(opts, :delivery_max_attempts, 1)
        )
      end)

    case result do
      :ok -> {:ok, :sent}
      {:error, reason} -> {:error, reason}
    end
  end

  defp send_notice(row, text, opts) do
    result =
      ChannelSend.send(
        Map.get(row, :platform) || "",
        Map.get(row, :destination) || "",
        text,
        build_send_opts(row),
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

  defp build_send_opts(row) do
    []
    |> put_thread(Map.get(row, :thread))
    |> merge_send_opts(Map.get(row, :send_opts))
  end

  defp put_thread(opts, thread) when is_binary(thread) and thread != "" do
    Keyword.merge(opts, thread_ts: thread, message_thread_id: thread)
  end

  defp put_thread(opts, _thread), do: opts

  defp merge_send_opts(opts, map) when is_map(map) do
    Enum.reduce(map, opts, fn {key, value}, acc ->
      case send_opt_key(key) do
        nil -> acc
        atom_key -> Keyword.put(acc, atom_key, value)
      end
    end)
  end

  defp merge_send_opts(opts, _map), do: opts

  # A closed allowlist: `send_opts` is Fermix-generated at admission, but map its
  # string keys through a fixed table so a malformed row can never trigger atom
  # exhaustion via `String.to_atom/1`.
  defp send_opt_key("thread_ts"), do: :thread_ts
  defp send_opt_key("message_thread_id"), do: :message_thread_id
  defp send_opt_key("reply_to"), do: :reply_to
  defp send_opt_key("req_options"), do: :req_options
  defp send_opt_key(_other), do: nil

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
  defp body(%{vendor: "codex_cloud"} = row, _result_text), do: cloud_body(row)

  defp body(%{status: "completed"} = _row, result_text), do: completed_body(result_text)

  defp body(row, result_text) when is_map(row), do: failed_body(row, result_text)

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

  # The vendor's own error text leads a failure message for the same reason it
  # leads the continuation notice: "reason: exit_1" tells the owner nothing, while
  # "Not logged in · Please run /login" is the whole diagnosis.
  defp failed_body(row, result_text) do
    [vendor_line(result_text), reason_line(row), diagnostics_line(row), resume_line(row)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp vendor_line(text) when is_binary(text) and text != "", do: bound_text(String.trim(text))
  defp vendor_line(_absent), do: ""

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
