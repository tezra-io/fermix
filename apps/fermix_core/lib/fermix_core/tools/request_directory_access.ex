defmodule FermixCore.Tools.RequestDirectoryAccess do
  @moduledoc """
  Ask the owner, in-conversation, to approve access to a directory the sandbox
  currently denies (SANDBOX_ACCESS_APPROVAL_FLOW §3). The model calls this only
  when a filesystem op was denied `{:outside_root, path}` and the task genuinely
  needs that directory — not on every incidental denial.

  Fail-closed and owner-gated by construction. The tool runs only inside an
  attended operator turn (operator trust + a live `reply_fn` + the gateway's
  `approval_fn` seam); a cron/unattended/guest run never reaches an approval
  path. It refuses — before prompting the owner — anything the system would
  itself reject (`$HOME` wholesale, `FERMIX_HOME`, `~/.ssh`, OS roots), stores a
  single-use 60 s pending confirmation bound to the owner's conversation origin,
  and pushes the exact canonical path + reason + config diff to the owner via
  `reply_fn`. It is a normal (non-terminal) tool: after the prompt is delivered
  the model finishes the turn with a short acknowledgement, so the turn's reply
  is that text. The owner approves with `/confirm <token>`; on a chat channel the
  original request auto-resumes.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Sandbox.Config
  alias FermixCore.Sandbox.ConfigMutation
  alias FermixCore.Sandbox.Mode
  alias FermixCore.Sandbox.PathPolicy
  alias FermixCore.Tools.Support

  @unattended_error "directory access requests need an attended owner conversation"

  @impl true
  @spec name() :: String.t()
  def name, do: "request_directory_access"

  @impl true
  @spec description() :: String.t()
  def description do
    "Ask the owner to approve access to a directory the sandbox denies. Use only " <>
      "after a filesystem op was denied for being outside the sandbox roots AND the " <>
      "task genuinely needs that directory. The owner confirms in chat, then the request resumes."
  end

  @impl true
  @spec parameters() :: map()
  def parameters do
    %{
      type: "object",
      required: ["path", "reason"],
      properties: %{
        path: %{
          type: "string",
          description: "The directory to request access to (the path the sandbox denied)."
        },
        reason: %{
          type: "string",
          description: "A short, honest reason the task needs this directory, shown to the owner."
        }
      }
    }
  end

  @doc """
  Advertise the tool only where a call could execute: an attended, top-level
  operator turn whose context carries both the channel `reply_fn` and the
  gateway `approval_fn` seam. Mirrors `subagents.advertise?/1` — dropped from
  every guest, unattended, or delegated context where a call would fail closed.
  """
  @spec advertise?(map()) :: boolean()
  def advertise?(context) when is_map(context) do
    Map.get(context, :source_trust) == :operator and
      is_function(Map.get(context, :reply_fn), 1) and
      is_function(Map.get(context, :approval_fn), 1) and
      Map.get(context, :subagent_depth, 0) == 0
  end

  # Intentionally NOT terminal (no `terminal?/0`): a terminal empty completion
  # would trip the queue's "I didn't get a response" retry, because the owner
  # prompt is a text side-effect the empty-completion ledger never records
  # (only `:react`/`:media`). Staying non-terminal also lets the already-allowed
  # and already-pending branches continue the loop so the model acts on their
  # guidance. The turn ends normally with the model's short acknowledgement.

  @impl true
  def when_to_use do
    "When a file/shell op was denied for being outside the sandbox roots and the " <>
      "task truly needs that directory. Ask the owner to approve it once, in chat."
  end

  @impl true
  def examples do
    [
      %{
        args: %{
          "path" => "/Users/me/repos/acme",
          "reason" => "The refactor spans this repo, which is outside the current sandbox roots."
        },
        note: "request access to a repo the task needs"
      }
    ]
  end

  @impl true
  def failure_modes do
    [
      %{
        tag: "not_attended",
        description: "no operator conversation / approval surface is available"
      },
      %{
        tag: "unsafe_root",
        description: "the path is one the system refuses to grant (e.g. $HOME, ~/.ssh)"
      },
      %{
        tag: "already_allowed",
        description: "the path is already reachable — just retry the operation"
      }
    ]
  end

  @impl true
  def requires_setup, do: nil

  @impl true
  def category, do: :system

  @impl true
  @spec execute(map(), Tool.context()) :: {:ok, Tool.tool_result()}
  def execute(args, context) when is_map(args) and is_map(context) do
    Support.run(name(), context, fn -> do_execute(args, context) end)
  end

  defp do_execute(args, context) do
    with {:ok, path} <- Support.required_string(args, "path"),
         {:ok, reason} <- Support.required_string(args, "reason"),
         :ok <- gate(context) do
      process_request(canonicalize(path), reason, context)
    else
      {:error, message} -> {:ok, Tool.error(message)}
    end
  end

  # Fail-closed, single message for every unattended condition (§3.2 gate 1):
  # unattended/cron/guest runs never learn there is an approval path.
  defp gate(context) do
    if attended_operator?(context), do: :ok, else: {:error, @unattended_error}
  end

  defp attended_operator?(context) do
    Map.get(context, :source_trust) == :operator and
      is_function(Map.get(context, :reply_fn), 1) and
      is_function(Map.get(context, :approval_fn), 1)
  end

  defp process_request(canonical, reason, context) do
    current = Config.current()

    if already_allowed?(canonical, context) do
      {:ok,
       Tool.success(
         "Access to #{canonical} is already allowed — no approval needed; retry the operation."
       )}
    else
      validate_and_request(canonical, reason, context, current)
    end
  end

  # Dry-run the mutation so the owner is never prompted for something the system
  # would refuse (§3.2 gate 2). `{:unsafe_root, _}` and any other validation error
  # short-circuit to a plain refusal.
  defp validate_and_request(canonical, reason, context, current) do
    case ConfigMutation.apply(current, {:add_allowed_root, canonical}, dry_run: true) do
      {:ok, proposed} ->
        request_owner_approval(canonical, reason, context, current, proposed)

      {:error, {:unsafe_root, root}} ->
        {:ok, Tool.error(unsafe_message(root))}

      {:error, reason} ->
        {:ok, Tool.error("Cannot request access to #{canonical}: #{format_reason(reason)}")}
    end
  end

  defp request_owner_approval(canonical, reason, context, current, proposed) do
    approval_fn = Map.fetch!(context, :approval_fn)
    diff = ConfigMutation.diff(current, proposed)

    case approval_fn.(%{path: canonical, reason: reason, diff: diff}) do
      {:ok, token, :existing} ->
        {:ok,
         Tool.success(
           "Access to #{canonical} is already pending the owner's approval (token #{token}). " <>
             "Stop and wait for them to /confirm it."
         )}

      {:ok, token, :new} ->
        deliver_prompt(context, canonical, reason, diff, token)

        {:ok,
         Tool.success(
           "Requested the owner's approval for #{canonical} (token #{token}). " <>
             "Stop now and wait — the request resumes automatically once they /confirm it."
         )}
    end
  end

  defp deliver_prompt(context, canonical, reason, diff, token) do
    reply_fn = Map.fetch!(context, :reply_fn)
    reply_fn.({:text, owner_prompt(canonical, reason, diff, token)})
    :ok
  end

  defp owner_prompt(canonical, reason, diff, token) do
    """
    I need access to a directory outside the current sandbox roots:

    Path: #{canonical}
    Reason: #{reason}

    #{diff}

    Approve with /confirm #{token} (expires in 60s). Once you confirm, I'll resume automatically.
    """
    |> String.trim()
  end

  defp canonicalize(path) do
    path |> Path.expand() |> PathPolicy.canonical_path()
  end

  # Is the canonical path already reachable under the live sandbox decision,
  # honoring the operator turn's request cwd (`context.cwd`)? Read-only classify —
  # no deny telemetry — so an "already allowed" short-circuit is silent.
  defp already_allowed?(canonical, context) do
    config = Config.current()
    protected = PathPolicy.protected_paths(config)
    effective = Mode.effective_roots(config, Map.get(context, :cwd))
    PathPolicy.allowed_path?(canonical, config, protected, effective) == :ok
  end

  defp unsafe_message(root) do
    "I can't request access to #{root} — the sandbox refuses to grant it (it's a " <>
      "protected or system location). Pick a specific project directory instead."
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
