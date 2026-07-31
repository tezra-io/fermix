defmodule FermixCore.Tools.HarnessRun do
  @moduledoc false

  # The shared execute flow for the two run tools (`codex_run`,
  # `claude_code_run`), which differ only in vendor tag, adapter module, and
  # accepted vendor params. The anatomy (spec §6): authorize → cwd working-dir
  # sandbox check → build vendor params/opts → resolve the delivery snapshot →
  # `Manager.start_run` → return the run id immediately. Runs are background-only
  # (design §23.1): there is no inline path and no wait window, so the launch
  # result tells the model to end its turn and never poll. All GenServer reach is
  # context-injectable (`:harness_manager`) so tool tests stub the manager.

  alias FermixCore.Harness.Authorization
  alias FermixCore.Harness.Config
  alias FermixCore.Harness.Consent
  alias FermixCore.Harness.Delivery
  alias FermixCore.Harness.Manager
  alias FermixCore.Sandbox
  alias FermixCore.Tools.HarnessSupport, as: Support

  @reserved ~w(prompt cwd timeout_minutes progress)
  @progress_table %{"quiet" => :quiet, "milestones" => :milestones}
  @end_turn " — end your turn now. Do not poll get_coding_run and do not wait for it."

  @type spec :: %{
          name: String.t(),
          vendor: String.t(),
          adapter: module(),
          key_table: %{optional(String.t()) => atom()}
        }

  @doc "Runs the full run-tool flow for `spec`, wrapped in the telemetry envelope."
  @spec dispatch(spec(), map(), map()) ::
          {:ok, FermixCore.Capabilities.Builtin.Tool.tool_result()}
  def dispatch(spec, args, context) when is_map(spec) and is_map(args) and is_map(context) do
    Support.run(spec.name, context, fn -> do_dispatch(spec, args, context) end)
  end

  defp do_dispatch(spec, args, context) do
    with :ok <- Authorization.authorize(spec.name, context),
         {:ok, prompt} <- Support.required_string(args, "prompt"),
         {:ok, raw_cwd} <- Support.required_string(args, "cwd"),
         :ok <- ensure_consent(spec, raw_cwd, context),
         {:ok, cwd} <- resolve_cwd(spec, raw_cwd, context),
         {:ok, params} <- Support.vendor_params(args, spec.key_table, @reserved),
         {:ok, opts} <- parse_opts(args),
         {:ok, session_id} <- fetch_session_id(context),
         {:ok, snapshot} <- Delivery.resolve_snapshot(context),
         {:ok, run_id} <-
           start_run(spec, prompt, cwd, params, opts, snapshot, session_id, context) do
      Support.success_json(launched_map(run_id, Map.get(snapshot, :origin_kind)))
    else
      {:error, reason} -> Support.error(reason)
    end
  end

  # --- First-use consent --------------------------------------------------

  # The consent gate (design §23.3), checked after authorization and before any
  # ledger/manager work: a config read, never a prompt. `:consent_required`
  # additionally ledgers `blocked/:consent_required` + delivers for a SCHEDULED
  # origin — the same D8 split the cwd denial uses.
  defp ensure_consent(spec, raw_cwd, context) do
    case Consent.ensure_approved() do
      :ok ->
        :ok

      {:error, :consent_required} = error ->
        maybe_block_scheduled(spec, raw_cwd, :consent_required, context)
        error
    end
  end

  # --- Working directory --------------------------------------------------

  # A cwd denial returns the tool error to the caller; for a SCHEDULED origin the
  # denial is ALSO ledgered `blocked/:workspace_denied` and delivered (spec D8 /
  # design §12.1 — the owner must hear a cron repo was not granted). Attended chat
  # gets the refusal inline in the tool result and no row is written.
  defp resolve_cwd(spec, raw_cwd, context) do
    case Sandbox.working_dir(raw_cwd, :harness_cwd, context) do
      {:ok, cwd} -> {:ok, cwd}
      {:error, reason} -> ledger_scheduled_denial(spec, raw_cwd, reason, context)
    end
  end

  defp ledger_scheduled_denial(spec, raw_cwd, reason, context) do
    # Best-effort owner notification (mirrors delivery/memory write-back): the
    # tool always returns the denial; the ledgered block rides alongside only when
    # the origin is scheduled and its target resolves.
    maybe_block_scheduled(spec, raw_cwd, :workspace_denied, context)
    {:error, reason}
  end

  defp maybe_block_scheduled(spec, raw_cwd, reason, context) do
    with {:ok, snapshot} <- Delivery.resolve_snapshot(context),
         "scheduled" <- Map.get(snapshot, :origin_kind),
         {:ok, session_id} <- fetch_session_id(context) do
      block = %{
        vendor: spec.vendor,
        cwd: raw_cwd,
        snapshot: snapshot,
        origin_session_id: session_id,
        reason: reason
      }

      Manager.block_scheduled(block, manager(context))
    end
  end

  # --- Options ------------------------------------------------------------

  defp parse_opts(args) do
    with {:ok, timeout} <- timeout_minutes(args),
         {:ok, progress} <- Support.optional_enum(args, "progress", @progress_table, :quiet) do
      {:ok, %{timeout_minutes: timeout, progress: progress}}
    end
  end

  defp timeout_minutes(args) do
    Support.optional_capped_int(args, "timeout_minutes", Config.default_timeout_minutes(), 1, 240)
  end

  defp fetch_session_id(context) do
    case Map.get(context, :session_id) do
      id when is_binary(id) and id != "" -> {:ok, id}
      _missing -> {:error, :missing_session}
    end
  end

  # --- Admission ----------------------------------------------------------

  defp start_run(spec, prompt, cwd, params, opts, snapshot, session_id, context) do
    request = %{
      vendor: spec.vendor,
      adapter: spec.adapter,
      prompt: prompt,
      cwd: cwd,
      ctx: plan_ctx(cwd, context),
      params: params,
      snapshot: snapshot,
      origin_session_id: session_id,
      timeout_minutes: opts.timeout_minutes,
      progress: opts.progress,
      # A run launched from a continuation turn inherits depth+1 on its row, so
      # the chain stays bounded (design §23.2). The turn's depth rides the context.
      continuation_depth: Support.continuation_depth(context)
    }

    Manager.start_run(request, manager(context))
  end

  defp plan_ctx(cwd, context) do
    %{cwd: cwd}
    |> maybe_put(:sandbox_config, Map.get(context, :sandbox_config))
    |> maybe_put(:find_executable, Map.get(context, :find_executable))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp manager(context), do: Map.get(context, :harness_manager, Manager)

  # --- Result shaping -----------------------------------------------------

  # Background-only (design §23.1): the launch acknowledgement is the whole
  # result. It says the outcome comes back on its own so the model ends the turn
  # — polling `get_coding_run` is what killed a real turn before this changed.
  # Where it comes back is the origin's own answer (§23.2's two configurations): a
  # chat origin re-enters this conversation, a scheduled one is delivered to the
  # job's frozen target — never promise a continuation an origin does not get.
  defp launched_map(run_id, origin_kind) do
    %{run_id: run_id, status: "launched", detail: launched_detail(origin_kind)}
  end

  defp launched_detail("scheduled") do
    "The coding run is executing in the background. Its outcome is delivered to " <>
      "this job's configured target when it finishes#{@end_turn}"
  end

  defp launched_detail(_chat) do
    "The coding run is executing in the background. It reports back into this " <>
      "conversation on its own when it finishes#{@end_turn}"
  end
end
