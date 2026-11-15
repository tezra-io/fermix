defmodule FermixCore.Agents.AgentDefinition do
  @moduledoc """
  Immutable description of a main or skill agent.

  Loaded from a SKILL.md frontmatter map. `trust` is set by `SkillRegistry`
  from the on-disk path (operators can't self-declare `:core`); `policy`
  comes from frontmatter and is parsed strictly — unknown classes raise.

  `allowed_tools` is 3-state by design:

    * `nil`   — field absent. Sub-agent gets the tools of the run that calls it.
    * `[]`    — explicit empty. Sub-agent gets no capabilities.
    * `[..]`  — exact name allowlist (still subject to `policy`/trust).

  A tool list under a key Fermix does not read (`allowed-tools`, the Agent
  Skills pre-approval field; `tools` or `allowedTools`, Claude Code's) is never
  taken as "absent": its author meant a limit, so with no `allowed_tools` the
  skill gets no capabilities. The key is kept in `misspelled_tool_keys` so the
  skill's run can say why (`Capabilities.Skill.tool_warning/2`).
  """

  alias FermixCore.Capabilities.Capability

  @type role :: :main | :sub
  @type source :: :operator | :guest

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          role: role(),
          persistent: boolean(),
          system_prompt: String.t(),
          model: String.t() | nil,
          provider: atom() | nil,
          reasoning_effort: atom() | nil,
          temperature: float() | nil,
          capabilities: [String.t()],
          allowed_tools: [String.t()] | nil,
          misspelled_tool_keys: [String.t()],
          policy: [Capability.policy_class()] | nil,
          trust: source() | nil,
          plugin: String.t() | nil,
          own_plugin: FermixCore.Capabilities.Registry.own_plugin() | nil,
          max_iterations: pos_integer(),
          timeout_seconds: pos_integer(),
          parent: String.t() | nil,
          delegates_to: [String.t()],
          source_path: String.t() | nil
        }

  @enforce_keys [
    :name,
    :description,
    :role,
    :persistent,
    :system_prompt,
    :capabilities,
    :allowed_tools,
    :max_iterations,
    :timeout_seconds,
    :parent,
    :delegates_to
  ]
  defstruct [
    :name,
    :description,
    :role,
    :persistent,
    :system_prompt,
    :model,
    :provider,
    # Set only by Tools.Subagents from [fermix_core.routing]/per-call args; NOT
    # parsed from SKILL.md frontmatter (docs/design/SUBAGENT_MODEL_SELECTION.md §5a).
    :reasoning_effort,
    :temperature,
    :capabilities,
    :allowed_tools,
    :policy,
    :trust,
    # Set only by SkillRegistry (`with_plugin/2`) for a skill an enabled
    # plugin ships; NOT parsed from SKILL.md frontmatter.
    :plugin,
    # Set only by Capabilities.Skill for a plugin skill's worker: its own
    # plugin's tools within its parent's grant (`Skill.own_plugin/2`).
    :own_plugin,
    :max_iterations,
    :timeout_seconds,
    :parent,
    :delegates_to,
    :source_path,
    misspelled_tool_keys: []
  ]

  @absent_sentinel :__absent__
  # Tool-list keys Fermix does not read: the Agent Skills `allowed-tools` and
  # Claude Code's `tools`/`allowedTools`.
  @misspelled_tool_keys ~w(allowed-tools tools allowedTools)
  # Deliberately excludes `gui_control` (a valid Capability policy class): computer
  # use is operator-only and never delegatable, so an agent/subagent definition may
  # not request it as a policy. Do not add it here to "match" Capability —
  # the omission is the guard.
  @valid_policy_strings ~w(read_only read_write exec network external_api)
  # Derived from the Descriptor registry — accepted strings and routable
  # providers can no longer diverge. `together`/`groq` were removed: they
  # were accepted-but-unroutable (no resolver ever existed; M12 §2.3-8).
  @valid_provider_strings Enum.map(
                            FermixCore.Providers.Descriptor.ids(),
                            &Atom.to_string/1
                          )

  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, name} <- fetch_required_string(attrs, "name"),
         :ok <- validate_name(name),
         {:ok, description} <- fetch_required_string(attrs, "description"),
         {:ok, system_prompt} <- fetch_required_string(attrs, "system_prompt"),
         {:ok, role} <- parse_role(get(attrs, "role", :sub)),
         {:ok, persistent} <-
           parse_persistent(get(attrs, "persistent", default_persistent(role)), role),
         {:ok, max_iterations} <- parse_positive_integer(get(attrs, "max_iterations", 25)),
         {:ok, timeout_seconds} <- parse_positive_integer(get(attrs, "timeout_seconds", 300)),
         {:ok, temperature} <- parse_optional_float(get(attrs, "temperature")),
         {:ok, allowed_tools} <-
           parse_allowed_tools(get(attrs, "allowed_tools", @absent_sentinel)),
         misspelled_tool_keys = Enum.filter(@misspelled_tool_keys, &Map.has_key?(attrs, &1)),
         {:ok, policy} <- parse_policy(get(attrs, "policy")),
         {:ok, trust} <- parse_trust(get(attrs, "trust")),
         {:ok, provider} <- parse_provider(get(attrs, "provider")) do
      {:ok,
       %__MODULE__{
         name: name,
         description: description,
         role: role,
         persistent: persistent,
         system_prompt: system_prompt,
         model: optional_string(get(attrs, "model")),
         provider: provider,
         temperature: temperature,
         capabilities: normalize_string_list(get(attrs, "capabilities", [])),
         allowed_tools: confine_misspelled(allowed_tools, misspelled_tool_keys),
         misspelled_tool_keys: misspelled_tool_keys,
         policy: policy,
         trust: trust,
         max_iterations: max_iterations,
         timeout_seconds: timeout_seconds,
         parent: optional_string(get(attrs, "parent")),
         delegates_to: normalize_string_list(get(attrs, "delegates_to", [])),
         source_path: optional_string(get(attrs, "source_path"))
       }}
    end
  end

  @doc """
  Tag an existing definition with its trust source. Used by `SkillRegistry`
  after path-based classification.
  """
  @spec with_trust(t(), source()) :: t()
  def with_trust(%__MODULE__{} = definition, trust)
      when trust in [:operator, :guest] do
    %{definition | trust: trust}
  end

  @doc """
  Tag a guest definition with the plugin it ships with. Used by `SkillRegistry`
  for a skill under an enabled plugin's skill directory: that plugin's tools are
  the one thing beyond guest its runs reach (`Capabilities.Skill.own_plugin/2`).
  """
  @spec with_plugin(t(), String.t()) :: t()
  def with_plugin(%__MODULE__{trust: :guest} = definition, plugin)
      when is_binary(plugin) and plugin != "" do
    %{definition | plugin: plugin}
  end

  defp get(attrs, key, default \\ nil) do
    if Map.has_key?(attrs, key) do
      Map.get(attrs, key)
    else
      atom_key =
        try do
          String.to_existing_atom(key)
        rescue
          ArgumentError -> nil
        end

      if Map.has_key?(attrs, atom_key) do
        Map.get(attrs, atom_key)
      else
        default
      end
    end
  end

  defp fetch_required_string(attrs, key) do
    case optional_string(get(attrs, key)) do
      nil -> {:error, {:missing_field, key}}
      value -> {:ok, value}
    end
  end

  defp optional_string(nil), do: nil

  defp optional_string(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp optional_string(value), do: to_string(value)

  defp validate_name(name) do
    if String.match?(name, ~r/^[a-zA-Z0-9_-]{1,64}$/) do
      :ok
    else
      {:error, {:invalid_name, name}}
    end
  end

  defp parse_role(:main), do: {:ok, :main}
  defp parse_role(:sub), do: {:ok, :sub}
  defp parse_role("main"), do: {:ok, :main}
  defp parse_role("sub"), do: {:ok, :sub}
  defp parse_role(role), do: {:error, {:invalid_role, role}}

  defp default_persistent(:main), do: true
  defp default_persistent(:sub), do: false

  defp parse_persistent(true, :main), do: {:ok, true}
  defp parse_persistent("true", :main), do: {:ok, true}
  defp parse_persistent(false, :sub), do: {:ok, false}
  defp parse_persistent("false", :sub), do: {:ok, false}
  defp parse_persistent(value, role), do: {:error, {:invalid_persistent, role, value}}

  defp parse_positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _ -> {:error, {:invalid_positive_integer, value}}
    end
  end

  defp parse_positive_integer(value), do: {:error, {:invalid_positive_integer, value}}

  defp parse_optional_float(nil), do: {:ok, nil}
  defp parse_optional_float(value) when is_float(value), do: {:ok, value}
  defp parse_optional_float(value) when is_integer(value), do: {:ok, value / 1}

  defp parse_optional_float(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, ""} -> {:ok, parsed}
      _ -> {:error, {:invalid_float, value}}
    end
  end

  defp parse_optional_float(value), do: {:error, {:invalid_float, value}}

  defp parse_allowed_tools(@absent_sentinel), do: {:ok, nil}
  defp parse_allowed_tools(nil), do: {:ok, nil}
  defp parse_allowed_tools(list) when is_list(list), do: {:ok, normalize_string_list(list)}
  defp parse_allowed_tools(other), do: {:error, {:invalid_allowed_tools, other}}

  # Named tools under a key Fermix does not read never widen to "absent".
  defp confine_misspelled(nil, [_ | _]), do: []
  defp confine_misspelled(allowed_tools, _misspelled_tool_keys), do: allowed_tools

  defp parse_policy(nil), do: {:ok, nil}

  defp parse_policy(value) when is_binary(value), do: parse_policy([value])

  defp parse_policy(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case parse_policy_class(value) do
        {:ok, class} -> {:cont, {:ok, [class | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, classes} -> {:ok, Enum.reverse(classes)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_policy(other), do: {:error, {:invalid_policy, other}}

  defp parse_policy_class(value) when is_binary(value) and value in @valid_policy_strings do
    {:ok, String.to_existing_atom(value)}
  end

  defp parse_policy_class(value), do: {:error, {:invalid_policy_class, value}}

  defp parse_trust(nil), do: {:ok, nil}
  defp parse_trust(value) when value in [:operator, :guest], do: {:ok, value}
  defp parse_trust(other), do: {:error, {:invalid_trust, other}}

  defp parse_provider(nil), do: {:ok, nil}

  defp parse_provider(value) when is_atom(value) do
    parse_provider(Atom.to_string(value))
  end

  defp parse_provider(value) when is_binary(value) do
    if value in @valid_provider_strings do
      {:ok, String.to_existing_atom(value)}
    else
      {:error, {:invalid_provider, value}}
    end
  end

  defp parse_provider(other), do: {:error, {:invalid_provider, other}}

  defp normalize_string_list(values) when is_list(values) do
    Enum.map(values, &to_string/1)
  end

  defp normalize_string_list(nil), do: []
  defp normalize_string_list(value), do: [to_string(value)]
end
