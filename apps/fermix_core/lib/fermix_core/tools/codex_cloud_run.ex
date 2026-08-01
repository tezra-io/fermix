defmodule FermixCore.Tools.CodexCloudRun do
  @moduledoc """
  Delegate a coding task to a Codex **cloud** run (`codex cloud exec`).

  Unlike the local rail, this submits a fire-and-forget task to a pre-configured
  Codex cloud environment and then tracks it by polling — there is no local
  process, no repository checkout, and no vendor cancel surface. The tool
  authorizes the caller (attended operator or an allowlisted scheduled job),
  resolves where the terminal message must go, and hands the submission to
  `Harness.Manager`. Runs are background-only (design §23.1): the tool returns the
  run id immediately and the outcome comes back on its own — into this
  conversation for a chat origin, as durable delivery for a scheduled one.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Harness.Authorization
  alias FermixCore.Harness.Config
  alias FermixCore.Harness.Consent
  alias FermixCore.Harness.Delivery
  alias FermixCore.Harness.Manager
  alias FermixCore.Tools.HarnessSupport, as: Support

  # Fixed string → atom table (spec C1: no `String.to_atom` on model input). The
  # tool-owned keys are dropped first; anything else (e.g. `timeout_minutes`, which
  # the poll deadline supersedes) is rejected as an unknown parameter.
  @param_keys %{"branch" => :branch, "attempts" => :attempts}
  @reserved ~w(query env_id)

  @impl true
  @spec name() :: String.t()
  def name, do: "codex_cloud_run"

  @impl true
  @spec description() :: String.t()
  def description do
    "Submit a coding task to a Codex cloud environment (codex cloud exec) and " <>
      "track it to completion. Runs in the background; the outcome comes back to " <>
      "this conversation on its own."
  end

  @impl true
  @spec parameters() :: map()
  def parameters do
    %{
      type: "object",
      required: ["query", "env_id"],
      properties: %{
        query: %{
          type: "string",
          description: "The coding task for the Codex cloud run to carry out."
        },
        env_id: %{type: "string", description: "The Codex cloud environment id to run in."},
        branch: %{
          type: "string",
          description: "Optional branch to run against (defaults to the env's)."
        },
        attempts: %{
          type: "integer",
          description: "Optional number of vendor attempts (1-4)."
        }
      }
    }
  end

  @impl true
  def when_to_use do
    "When repo coding work should run in a Codex cloud environment rather than a " <>
      "local checkout — no local repository is touched and there is no cancel; " <>
      "tracking is by polling."
  end

  @impl true
  def examples do
    [
      %{
        args: %{"query" => "Fix the flaky auth test", "env_id" => "proj-web"},
        note: "background cloud run"
      }
    ]
  end

  @impl true
  def failure_modes do
    [
      %{tag: "not_authorized", description: "not an attended operator or allowlisted job"},
      %{
        tag: "consent_required",
        description: "the owner has not yet approved coding-agent launches on this machine"
      },
      %{
        tag: "query_too_large",
        description: "the query exceeds the argv byte cap (no file spillover)"
      },
      %{tag: "cloud_auth", description: "not signed in to ChatGPT for the cloud surface"},
      %{tag: "cli_unavailable", description: "the codex CLI is not installed or not on PATH"}
    ]
  end

  @impl true
  def requires_setup, do: nil

  @impl true
  def category, do: :harness

  @doc """
  Advertise only when the harness is enabled, the owner has approved coding agents
  on this machine (design §23.4 — no dead ends: an unusable harness offers
  nothing and Fermix codes with its own tools), and the authorization gate would
  pass, on a channel that can carry a coding run at all
  (`HarnessSupport.advertisable_channel?/1`). The tool stays dispatchable by name,
  where the execute-time refusal tells the caller to proceed directly.
  """
  @spec advertise?(map()) :: boolean()
  def advertise?(context) when is_map(context) do
    Config.enabled?() and Config.approved?() and
      Support.advertisable_channel?(context) and
      Authorization.authorize(name(), context) == :ok
  end

  @impl true
  @spec execute(map(), Tool.context()) :: {:ok, Tool.tool_result()}
  def execute(args, context) when is_map(args) and is_map(context) do
    Support.run(name(), context, fn -> do_execute(args, context) end)
  end

  defp do_execute(args, context) do
    with :ok <- Authorization.authorize(name(), context),
         {:ok, query} <- Support.required_string(args, "query"),
         {:ok, env_id} <- Support.required_string(args, "env_id"),
         {:ok, extra} <- Support.vendor_params(args, @param_keys, @reserved),
         {:ok, session_id} <- fetch_session_id(context),
         {:ok, snapshot} <- Delivery.resolve_snapshot(context),
         :ok <- ensure_consent(env_id, snapshot, session_id, context),
         {:ok, run_id} <- start_run(query, env_id, extra, snapshot, session_id, context) do
      Support.success_json(launched_map(run_id))
    else
      {:error, reason} -> Support.error(reason)
    end
  end

  # The first-use consent gate (design §23.3), checked after the delivery snapshot
  # is resolved and before any manager work: a config read, never a prompt.
  # `:consent_required` additionally ledgers `blocked/:consent_required` +
  # delivers for a SCHEDULED origin — the cloud analogue of the local rail's D8
  # split.
  defp ensure_consent(env_id, snapshot, session_id, context) do
    case Consent.ensure_approved() do
      :ok ->
        :ok

      {:error, :consent_required} = error ->
        maybe_block_scheduled_consent(env_id, snapshot, session_id, context)
        error
    end
  end

  defp maybe_block_scheduled_consent(env_id, snapshot, session_id, context) do
    if Map.get(snapshot, :origin_kind) == "scheduled" do
      block = %{
        params: %{env_id: env_id},
        snapshot: snapshot,
        origin_session_id: session_id,
        reason: :consent_required
      }

      Manager.block_scheduled_cloud(block, manager(context))
    end
  end

  defp start_run(query, env_id, extra, snapshot, session_id, context) do
    request = %{
      params: Map.merge(%{query: query, env_id: env_id}, extra),
      snapshot: snapshot,
      origin_session_id: session_id,
      ctx: plan_ctx(context),
      # Chain depth of the launching turn, so this run's completion knows whether
      # it may continue the conversation (design §23.2).
      continuation_depth: Support.continuation_depth(context)
    }

    Manager.start_cloud_run(request, manager(context))
  end

  defp plan_ctx(context) do
    case Map.get(context, :find_executable) do
      fun when is_function(fun, 1) -> %{find_executable: fun}
      _absent -> %{}
    end
  end

  defp fetch_session_id(context) do
    case Map.get(context, :session_id) do
      id when is_binary(id) and id != "" -> {:ok, id}
      _missing -> {:error, :missing_session}
    end
  end

  # Background-only (design §23.1): the submission acknowledgement is the whole
  # result — a submit that already failed reaches the owner through the same
  # completion path as any other terminal outcome, so the tool never polls and
  # never waits.
  defp launched_map(run_id) do
    %{
      run_id: run_id,
      status: "launched",
      detail:
        "Submitted to Codex cloud and now tracked in the background. The outcome " <>
          "comes back into this conversation on its own when the task finishes — " <>
          "end your turn now. Do not poll get_coding_run and do not wait for it."
    }
  end

  defp manager(context), do: Map.get(context, :harness_manager, Manager)
end
