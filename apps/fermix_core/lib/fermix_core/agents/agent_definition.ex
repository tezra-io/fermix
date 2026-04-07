defmodule FermixCore.Agents.AgentDefinition do
  @moduledoc """
  Immutable description of a main or skill agent.

  M2 uses this struct as the filesystem-backed contract for skill discovery.
  """

  @type role :: :main | :sub

  @type t :: %__MODULE__{
          name: String.t(),
          role: role(),
          persistent: boolean(),
          system_prompt: String.t(),
          model: String.t() | nil,
          temperature: float() | nil,
          capabilities: [String.t()],
          allowed_tools: [String.t()],
          max_iterations: pos_integer(),
          timeout_seconds: pos_integer(),
          parent: String.t() | nil,
          delegates_to: [String.t()],
          source_path: String.t() | nil
        }

  @enforce_keys [
    :name,
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
    :role,
    :persistent,
    :system_prompt,
    :model,
    :temperature,
    :capabilities,
    :allowed_tools,
    :max_iterations,
    :timeout_seconds,
    :parent,
    :delegates_to,
    :source_path
  ]

  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, name} <- fetch_required_string(attrs, "name"),
         :ok <- validate_name(name),
         {:ok, system_prompt} <- fetch_required_string(attrs, "system_prompt"),
         {:ok, role} <- parse_role(get(attrs, "role", :sub)),
         {:ok, persistent} <- parse_persistent(get(attrs, "persistent", role == :main), role),
         {:ok, max_iterations} <- parse_positive_integer(get(attrs, "max_iterations", 25)),
         {:ok, timeout_seconds} <- parse_positive_integer(get(attrs, "timeout_seconds", 300)),
         {:ok, temperature} <- parse_optional_float(get(attrs, "temperature")) do
      {:ok,
       %__MODULE__{
         name: name,
         role: role,
         persistent: persistent,
         system_prompt: system_prompt,
         model: optional_string(get(attrs, "model")),
         temperature: temperature,
         capabilities: normalize_string_list(get(attrs, "capabilities", [])),
         allowed_tools: normalize_string_list(get(attrs, "allowed_tools", [])),
         max_iterations: max_iterations,
         timeout_seconds: timeout_seconds,
         parent: optional_string(get(attrs, "parent")),
         delegates_to: normalize_string_list(get(attrs, "delegates_to", [])),
         source_path: optional_string(get(attrs, "source_path"))
       }}
    end
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

      if is_atom(atom_key) and Map.has_key?(attrs, atom_key) do
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
    if String.match?(name, ~r/^[a-zA-Z0-9_-]+$/) do
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

  defp parse_persistent(value, :main) when value in [true, "true"], do: {:ok, true}
  defp parse_persistent(value, :sub) when value in [false, "false"], do: {:ok, false}
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

  defp normalize_string_list(values) when is_list(values) do
    Enum.map(values, &to_string/1)
  end

  defp normalize_string_list(nil), do: []
  defp normalize_string_list(value), do: [to_string(value)]
end
