defmodule FermixCore.Sandbox do
  @moduledoc """
  Public enforcement entrypoint for the local workspace sandbox.
  """

  alias FermixCore.Capabilities.Capability
  alias FermixCore.Sandbox.Config
  alias FermixCore.Sandbox.Decision
  alias FermixCore.Sandbox.Env
  alias FermixCore.Sandbox.Hardline
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

    with :allow <- hardline_decision(command, context),
         {:ok, working_dir} <- resolve_working_dir(requested_dir, config, context),
         :allow <- enforce(:exec, %{operation: :shell, working_dir: working_dir}, context),
         {:ok, env} <- Env.build(config) do
      {:ok, %{working_dir: working_dir, env: env}}
    else
      {:hardline, reason} -> {:error, {:hardline, reason}}
      {:deny, reason} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec write_path(String.t(), atom(), map()) :: {:ok, String.t()} | {:error, term()}
  def write_path(path, operation, context)
      when is_binary(path) and is_atom(operation) and is_map(context) do
    config = config_from(context)

    with {:ok, resolved} <- PathPolicy.resolve_write_path(path, config, context),
         :allow <- enforce(:read_write, %{operation: operation, path: resolved}, context) do
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

    with {:ok, resolved} <- PathPolicy.resolve_read_path(path, config, context),
         :allow <- enforce(:read_only, %{operation: operation, path: resolved}, context) do
      {:ok, resolved}
    else
      {:deny, reason} -> {:error, reason}
      {:error, reason} -> emit_denied(:read_only, reason, operation, context)
    end
  end

  @spec working_dir(String.t() | nil, atom(), map()) :: {:ok, String.t()} | {:error, term()}
  def working_dir(path, operation, context) when is_atom(operation) and is_map(context) do
    config = config_from(context)

    with {:ok, resolved} <- PathPolicy.resolve_working_dir(path, config, context),
         :allow <- enforce(:read_write, %{operation: operation, path: resolved}, context) do
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

  defp hardline_decision(command, context) do
    case Hardline.classify(command) do
      :allow ->
        :allow

      {:hardline, reason} ->
        Decision.emit({:hardline, reason}, metadata(:exec, %{operation: :shell}, context))
    end
  end

  defp resolve_working_dir(requested_dir, config, context) do
    case PathPolicy.resolve_working_dir(requested_dir, config, context) do
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

  defp metadata(policy_class, request, context) do
    %{
      policy_class: policy_class,
      operation: Map.get(request, :operation, :unknown),
      agent: Map.get(context, :agent_name, "unknown"),
      conversation_key: Map.get(context, :conversation_key)
    }
  end
end
