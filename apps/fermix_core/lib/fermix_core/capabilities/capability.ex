defmodule FermixCore.Capabilities.Capability do
  @moduledoc """
  Plain-data description of one thing the LLM can call.

  Built-in tools, skill sub-agents, and MCP server tools all surface as
  `%Capability{}` structs so the agent loop, registry, and provider adapters
  see one shape regardless of origin.

  The `executor` is `{module, function, extra_args}`. `execute/3` calls
  `apply(module, function, [args, context | extra_args])`. The struct holds
  no behaviour callbacks — skill and MCP capabilities are constructed from
  runtime data (SKILL.md frontmatter, `tools/list` responses), so a struct
  with a runtime executor reference fits all three kinds.

  Built-in M7 tools populate a stable metadata schema:

    * `:when_to_use` — one-sentence routing hint used by runtime prompt summaries.
    * `:examples` — list of `%{args: map(), note: String.t()}` examples for `tool_help`.
    * `:failure_modes` — list of JSON-safe `%{tag: String.t(), description: String.t()}` maps.
    * `:requires_setup` — `nil` for keyless tools; reserved for future setup-gated built-ins.
    * `:category` — prompt grouping atom such as `:file`, `:web`, `:git`, or `:memory`.
  """

  @type kind :: :builtin | :skill | :mcp
  @type policy_class ::
          :read_only | :read_write | :exec | :network | :external_api | :gui_control
  @type executor :: {module(), atom(), list()}

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          parameters: map(),
          kind: kind(),
          executor: executor(),
          hidden_from_agent?: boolean(),
          policy_class: policy_class(),
          metadata: map()
        }

  @enforce_keys [:name, :description, :parameters, :kind, :executor]
  defstruct [
    :name,
    :description,
    :parameters,
    :kind,
    :executor,
    hidden_from_agent?: false,
    policy_class: :read_only,
    metadata: %{}
  ]

  @valid_kinds [:builtin, :skill, :mcp]
  # `:gui_control` is the computer-use blast class. It carries NO sandbox/path/shell
  # enforcement (there is none to carry — see COMPUTER_USE.md §7.1); it exists purely
  # to label the capability and route it to the §7 action-boundary safety layer. It
  # is granted only to the operator surface (registry.ex) and is deliberately excluded
  # from the subagent worker surface (subagents.ex) so desktop control is never
  # delegated to an unattended worker.
  @valid_policy_classes [:read_only, :read_write, :exec, :network, :external_api, :gui_control]

  @spec new(map()) :: t()
  def new(%{} = attrs) do
    name = fetch_required!(attrs, :name)
    validate_name!(name)
    description = fetch_required!(attrs, :description)
    parameters = fetch_required!(attrs, :parameters)
    validate_parameters!(parameters)
    kind = fetch_required!(attrs, :kind)
    validate_kind!(kind)
    executor = fetch_required!(attrs, :executor)
    validate_executor!(executor)
    policy_class = Map.get(attrs, :policy_class, :read_only)
    validate_policy_class!(policy_class)

    %__MODULE__{
      name: name,
      description: description,
      parameters: parameters,
      kind: kind,
      executor: executor,
      hidden_from_agent?: Map.get(attrs, :hidden_from_agent?, false),
      policy_class: policy_class,
      metadata: Map.get(attrs, :metadata, %{})
    }
  end

  @doc """
  Run the capability. The runtime owns dispatch — adapters never call this.
  """
  @spec execute(t(), map(), map()) :: term()
  def execute(%__MODULE__{executor: {mod, fun, extra}}, args, context)
      when is_map(args) and is_map(context) and is_list(extra) do
    apply(mod, fun, [args, context | extra])
  end

  defp fetch_required!(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "Capability.new/1 missing required field #{inspect(key)}"
    end
  end

  defp validate_name!(name) when is_binary(name) and byte_size(name) > 0, do: :ok

  defp validate_name!(other) do
    raise ArgumentError, "Capability name must be a non-empty string, got: #{inspect(other)}"
  end

  defp validate_parameters!(parameters) when is_map(parameters), do: :ok

  defp validate_parameters!(other) do
    raise ArgumentError,
          "Capability parameters must be a JSON-Schema map, got: #{inspect(other)}"
  end

  defp validate_kind!(kind) when kind in @valid_kinds, do: :ok

  defp validate_kind!(other) do
    raise ArgumentError,
          "Capability kind must be one of #{inspect(@valid_kinds)}, got: #{inspect(other)}"
  end

  defp validate_executor!({mod, fun, extra})
       when is_atom(mod) and is_atom(fun) and is_list(extra),
       do: :ok

  defp validate_executor!(other) do
    raise ArgumentError,
          "Capability executor must be {module, function, extra_args}, got: #{inspect(other)}"
  end

  defp validate_policy_class!(class) when class in @valid_policy_classes, do: :ok

  defp validate_policy_class!(other) do
    raise ArgumentError,
          "Capability policy_class must be one of #{inspect(@valid_policy_classes)}, " <>
            "got: #{inspect(other)}"
  end

  @spec valid_policy_classes() :: [policy_class()]
  def valid_policy_classes, do: @valid_policy_classes
end
