defmodule FermixCore.Sandbox do
  @moduledoc """
  Public enforcement entrypoint for the local workspace sandbox.
  """

  alias FermixCore.Capabilities.Capability
  alias FermixCore.Sandbox.Config
  alias FermixCore.Sandbox.Decision
  alias FermixCore.Sandbox.Env
  alias FermixCore.Sandbox.Hardline
  alias FermixCore.Sandbox.Mode
  alias FermixCore.Sandbox.PathPolicy

  @type decision :: Decision.decision()

  @spec enforce(Capability.policy_class(), map(), map()) :: decision()
  def enforce(policy_class, request, context)
      when is_atom(policy_class) and is_map(request) and is_map(context) do
    request
    |> do_enforce(config_from(context))
    |> Decision.emit(metadata(policy_class, request, context))
  end

  @spec shell_plan(String.t(), String.t() | nil, map()) ::
          {:ok, %{working_dir: String.t(), env: [{String.t(), String.t()}]}} | {:error, term()}
  def shell_plan(command, requested_dir, context) when is_binary(command) and is_map(context) do
    config = config_from(context)
    protected_roots = PathPolicy.protected_paths(config)
    effective_roots = effective_roots_for(config, context)

    with :allow <- hardline_decision(command, context),
         {:ok, working_dir} <-
           resolve_working_dir(requested_dir, config, context, protected_roots, effective_roots),
         :allow <- enforce_exec(working_dir, context, config, protected_roots, effective_roots),
         {:ok, env} <- Env.build(config) do
      {:ok, %{working_dir: working_dir, env: env}}
    else
      {:hardline, reason} -> {:error, {:hardline, reason}}
      {:deny, reason} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Classify a `shell_plan/3` error as typed proof that policy stopped the request
  before it began, or `nil` when it is not a policy denial.

  Named for the *phase*, not the reason: a caller may only stamp
  `phase: "pre_execution"` where it can prove nothing has run yet. Error text is
  not proof — a command that genuinely executed and exited non-zero also produces
  error text — so consumers key off this marker and nothing else.

  `nil` is the load-bearing negative answer, not a swallowed error: a missing
  working directory, an `Env.build/1` failure, or a malformed request are real
  failures that are *not* policy denials, and must stay untyped.
  """
  @spec pre_execution_denial(term()) :: map() | nil
  def pre_execution_denial({:hardline, _reason}),
    do: %{source: "sandbox", decision: "hardline", phase: "pre_execution"}

  def pre_execution_denial({tag, _resource})
      when tag in [:outside_root, :protected_path, :blocked_root],
      do: %{source: "sandbox", decision: "deny", phase: "pre_execution"}

  def pre_execution_denial(_other), do: nil

  @spec write_path(String.t(), atom(), map()) :: {:ok, String.t()} | {:error, term()}
  def write_path(path, operation, context)
      when is_binary(path) and is_atom(operation) and is_map(context) do
    config = config_from(context)
    protected_roots = PathPolicy.protected_paths(config)
    effective_roots = effective_roots_for(config, context)

    with {:ok, resolved} <-
           PathPolicy.resolve_write_path(path, config, context, protected_roots, effective_roots),
         :allow <-
           path_enforce(
             :read_write,
             operation,
             resolved,
             context,
             config,
             protected_roots,
             effective_roots
           ) do
      {:ok, resolved}
    else
      {:deny, reason} -> {:error, reason}
      {:error, reason} -> emit_denied(:read_write, reason, operation, context)
    end
  end

  @spec read_path(String.t(), atom(), map()) :: {:ok, String.t()} | {:error, term()}
  def read_path(path, operation, context)
      when is_binary(path) and is_atom(operation) and is_map(context) do
    config = config_from(context)
    protected_roots = PathPolicy.protected_paths(config)
    effective_roots = effective_roots_for(config, context)

    with {:ok, resolved} <-
           PathPolicy.resolve_read_path(path, config, context, protected_roots, effective_roots),
         :allow <-
           path_enforce(
             :read_only,
             operation,
             resolved,
             context,
             config,
             protected_roots,
             effective_roots
           ) do
      {:ok, resolved}
    else
      {:deny, reason} -> {:error, reason}
      {:error, reason} -> emit_denied(:read_only, reason, operation, context)
    end
  end

  @doc """
  Batch read-path gate for tools that validate many candidates from one search
  (`content_search`/`glob_search`). Resolves config, protected roots, effective
  roots, and the working-dir base ONCE, then validates each candidate against
  them — the batch form of `read_path/3` that removes the per-candidate root-set
  recompute (the L-2b syscall storm) without weakening the gate.

  Returns the input paths that pass, in input order. Each candidate is still
  individually symlink/case resolved and containment-checked, and still fails
  CLOSED on a canonicalization error. Denied candidates still emit a
  `[:fermix, :sandbox, :decision]` deny, preserving the `:sandbox_event`
  security-audit trace; the per-candidate ALLOW emit is intentionally dropped
  (`DecisionTelemetry` ignores allow, and it is the redundant per-file dispatch
  this batch path exists to remove).
  """
  @spec read_paths([String.t()], atom(), map()) :: [String.t()]
  def read_paths(paths, operation, context)
      when is_list(paths) and is_atom(operation) and is_map(context) do
    config = config_from(context)
    protected_roots = PathPolicy.protected_paths(config)
    effective_roots = effective_roots_for(config, context)

    case PathPolicy.resolve_working_dir(
           Map.get(context, :cwd),
           config,
           context,
           protected_roots,
           effective_roots
         ) do
      {:ok, base} ->
        Enum.filter(
          paths,
          &candidate_allowed?(
            &1,
            base,
            operation,
            context,
            config,
            protected_roots,
            effective_roots
          )
        )

      {:error, _reason} ->
        # The working-dir base is unresolvable (e.g. a missing configured cwd),
        # so every candidate would be denied — return none. This omits the N
        # identical per-candidate working-dir denies the self-resolving path
        # would emit; that reason is operational (missing_working_dir), not a
        # protected/outside-root security signal.
        []
    end
  end

  @spec working_dir(String.t() | nil, atom(), map()) :: {:ok, String.t()} | {:error, term()}
  def working_dir(path, operation, context) when is_atom(operation) and is_map(context) do
    config = config_from(context)
    protected_roots = PathPolicy.protected_paths(config)
    effective_roots = effective_roots_for(config, context)

    with {:ok, resolved} <-
           PathPolicy.resolve_working_dir(path, config, context, protected_roots, effective_roots),
         :allow <-
           path_enforce(
             :read_write,
             operation,
             resolved,
             context,
             config,
             protected_roots,
             effective_roots
           ) do
      {:ok, resolved}
    else
      {:deny, reason} -> {:error, reason}
      {:error, reason} -> emit_denied(:read_write, reason, operation, context)
    end
  end

  defp do_enforce(%{operation: operation, working_dir: dir}, config)
       when operation in [:shell, :command_capability] and is_binary(dir),
       do: path_decision(dir, config)

  defp do_enforce(%{path: path}, config) when is_binary(path) do
    path_decision(path, config)
  end

  defp do_enforce(_request, _config), do: {:deny, :invalid_request}

  defp path_decision(path, config) do
    case PathPolicy.allowed_path?(path, config) do
      :ok -> :allow
      {:error, reason} -> {:deny, reason}
    end
  end

  # Exec decision for shell_plan: reuses the config + root sets already resolved
  # for the working-dir decision instead of re-resolving via enforce/3.
  defp enforce_exec(working_dir, context, config, protected_roots, effective_roots) do
    request = %{operation: :shell, working_dir: working_dir}

    working_dir
    |> path_decision(config, protected_roots, effective_roots)
    |> Decision.emit(metadata(:exec, request, context))
  end

  # Enforcement for read/write/working-dir reusing the config + root sets the
  # caller already resolved for this call, instead of re-deriving them via
  # enforce/3 → config_from → allowed_path?/2 (which recomputes both root sets).
  # Same decision, same single Decision.emit — the shell_plan/enforce_exec
  # precomputed-roots pattern applied to the path tools.
  defp path_enforce(
         policy_class,
         operation,
         path,
         context,
         config,
         protected_roots,
         effective_roots
       ) do
    request = %{operation: operation, path: path}

    path
    |> path_decision(config, protected_roots, effective_roots)
    |> Decision.emit(metadata(policy_class, request, context))
  end

  defp path_decision(path, config, protected_roots, effective_roots) do
    case PathPolicy.allowed_path?(path, config, protected_roots, effective_roots) do
      :ok -> :allow
      {:error, reason} -> {:deny, reason}
    end
  end

  # One candidate of a batch `read_paths/3`: resolve it under the already-resolved
  # base and gate it against the hoisted root sets. Preserves read_path's
  # fail-closed behavior (a canonicalization error → deny → excluded) and its
  # deny telemetry; the allow branch skips the emit (see read_paths/3 doc).
  defp candidate_allowed?(
         path,
         base,
         operation,
         context,
         config,
         protected_roots,
         effective_roots
       ) do
    case PathPolicy.check_under_base(path, base, config, protected_roots, effective_roots) do
      {:ok, _resolved} ->
        true

      {:error, reason} ->
        Decision.emit({:deny, reason}, metadata(:read_only, %{operation: operation}, context))
        false
    end
  end

  defp hardline_decision(command, context) do
    case Hardline.classify(command) do
      :allow ->
        :allow

      {:hardline, reason} ->
        Decision.emit({:hardline, reason}, metadata(:exec, %{operation: :shell}, context))
    end
  end

  defp resolve_working_dir(requested_dir, config, context, protected_roots, effective_roots) do
    case PathPolicy.resolve_working_dir(
           requested_dir,
           config,
           context,
           protected_roots,
           effective_roots
         ) do
      {:ok, dir} ->
        {:ok, dir}

      {:error, reason} ->
        Decision.emit({:deny, reason}, metadata(:exec, %{operation: :shell}, context))
        {:error, reason}
    end
  end

  defp emit_denied(policy_class, reason, operation, context) do
    Decision.emit({:deny, reason}, metadata(policy_class, %{operation: operation}, context))
    {:error, reason}
  end

  defp config_from(%{sandbox_config: config}), do: Config.normalize(config)
  defp config_from(_context), do: Config.current()

  # Effective roots for a context-bearing tool operation, threading the turn's
  # request cwd (`context.cwd`, set only for a trusted operator origin) into
  # standard-mode admission. Context-free callers (CLI `sandbox explain`,
  # ConfigMutation validation) use `Mode.effective_roots/1` directly.
  defp effective_roots_for(config, context) do
    Mode.effective_roots(config, Map.get(context, :cwd))
  end

  defp metadata(policy_class, request, context) do
    %{
      policy_class: policy_class,
      operation: Map.get(request, :operation, :unknown),
      agent: Map.get(context, :agent_name, "unknown"),
      conversation_key: Map.get(context, :conversation_key)
    }
  end
end
