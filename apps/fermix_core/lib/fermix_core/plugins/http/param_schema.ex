defmodule FermixCore.Plugins.Http.ParamSchema do
  @moduledoc """
  Validates a declarative plugin tool's arguments against the manifest
  `parameters` block and materializes defaults — the in-house bounded subset of
  JSON Schema the `http` rail uses (§5.3). Deliberately NOT a JSON-Schema
  dependency: a single-level `object` with `properties` (`type`, `enum`,
  `default`, `description`) + `required`. Nested validation below the top level
  is not performed — `object`/`array` params (e.g. Notion block payloads) pass
  through opaquely.

  `validate/2` returns the normalized args (declared keys only, defaults
  materialized) or a `{:error, _}` the runtime turns into a tool error before
  any request is sent.
  """

  @types ~w(string integer number boolean array object)

  @doc """
  Validate `args` against `schema` and materialize defaults. Returns
  `{:ok, normalized}` (only declared keys; absent optionals with a `default`
  filled in; absent optionals without a default omitted) or
  `{:error, {:missing_param, key} | {:invalid_param, key, detail}}`.
  """
  @spec validate(map(), map()) :: {:ok, map()} | {:error, term()}
  def validate(schema, args) when is_map(schema) and is_map(args) do
    properties = Map.get(schema, "properties", %{})
    required = Map.get(schema, "required", [])

    with {:ok, normalized} <- normalize(properties, args),
         :ok <- check_required(required, normalized) do
      {:ok, normalized}
    end
  end

  defp normalize(properties, args) do
    Enum.reduce_while(properties, {:ok, %{}}, fn {key, spec}, {:ok, acc} ->
      case normalize_one(key, spec, args) do
        :omit -> {:cont, {:ok, acc}}
        {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp normalize_one(key, spec, args) do
    case Map.fetch(args, key) do
      {:ok, value} -> validate_value(key, spec, value)
      :error -> default_or_omit(key, spec)
    end
  end

  defp default_or_omit(key, spec) do
    case Map.fetch(spec, "default") do
      {:ok, default} -> validate_value(key, spec, default)
      :error -> :omit
    end
  end

  defp validate_value(key, spec, value) do
    with :ok <- check_type(key, spec, value),
         :ok <- check_enum(key, spec, value) do
      {:ok, value}
    end
  end

  defp check_type(key, spec, value) do
    case Map.get(spec, "type") do
      type when type in @types ->
        if matches?(type, value), do: :ok, else: type_error(key, type, value)

      nil ->
        :ok

      other ->
        {:error, {:invalid_param, key, {:unknown_type, other}}}
    end
  end

  defp matches?("string", v), do: is_binary(v)
  defp matches?("integer", v), do: is_integer(v)
  defp matches?("number", v), do: is_number(v)
  defp matches?("boolean", v), do: is_boolean(v)
  defp matches?("array", v), do: is_list(v)
  defp matches?("object", v), do: is_map(v)

  defp type_error(key, type, value),
    do: {:error, {:invalid_param, key, {:expected_type, type, value}}}

  defp check_enum(key, spec, value) do
    case Map.get(spec, "enum") do
      nil ->
        :ok

      choices when is_list(choices) ->
        if value in choices,
          do: :ok,
          else: {:error, {:invalid_param, key, {:not_in_enum, choices}}}

      _ ->
        :ok
    end
  end

  defp check_required(required, normalized) do
    case Enum.find(required, &(not Map.has_key?(normalized, &1))) do
      nil -> :ok
      missing -> {:error, {:missing_param, missing}}
    end
  end
end
