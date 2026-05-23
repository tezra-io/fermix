defmodule FermixCore.Capabilities.Registry do
  @moduledoc """
  Single source of truth for everything the LLM can call.

  Holds `%FermixCore.Capabilities.Capability{}` structs in a protected ETS
  table keyed by `name`. Reads (`list/1,2`, `find/2`) hit ETS directly so
  the agent loop's hot path doesn't go through a GenServer. Writes
  (`register/2`, `unregister_kind/2,3`, `refresh/2`) serialize through the
  GenServer.

  Built-ins are mirrored at boot through `FermixCore.Capabilities.Builtin.from_tool_module/1`.
  MCP server tools register through their own supervisors as they come up.
  Skills live in `FermixCore.Agents.SkillRegistry` and are exposed through
  the generated skill catalog plus `skill_view` / `skill_run`.
  """

  use GenServer

  alias FermixCore.Capabilities.Capability

  @type policy_spec ::
          nil
          | [Capability.policy_class()]
          | [allow: [Capability.policy_class()], deny: [Capability.policy_class()]]

  @type trust :: nil | :operator | :guest

  @type filter ::
          [
            allowed_tools: [String.t()] | nil,
            policy: policy_spec(),
            policy_classes: [Capability.policy_class()] | nil,
            trust: trust(),
            kind: Capability.kind() | :all,
            excluded_categories: [atom()] | nil,
            excluded_names: [String.t()] | nil,
            include_hidden?: boolean()
          ]

  # Default policies per trust level. Single-owner model:
  #
  #   :operator — the human owner (and the system-internal callers that
  #               inherit from the operator's session: voice, CLI,
  #               scheduled jobs, bundled/user-installed skills). Full
  #               capability surface.
  #
  #   :guest    — non-operator humans (currently dormant until
  #               multi-user/group-chat lands) and plugin-loaded skills
  #               whose code the operator did not vet. Read-only only.
  #
  #   nil       — trust not set on this call path. Treated as `:guest`
  #               (least privilege). This is the forgiving safe default:
  #               a forgotten trust degrades the surface rather than
  #               silently granting full access.
  @operator_default_policy [
    allow: [:read_only, :read_write, :exec, :network, :external_api],
    deny: []
  ]
  @guest_default_policy [
    allow: [:read_only],
    deny: [:read_write, :exec, :network, :external_api]
  ]

  # --- Client API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  @spec register(GenServer.server(), Capability.t()) ::
          :ok | {:error, {:duplicate_name, String.t()}}
  def register(server \\ __MODULE__, %Capability{} = capability) do
    GenServer.call(server, {:register, capability})
  end

  @spec unregister(GenServer.server(), String.t()) :: :ok
  def unregister(server \\ __MODULE__, name) when is_binary(name) do
    GenServer.call(server, {:unregister, name})
  end

  @doc """
  Drop every capability of `kind`, optionally scoped by a metadata key/value
  match. Used by `MCP.Supervisor` to clear a single server's tools when its
  client goes down.
  """
  @spec unregister_kind(GenServer.server(), Capability.kind(), keyword()) :: :ok
  def unregister_kind(server \\ __MODULE__, kind, opts \\ []) do
    GenServer.call(server, {:unregister_kind, kind, opts})
  end

  @spec find(GenServer.server(), String.t()) :: {:ok, Capability.t()} | :error
  def find(server \\ __MODULE__, name) when is_binary(name) do
    case :ets.lookup(table_for(server), name) do
      [{^name, capability}] -> {:ok, capability}
      [] -> :error
    end
  end

  @spec list(GenServer.server()) :: [Capability.t()]
  def list(server \\ __MODULE__) do
    list(server, [])
  end

  @spec list(GenServer.server(), filter()) :: [Capability.t()]
  def list(server, opts) when is_list(opts) do
    server
    |> table_for()
    |> :ets.tab2list()
    |> Enum.map(fn {_name, capability} -> capability end)
    |> Enum.sort_by(& &1.name)
    |> apply_filters(opts)
  end

  @doc """
  Return the agent-visible capability catalog with coarse visibility filters.

  This is a semantic wrapper over `list/2` for agent runtimes that declare
  exclusions by capability category instead of maintaining per-tool allowlists.
  """
  @spec list_for(filter()) :: [Capability.t()]
  def list_for(opts \\ []) when is_list(opts) do
    list(__MODULE__, opts)
  end

  @spec list_for(GenServer.server(), filter()) :: [Capability.t()]
  def list_for(server, opts) when is_list(opts) do
    list(server, opts)
  end

  @doc """
  Refresh the capabilities for `kind`. Stage 1 is a no-op stub for `:builtin`
  (built-ins are pinned at app boot). Skill/MCP refresh handlers land in
  their respective stages.
  """
  @spec refresh(GenServer.server(), Capability.kind() | :all) :: :ok
  def refresh(server \\ __MODULE__, kind) do
    GenServer.call(server, {:refresh, kind})
  end

  # --- GenServer ---

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    table = table_name(name)
    :ets.new(table, [:set, :protected, :named_table, read_concurrency: true])
    {:ok, %{table: table, name: name}}
  end

  @impl true
  def handle_call({:register, %Capability{name: name} = capability}, _from, state) do
    case :ets.lookup(state.table, name) do
      [] ->
        :ets.insert(state.table, {name, capability})
        {:reply, :ok, state}

      [{^name, _existing}] ->
        {:reply, {:error, {:duplicate_name, name}}, state}
    end
  end

  def handle_call({:unregister, name}, _from, state) do
    case :ets.lookup(state.table, name) do
      [] ->
        {:reply, :ok, state}

      [{^name, _existing}] ->
        :ets.delete(state.table, name)
        {:reply, :ok, state}
    end
  end

  def handle_call({:unregister_kind, kind, opts}, _from, state) do
    metadata_match = Keyword.get(opts, :metadata, %{})

    state.table
    |> :ets.tab2list()
    |> Enum.each(fn entry -> maybe_unregister(entry, state, kind, metadata_match) end)

    {:reply, :ok, state}
  end

  def handle_call({:refresh, _kind}, _from, state) do
    # Stage 1 placeholder. Stage 3 wires SkillRegistry → CapabilityRegistry
    # for :skill; Stage 5 wires MCP.Supervisor for :mcp.
    {:reply, :ok, state}
  end

  def handle_call(:table_name, _from, state), do: {:reply, state.table, state}

  defp maybe_unregister({_name, %Capability{} = cap}, state, kind, metadata_match) do
    if cap.kind == kind and metadata_matches?(cap.metadata, metadata_match) do
      :ets.delete(state.table, cap.name)
    end
  end

  defp maybe_unregister(_entry, _state, _kind, _metadata_match), do: :ok

  # --- Helpers ---

  defp metadata_matches?(_metadata, empty) when empty == %{}, do: true

  defp metadata_matches?(metadata, match) when is_map(metadata) and is_map(match) do
    Enum.all?(match, fn {key, value} -> Map.get(metadata, key) == value end)
  end

  @spec table_for(GenServer.server()) :: atom()
  defp table_for(server) when is_atom(server), do: table_name(server)

  defp table_for(server) when is_pid(server) do
    GenServer.call(server, :table_name)
  end

  defp table_name(name) when is_atom(name), do: :"#{name}.Table"

  defp apply_filters(capabilities, opts) do
    policy = effective_policy(opts)

    capabilities
    |> apply_kind(Keyword.get(opts, :kind, :all))
    |> apply_policy(policy)
    |> apply_allowlist(Keyword.get(opts, :allowed_tools))
    |> apply_name_exclusion(Keyword.get(opts, :excluded_names))
    |> apply_category_exclusion(Keyword.get(opts, :excluded_categories, []))
    |> apply_hidden_filter(Keyword.get(opts, :include_hidden?, false))
  end

  # Trust/policy filtering is only applied when the caller explicitly
  # asks for it. A `list/2` call with no `:trust`, `:policy`, or
  # `:policy_classes` opt is treated as the storage primitive — return
  # everything registered. The "missing = least privilege" safety
  # default applies to call sites that DO ask for trust filtering but
  # pass `trust: nil` (see `resolve_policy/2`); it does not retroactively
  # filter callers that never asked for a trust gate at all.
  defp effective_policy(opts) do
    cond do
      Keyword.has_key?(opts, :policy_classes) ->
        Keyword.get(opts, :policy_classes)

      Keyword.has_key?(opts, :trust) or Keyword.has_key?(opts, :policy) ->
        resolve_policy(Keyword.get(opts, :trust), Keyword.get(opts, :policy))

      true ->
        nil
    end
  end

  @doc """
  Resolve the effective policy filter from `(trust, policy)`.

  An explicit `policy` (non-empty list) always wins. When `policy` is
  unset or empty, fall back to the default for the trust level:
  `:operator` is unfiltered (full surface), `:guest` is read-only.
  `nil` is treated as `:guest` so any call path that forgot to set
  trust fails safe rather than silently granting the full surface.
  """
  @spec resolve_policy(trust(), policy_spec()) :: policy_spec()
  def resolve_policy(_trust, policy) when is_list(policy) and policy != [], do: policy
  def resolve_policy(:operator, _policy), do: @operator_default_policy
  def resolve_policy(:guest, _policy), do: @guest_default_policy
  def resolve_policy(nil, _policy), do: @guest_default_policy

  defp apply_kind(capabilities, :all), do: capabilities

  defp apply_kind(capabilities, kind) when kind in [:builtin, :skill, :mcp] do
    Enum.filter(capabilities, &(&1.kind == kind))
  end

  defp apply_policy(capabilities, nil), do: capabilities

  defp apply_policy(capabilities, policy) when is_list(policy) do
    {allow, deny} = normalize_policy(policy)

    validate_policy_classes!(allow, :allow)
    validate_policy_classes!(deny, :deny)

    Enum.filter(capabilities, fn %Capability{policy_class: class} ->
      class in allow and class not in deny
    end)
  end

  defp normalize_policy(policy) do
    if Keyword.keyword?(policy) and
         (Keyword.has_key?(policy, :allow) or Keyword.has_key?(policy, :deny)) do
      {Keyword.get(policy, :allow, Capability.valid_policy_classes()),
       Keyword.get(policy, :deny, [])}
    else
      # bare list of classes acts as the allow set, no denies
      {policy, []}
    end
  end

  defp validate_policy_classes!(classes, key) do
    valid = Capability.valid_policy_classes()

    Enum.each(classes, fn class ->
      unless class in valid do
        raise ArgumentError,
              "Capabilities.Registry.list/2 #{key} contains invalid policy class " <>
                "#{inspect(class)}; expected one of #{inspect(valid)}"
      end
    end)
  end

  defp apply_allowlist(_capabilities, []), do: []
  defp apply_allowlist(capabilities, nil), do: capabilities

  defp apply_allowlist(capabilities, names) when is_list(names) do
    name_set = MapSet.new(names)
    Enum.filter(capabilities, &MapSet.member?(name_set, &1.name))
  end

  defp apply_name_exclusion(capabilities, nil), do: capabilities
  defp apply_name_exclusion(capabilities, []), do: capabilities

  defp apply_name_exclusion(capabilities, names) when is_list(names) do
    name_set = MapSet.new(names)
    Enum.reject(capabilities, &MapSet.member?(name_set, &1.name))
  end

  defp apply_category_exclusion(capabilities, nil), do: capabilities
  defp apply_category_exclusion(capabilities, []), do: capabilities

  defp apply_category_exclusion(capabilities, categories) when is_list(categories) do
    category_set = MapSet.new(categories)

    Enum.reject(capabilities, fn %Capability{metadata: metadata} ->
      Map.get(metadata, :category) in category_set
    end)
  end

  defp apply_hidden_filter(capabilities, true), do: capabilities

  defp apply_hidden_filter(capabilities, false) do
    Enum.reject(capabilities, & &1.hidden_from_agent?)
  end
end
