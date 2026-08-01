defmodule FermixCore.Tools.HarnessSupport do
  @moduledoc false

  # Shared plumbing for the five coding-harness tools: the `ToolTelemetry.exec`
  # envelope, JSON result shaping, option/param parsing, and honest error
  # formatting. The harness twin of `JobRegistrySupport` (spec §6/C1) — kept
  # separate so harness error vocabulary and run payloads never drift into the
  # jobs family.

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Capabilities.UntrustedContent
  alias FermixCore.Harness.Artifacts
  alias FermixCore.Harness.Consent
  alias FermixCore.Memory.Repo
  alias FermixCore.Tools.Telemetry, as: ToolTelemetry

  # The polled payload carries a diagnosis, not a deliverable — the full result
  # already lives in `result.txt`, which the payload names via `artifacts_dir`.
  # Deliberately its own budget: `Continuation`'s notice bound and `Delivery`'s
  # message bound size a chat message, this one sizes a JSON tool result. They are
  # not meant to agree.
  @result_tail_max 4_096

  # Must match `Harness.Continuation`'s attribution and the memory-recall
  # classification (`UntrustedContent.untrusted_source_type?/1`), so the same
  # vendor text carries the same label whichever door it reaches the model by.
  @untrusted_source "coding_harness"

  # Parameter values whose only effect is to remove the vendor child's own
  # confinement. Fermix admits the run's `cwd` and every `add_dirs` entry through
  # its sandbox, but does not confine the child at the OS level — `Harness.Env`
  # sanitizes secrets, it is not a jail. So the vendor's own sandbox is the sole
  # thing keeping the child inside those directories, and these values switch it
  # off: after them the child writes anywhere the daemon user can.
  #
  # The line this draws is friction vs. boundary. `acceptEdits`, `auto`,
  # `manual`, `dontAsk`, `plan`, `read-only` and `workspace-write` all change how
  # much the child asks *within* its sandbox and stay available to the model.
  # These two delete the sandbox, and the model does not get to make that call.
  #
  # Refusing here — the model-facing tool boundary — deliberately leaves the
  # ADAPTER vocabulary intact: an owner-set posture is a different thing from a
  # model-set one, and M25's server-side Code-mode posture (§7.2) needs the
  # adapters to still express it. Omitting the param entirely remains the
  # default, which inherits the operator's own `~/.claude/settings.json` or
  # `~/.codex/config.toml` — so autonomy is unchanged by this gate.
  @boundary_removing %{
    sandbox: ["danger-full-access"],
    permission_mode: ["bypassPermissions"]
  }

  # Closes the execute-time consent refusal so a by-name dispatch never dead-ends
  # (design §23.4): main-agent coding is permitted, merely not preferred.
  @proceed_directly "Do not retry this tool — carry out the work yourself now with your ordinary file and shell tools."

  @doc """
  Wraps `fun` in the monotonic timer + `ToolTelemetry.exec` envelope every
  built-in tool shares (`memory_recall`/`JobRegistrySupport` precedent). Never
  hand-rolls `:telemetry.execute` — the shared emitter keeps runs correlatable.
  """
  @spec run(String.t(), map(), (-> {:ok, Tool.tool_result()})) :: {:ok, Tool.tool_result()}
  def run(tool_name, context, fun) when is_binary(tool_name) and is_map(context) do
    start = System.monotonic_time(:millisecond)
    result = fun.()
    duration = System.monotonic_time(:millisecond) - start
    success = match?({:ok, %{success: true}}, result)

    ToolTelemetry.exec(tool_name, context, success, duration,
      metadata: maybe_put_error(%{}, result),
      result: result
    )

    result
  end

  # Channels whose conversation is owned by an external client and ends with it.
  # A coding run outlives the turn that launched it and reports back through a
  # continuation into that conversation, so on these surfaces the whole harness
  # family stays off the advertised schema (MILESTONE_29_ACP_AGENT_SURFACE §4,
  # "Detached work"). Visibility only, exactly like the other advertise gates:
  # a by-name dispatch still runs the execute-time `Harness.Authorization` gate.
  @client_owned_channels ["acp"]

  @doc """
  Whether this turn's channel can carry a coding run at all — the harness half of
  every harness tool's `advertise?/1`.

  One definition for the whole family: the gate is a property of the FEATURE, not
  of a tool, so a harness tool added later inherits it by calling this rather than
  re-deriving the channel list.
  """
  @spec advertisable_channel?(map()) :: boolean()
  def advertisable_channel?(context) when is_map(context) do
    Map.get(context, :channel) not in @client_owned_channels
  end

  @spec repo(map()) :: term()
  def repo(context), do: Map.get(context, :memory_repo, Repo)

  @doc """
  The launching turn's completion-continuation depth (design §23.2), threaded from
  the continuation message's metadata by `TurnRunner`. Zero for an owner-typed
  turn and for any context without the key; a non-integer or negative value is
  read as zero (the depth cap must never widen on malformed context).
  """
  @spec continuation_depth(map()) :: non_neg_integer()
  def continuation_depth(context) when is_map(context) do
    case Map.get(context, :harness_continuation_depth) do
      depth when is_integer(depth) and depth > 0 -> depth
      _absent_or_zero -> 0
    end
  end

  @spec success_json(term()) :: {:ok, Tool.tool_result()}
  def success_json(value), do: {:ok, Tool.success(Jason.encode!(value))}

  @spec error(term()) :: {:ok, Tool.tool_result()}
  def error(reason), do: {:ok, Tool.error(format_error(reason))}

  @spec required_string(map(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def required_string(args, key) do
    case Map.fetch(args, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_param, key}}
      :error -> {:error, {:missing_param, key}}
    end
  end

  @doc """
  Reads a string-enum option, mapping it to its atom via `table`. Absent → the
  default atom; an unknown value is rejected.
  """
  @spec optional_enum(map(), String.t(), %{optional(String.t()) => atom()}, atom()) ::
          {:ok, atom()} | {:error, term()}
  def optional_enum(args, key, table, default) do
    case Map.get(args, key) do
      nil -> {:ok, default}
      value -> lookup_enum(table, key, value)
    end
  end

  defp lookup_enum(table, key, value) do
    case Map.fetch(table, value) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, {:invalid_option, key}}
    end
  end

  @doc """
  Reads a bounded integer option: absent → `default`; below `floor` or a
  non-integer → rejected; above `cap` → clamped to `cap` (a documented ceiling,
  not a fallback branch).
  """
  @spec optional_capped_int(map(), String.t(), integer(), integer(), integer()) ::
          {:ok, integer()} | {:error, term()}
  def optional_capped_int(args, key, default, floor, cap) do
    case Map.get(args, key) do
      nil -> {:ok, default}
      value when is_integer(value) and value >= floor -> {:ok, min(value, cap)}
      _value -> {:error, {:invalid_option, key}}
    end
  end

  @doc """
  Builds the vendor `params` map from the model's string-keyed JSON `args`.

  `reserved` are the tool-owned keys (prompt/cwd/shared opts) dropped first;
  every remaining key must appear in `key_table` (a fixed string → atom map, so
  no `String.to_atom` ever runs) or the build fails loud with
  `{:unknown_param, key}`. The adapter's own `reject_unknown` is defense in
  depth — the tool boundary catches typos first.
  """
  @spec vendor_params(map(), %{optional(String.t()) => atom()}, [String.t()]) ::
          {:ok, map()}
          | {:error, {:unknown_param, String.t()} | {:boundary_removing_param, atom(), term()}}
  def vendor_params(args, key_table, reserved) do
    args
    |> Map.drop(reserved)
    |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case Map.fetch(key_table, key) do
        {:ok, atom} -> take_param(acc, atom, value)
        :error -> {:halt, {:error, {:unknown_param, key}}}
      end
    end)
  end

  defp take_param(acc, atom, value) do
    if value in Map.get(@boundary_removing, atom, []) do
      {:halt, {:error, {:boundary_removing_param, atom, value}}}
    else
      {:cont, {:ok, Map.put(acc, atom, value)}}
    end
  end

  @doc "The model-visible, JSON-safe summary of one harness run row."
  @spec run_summary(map()) :: map()
  def run_summary(row) when is_map(row) do
    %{
      id: Map.get(row, :id),
      vendor: Map.get(row, :vendor),
      rail: Map.get(row, :rail),
      status: Map.get(row, :status),
      reason: Map.get(row, :reason),
      cwd: Map.get(row, :cwd),
      resumable: Map.get(row, :resumable),
      origin_kind: Map.get(row, :origin_kind),
      parent_job_id: Map.get(row, :parent_job_id),
      vendor_session_id: Map.get(row, :vendor_session_id),
      task_url: Map.get(row, :task_url),
      delivery_status: Map.get(row, :delivery_status),
      created_at: iso(Map.get(row, :created_at)),
      started_at: iso(Map.get(row, :started_at)),
      completed_at: iso(Map.get(row, :completed_at))
    }
  end

  @doc """
  The full run payload for `get_coding_run`: the summary plus diagnostics tail,
  usage, exit/framing detail, artifact paths, and durable delivery state.

  `vendor_text` is the run's harvested text (read by the caller through
  `Artifacts.read_result/1`, so the I/O stays visible at the call site). It is
  bounded and exposed as `result_tail` because a run polled instead of awaited must
  still yield its diagnosis: a claude auth failure reaches the ledger as a bare
  `exit_1` with an empty diagnostics tail, and without this the polling path is the
  one surface where the vendor's own explanation stays invisible.
  """
  @spec run_payload(map(), String.t() | nil) :: map()
  def run_payload(row, vendor_text \\ nil) when is_map(row) do
    row
    |> run_summary()
    |> Map.put(:result_tail, frame_result_tail(bound_text(vendor_text)))
    |> Map.merge(%{
      exit_code: Map.get(row, :exit_code),
      framing_errors: Map.get(row, :framing_errors),
      artifact_truncated: Map.get(row, :artifact_truncated),
      usage: Map.get(row, :usage),
      diagnostics_tail: Map.get(row, :diagnostics_tail),
      artifacts_dir: Map.get(row, :artifacts_dir),
      worktree_root: Map.get(row, :worktree_root),
      task_id: Map.get(row, :task_id),
      next_poll_at: iso(Map.get(row, :next_poll_at)),
      poll_deadline: iso(Map.get(row, :poll_deadline)),
      delivery_attempts: Map.get(row, :delivery_attempts),
      last_delivery_error: Map.get(row, :last_delivery_error),
      delivered_at: iso(Map.get(row, :delivered_at))
    })
  end

  @doc """
  Reads `row`'s harvested text off disk for the polling path. Separate from
  `run_payload/2` so the file read is visible where it happens rather than hidden
  inside a formatter.
  """
  @spec read_run_text(map()) :: String.t() | nil
  def read_run_text(row) when is_map(row), do: Artifacts.read_result(Map.get(row, :artifacts_dir))

  defp bound_text(nil), do: nil
  defp bound_text(text) when byte_size(text) <= @result_tail_max, do: text
  defp bound_text(text), do: utf8_prefix(text, @result_tail_max) <> "\n… [truncated]"

  # The same bytes the continuation notice frames: the vendor CLI's own text,
  # derived from the repo, issue and web content the run read. `get_coding_run`
  # is `:read_only` and plugin-less, so `UntrustedContent.wrap/2` passes its
  # output through untouched — without this the identical stream reaches the
  # model unframed simply because it was polled instead of awaited, which is the
  # drift a single boundary exists to prevent.
  defp frame_result_tail(nil), do: nil
  defp frame_result_tail(""), do: ""
  defp frame_result_tail(text), do: UntrustedContent.frame(@untrusted_source, text)

  # A byte-wise cut can land inside a multibyte codepoint, and unlike the chat-bound
  # siblings this value is `Jason.encode!`d — invalid UTF-8 would raise and take the
  # whole `get_coding_run` call down, losing the diagnosis it exists to deliver.
  # Bounded by construction: a UTF-8 codepoint is at most 4 bytes, so at most three
  # bytes are ever shaved.
  defp utf8_prefix(text, size) when size > 0 do
    prefix = binary_part(text, 0, size)

    if String.valid?(prefix), do: prefix, else: utf8_prefix(text, size - 1)
  end

  defp utf8_prefix(_text, _size), do: ""

  defp iso(nil), do: nil
  defp iso(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp maybe_put_error(metadata, {:ok, %{success: false, error: error}}) when is_binary(error) do
    Map.put(metadata, :error, error)
  end

  defp maybe_put_error(metadata, {:error, reason}) do
    Map.put(metadata, :error, format_error(reason))
  end

  defp maybe_put_error(metadata, _result), do: metadata

  # --- Error vocabulary ---------------------------------------------------

  defp format_error(message) when is_binary(message), do: message
  defp format_error({:missing_param, key}), do: "Missing required parameter: #{key}"
  defp format_error({:invalid_param, key}), do: "Invalid parameter: #{key}"

  defp format_error({:invalid_param, :attempts, value}),
    do: "Invalid parameter: attempts (expected an integer 1-4, got #{inspect(value)})"

  defp format_error({:invalid_param, key, value}),
    do: "Invalid parameter: #{key} (got #{inspect(value)})"

  defp format_error({:invalid_option, key}), do: "Invalid option: #{key}"
  defp format_error({:unknown_param, key}), do: "Unknown parameter: #{key}"

  # The adapters mint typed param refusals, and without a clause here they reached
  # the model as inspected Elixir (`{:param_not_supported_with_resume, :sandbox}`
  # was delivered verbatim in a live trace) — unreadable as "the vendor cannot do
  # this" rather than "Fermix is broken". Each names the next move, since the
  # caller has to change the call to get anywhere.
  defp format_error({:param_not_supported_with_resume, key}) do
    "#{key} cannot be set when resuming a Codex thread — the resume command has no " <>
      "form for it. Drop #{key} to continue the thread as it stands, or omit `resume` " <>
      "to start a fresh run with it."
  end

  defp format_error(:ephemeral_not_resumable) do
    "An ephemeral run writes no session files, so there is no thread to resume. " <>
      "Drop `ephemeral` to make this run resumable, or drop `resume` to start fresh."
  end

  defp format_error({:invalid_sandbox, value}) do
    "Invalid sandbox mode: #{inspect(value)}. Selectable modes are `read-only` and " <>
      "`workspace-write`; omit the parameter to use the operator's configured posture."
  end

  # Claude Code's own three. `--resume` there is a flat option that coexists with
  # every other flag, so it has no "not supported with resume" class — but it does
  # mint its own enum and mutual-exclusion refusals, which leaked the same way.
  defp format_error({:invalid_effort, value}) do
    "Invalid effort: #{inspect(value)}. Levels are `low`, `medium`, `high`, `xhigh` " <>
      "and `max`; omit the parameter to use the model's default."
  end

  defp format_error({:invalid_permission_mode, value}) do
    "Invalid permission mode: #{inspect(value)}. Modes are `acceptEdits`, `auto`, " <>
      "`manual`, `dontAsk` and `plan`; omit the parameter to use the operator's " <>
      "configured posture."
  end

  defp format_error(:resume_and_continue) do
    "`resume` names one session and `continue` picks the most recent, so they cannot " <>
      "be combined. Keep `resume` with the session id, or drop it and use `continue` alone."
  end

  # Shared by both adapters, and the most reachable of this family: any path-bearing
  # param (`add_dirs`, `images`, `append_system_prompt_file`) the model names outside
  # the granted roots lands here. Names the param, then the way to widen the roots —
  # a bare reason tuple told the model neither.
  defp format_error({:path_denied, key, reason}),
    do: "#{key}: #{format_path_reason(reason)}"

  defp format_error(:missing_cwd),
    do: "A coding run needs a working directory; none was resolved for this call."

  # Name the value AND the way forward: the model's next move is to drop the
  # param (inheriting the operator's configured posture), not to guess another
  # spelling of the same escalation.
  defp format_error({:boundary_removing_param, key, value}) do
    "#{key}: #{inspect(value)} is not selectable — it would remove the sandbox " <>
      "this run's directories were admitted into. Omit the parameter to use the " <>
      "operator's configured posture, or choose a confining level."
  end

  defp format_error(:worker_context),
    do: "Coding-harness runs are not available to delegated subagents."

  defp format_error(:guest_context),
    do: "Coding-harness runs are available to the owner only."

  defp format_error(:unattended),
    do:
      "Coding-harness runs need a live attended operator turn " <>
        "(no reply surface is available here)."

  defp format_error(:cron_not_allowlisted),
    do:
      "This scheduled job is not authorized for coding-harness runs — " <>
        "add the tool name to the job's allowed_tools."

  defp format_error(:missing_job_id), do: "Scheduled context is missing its job id."
  defp format_error({:job_lookup_failed, reason}), do: "Job lookup failed: #{inspect(reason)}"

  # An unapproved machine advertises no run tool (design §23.4), so this refusal
  # is only reachable by a by-name dispatch — it must never dead-end the caller.
  # The owner-facing approval guidance is followed by the model's next move: do
  # the work directly with the ordinary file/shell tools (guidance inside an
  # error, not a second code path).
  defp format_error(:consent_required),
    do: Consent.scheduled_guidance() <> " " <> @proceed_directly

  defp format_error(:missing_session),
    do: "This turn has no session id, so a coding run cannot be correlated."

  defp format_error(:not_found), do: "No coding run found for that id."
  defp format_error(:already_terminal), do: "That coding run has already finished."
  defp format_error(:timeout), do: "Timed out waiting for the coding run."
  defp format_error(:max_active), do: "The coding-harness is at its concurrent-run limit."
  defp format_error(:cli_unavailable), do: "The vendor CLI is not installed or not on PATH."
  defp format_error({:workspace_locked, root}), do: "Another run is active in #{root}."
  # Three distinct causes; collapsing them into "quota is full" sent the model
  # (and the owner) after the wrong problem when the real one was a failed
  # free-space probe or a low disk.
  defp format_error({:artifact_quota, %{kind: :quota_exceeded} = detail}),
    do:
      "The coding-harness artifact store is full " <>
        "(#{gb(detail[:used_bytes])} used of #{gb(detail[:quota_bytes])}) — " <>
        "old run artifacts need clearing or the quota raising."

  defp format_error({:artifact_quota, %{kind: :below_min_free} = detail}),
    do:
      "Disk free space (#{gb(detail[:free_bytes])}) is below the coding-harness " <>
        "floor of #{gb(detail[:min_free_bytes])} — free up disk space."

  defp format_error({:artifact_quota, %{kind: :free_space_unknown, reason: reason}}),
    do: "Could not determine free disk space for coding-harness artifacts: #{inspect(reason)}."

  defp format_error({:artifact_quota, detail}),
    do: "Coding-harness artifact storage is unavailable: #{inspect(detail)}."

  defp format_error(:query_too_large),
    do:
      "The query is too large to submit — cloud runs send it as one argument and cannot spill it to a file."

  defp format_error(:not_cloud),
    do: "That is not a cloud run — stop_tracking_coding_run only applies to Codex cloud runs."

  defp format_error({:vendor_cancel_unsupported, task_url}),
    do:
      "Codex cloud tasks cannot be cancelled from Fermix (the vendor has no cancel surface). " <>
        "Use stop_tracking_coding_run to stop tracking; the task keeps running on ChatGPT" <>
        cloud_task_pointer(task_url)

  defp format_error(reason), do: inspect(reason)

  # Only the two denials a harness path param actually produces. The sandbox's
  # reason set is open, so an unrecognized one still says what happened and which
  # param — it just cannot name the remedy. (Several tools carry their own private
  # copy of a fuller ladder; unifying them is its own change, not this one.)
  defp format_path_reason({:outside_root, path}) do
    "#{path} is outside the sandbox roots. Call request_directory_access to ask the " <>
      "owner to approve it, or have them run: fermix grant path #{Path.dirname(path)}"
  end

  defp format_path_reason({:protected_path, path}),
    do: "#{path} is protected by the sandbox and cannot be opened to a coding run."

  defp format_path_reason(reason), do: "path denied by the sandbox — #{inspect(reason)}"

  defp cloud_task_pointer(url) when is_binary(url) and url != "", do: ": #{url}"
  defp cloud_task_pointer(_url), do: "."

  # Byte counts here are only ever read by a human or the model, so render them
  # readably rather than as raw bytes.
  defp gb(bytes) when is_integer(bytes) and bytes >= 0,
    do: :erlang.float_to_binary(bytes / 1_073_741_824, decimals: 1) <> " GB"

  defp gb(_unknown), do: "an unknown amount"
end
