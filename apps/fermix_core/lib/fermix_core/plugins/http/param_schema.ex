defmodule FermixCore.Plugins.Http.ParamSchema do
  @moduledoc """
  Validates a declarative plugin tool's arguments against the manifest
  `parameters` block and materializes defaults — the in-house bounded subset of
  JSON Schema the `http` rail uses (§5.3). Deliberately NOT a JSON-Schema
  dependency: a single-level `object` with `properties` (`type`, `enum`,
  `default`, `description`, and the scalar bounds below) + `required`. Nested
  validation below the top level is not performed — `object`/`array` params
  (e.g. Notion block payloads) pass through opaquely. A JSON-string value for a
  declared `object`/`array` param is decoded to its native shape first (models
  stringify freeform structured params); only the top-level type is then checked.

  `validate/2` returns the normalized args (declared keys only, defaults
  materialized) or a `{:error, _}` the runtime turns into a tool error before
  any request is sent.

  ## Scalar bounds (top level only)

  A property may bound its value, and the bound is *enforced* here rather than
  merely described: `minimum`/`maximum` on an `integer` or `number` (inclusive),
  `minLength`/`maxLength` on a `string` (inclusive). String lengths are counted
  in **codepoints**, not graphemes — a combining sequence is two codepoints and
  one grapheme, and a fixed-width identifier (a 17-character VIN) means
  codepoints. Bounds are checked after `type` and `enum`, so a wrong-typed value
  reports its type error rather than a bound error, and each bound has its own
  reason (`:below_minimum`, `:above_maximum`, `:below_min_length`,
  `:above_max_length`).

  A bound is consulted only for the kind of value it can describe: a `minimum`
  declared on a string, or a `minLength` declared on an integer, says nothing
  and is never applied. A bound that is present but not a number is a broken
  manifest and is refused (`:invalid_bound`) rather than skipped. Unknown
  arguments are still dropped silently, bounds or not.
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
    value = coerce_structured(Map.get(spec, "type"), value)

    with :ok <- check_type(key, spec, value),
         :ok <- check_enum(key, spec, value),
         :ok <- check_bounds(key, spec, value) do
      {:ok, value}
    end
  end

  # A declared `object`/`array` param whose value arrives as a JSON-encoded
  # string is normalized to its decoded map/list. Models routinely stringify a
  # freeform `{"type":"object"}` param that ships no inner schema to guide them,
  # and this is provider-wide (OpenAI's stringified `arguments`, Anthropic's
  # native `input`, xAI). Coercion is the one deterministic encoding the
  # validator accepts for a structured type — a string that does NOT decode to
  # the declared type is left as-is so `check_type` still fails loud with
  # `invalid_param`. Scalars are out of scope: their types are unambiguous and
  # models supply them natively, so a stringified scalar stays a type error.
  defp coerce_structured(type, value) when type in ["object", "array"] and is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> if matches?(type, decoded), do: decoded, else: value
      {:error, _} -> value
    end
  end

  defp coerce_structured(_type, value), do: value

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

  # Bounds run last and only for the value kind they describe: `minimum`/
  # `maximum` bound a number, `minLength`/`maxLength` bound a string's codepoint
  # count. Anything else (boolean, array, object) has no bound grammar.
  defp check_bounds(key, spec, value) when is_number(value) do
    with {:ok, min} <- bound(key, spec, "minimum"),
         {:ok, max} <- bound(key, spec, "maximum"),
         :ok <- at_least(key, min, value, :below_minimum) do
      at_most(key, max, value, :above_maximum)
    end
  end

  defp check_bounds(key, spec, value) when is_binary(value) do
    codepoints = value |> String.codepoints() |> length()

    with {:ok, min} <- bound(key, spec, "minLength"),
         {:ok, max} <- bound(key, spec, "maxLength"),
         :ok <- at_least(key, min, codepoints, :below_min_length) do
      at_most(key, max, codepoints, :above_max_length)
    end
  end

  defp check_bounds(_key, _spec, _value), do: :ok

  # An absent bound is `nil`; a present one must be a number, or the manifest is
  # broken and says so at the first call instead of being quietly ignored.
  defp bound(key, spec, field) do
    case Map.fetch(spec, field) do
      :error -> {:ok, nil}
      {:ok, value} when is_number(value) -> {:ok, value}
      {:ok, value} -> {:error, {:invalid_param, key, {:invalid_bound, field, value}}}
    end
  end

  defp at_least(_key, nil, _actual, _reason), do: :ok

  defp at_least(key, min, actual, reason) when actual < min,
    do: {:error, {:invalid_param, key, {reason, min}}}

  defp at_least(_key, _min, _actual, _reason), do: :ok

  defp at_most(_key, nil, _actual, _reason), do: :ok

  defp at_most(key, max, actual, reason) when actual > max,
    do: {:error, {:invalid_param, key, {reason, max}}}

  defp at_most(_key, _max, _actual, _reason), do: :ok

  defp check_required(required, normalized) do
    case Enum.find(required, &(not Map.has_key?(normalized, &1))) do
      nil -> :ok
      missing -> {:error, {:missing_param, missing}}
    end
  end
end
