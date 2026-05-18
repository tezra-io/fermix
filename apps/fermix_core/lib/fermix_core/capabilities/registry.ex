defmodule FermixCore.Capabilities.Registry do
  @moduledoc """
  Single source of truth for everything the LLM can call.

  Holds `%FermixCore.Capabilities.Capability{}` structs in a protected ETS
  table keyed by `name`. Reads (`list/1,2`, `find/2`) hit ETS directly so
  the agent loop's hot path doesn't go through a GenServer. Writes
  (`register/2`, `unregister_kind/2,3`, `refresh/2`) serialize through the
  GenServer.

  Built-ins are mirrored at boot through `FermixCore.Capabilities.Builtin.from_tool_module/1`.
  Skills and MCP server tools register themselves through their own
  supervisors as they come up.
  """

  use GenServer

  alias FermixCore.Capabilities.Capability

  @type policy_spec ::
          nil
          | [Capability.policy_class()]
          | [allow: [Capability.policy_class()], deny: [Capability.policy_class()]]

  @type trust :: nil | :core | :local | :third_party

  @type filter ::
          [
            allowed_tools: [String.t()] | nil,
            policy: policy_spec(),
            trust: trust(),
            kind: Capability.kind() | :all,
            include_hidden?: boolean()
          ]

  # Default policies per trust source. See design §4.6.3.
  # `:core` and `nil` (unscoped, e.g. main agent) are unfiltered.
  @third_party_default_policy [
    allow: [:read_only],
    deny: [:read_write, :exec, :network, :external_api]
  ]
  @local_default_policy [
    allow: [:read_only, :read_write, :exec, :network],
    deny: [:external_api]
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
    :ets.delete(state.table, name)
    {:reply, :ok, state}
  end

  def handle_call({:unregister_kind, kind, opts}, _from, state) do
    metadata_match = Keyword.get(opts, :metadata, %{})

    state.table
    |> :ets.tab2list()
    |> Enum.each(fn {name, %Capability{} = cap} ->
      if cap.kind == kind and metadata_matches?(cap.metadata, metadata_match) do
        :ets.delete(state.table, name)
      end
    end)

    {:reply, :ok, state}
  end

  def handle_call({:refresh, _kind}, _from, state) do
    # Stage 1 placeholder. Stage 3 wires SkillRegistry → CapabilityRegistry
    # for :skill; Stage 5 wires MCP.Supervisor for :mcp.
    {:reply, :ok, state}
  end

  def handle_call(:table_name, _from, state), do: {:reply, state.table, state}

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
    policy = resolve_policy(Keyword.get(opts, :trust), Keyword.get(opts, :policy))

    capabilities
    |> apply_kind(Keyword.get(opts, :kind, :all))
    |> apply_policy(policy)
    |> apply_allowlist(Keyword.get(opts, :allowed_tools))
    |> apply_hidden_filter(Keyword.get(opts, :include_hidden?, false))
  end

  @doc """
  Resolve the effective policy filter from `(trust, policy)`.

  An explicit `policy` always wins. When the skill leaves `policy` unset,
  fall back to the default for the trust level: `:third_party` is read-only,
  `:local` is broad-but-not-external. `:core` and `nil` (main agent) are
  unfiltered.
  """
  @spec resolve_policy(trust(), policy_spec()) :: policy_spec()
  def resolve_policy(_trust, policy) when is_list(policy) and policy != [], do: policy
  def resolve_policy(:third_party, _policy), do: @third_party_default_policy
  def resolve_policy(:local, _policy), do: @local_default_policy
  def resolve_policy(:core, _policy), do: nil
  def resolve_policy(nil, _policy), do: nil

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

  defp apply_hidden_filter(capabilities, true), do: capabilities

  defp apply_hidden_filter(capabilities, false) do
    Enum.reject(capabilities, & &1.hidden_from_agent?)
  end
end
