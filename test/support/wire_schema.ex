defmodule FermixTestSupport.WireSchema do
  @moduledoc """
  A bounded JSON Schema validator for exactly the vocabulary the wire exports
  under `fermix_core/priv/` use, so a contract test checks a frame against the
  schema a phone or a companion vendors, not against a copy of the codec.

  Anything outside the vocabulary fails loudly rather than passing unchecked:
  extending a schema with an unsupported keyword breaks the test that reads it
  instead of quietly weakening the gate. `x-max-bytes` is enforced (a bound in
  bytes of UTF-8, which `maxLength` cannot say); every other `x-` keyword is
  an annotation.
  """

  @inert_keywords ~w($schema $id $defs title description contentMediaType)
  @checked_elsewhere ~w(if then contentSchema)

  @doc """
  The problems `value` has against `schema`, resolving `$ref`s in `root`.
  An empty list means valid.
  """
  @spec errors(term(), map(), map()) :: [String.t()]
  def errors(value, schema, root) when is_map(schema) and is_map(root) do
    conditional_errors(schema, value, root) ++
      content_errors(schema, value, root) ++
      Enum.flat_map(Map.drop(schema, @checked_elsewhere), &keyword_errors(&1, value, root))
  end

  @doc "A `$ref` to one of the root's `$defs`."
  @spec ref(String.t()) :: map()
  def ref(name) when is_binary(name), do: %{"$ref" => "#/$defs/#{name}"}

  @doc """
  Every path in `schema` whose `type` admits `null`: an export whose optional
  fields are absent, never null, has none.
  """
  @spec null_typed_paths(term(), String.t()) :: [String.t()]
  def null_typed_paths(schema, path) when is_map(schema) and is_binary(path) do
    Enum.flat_map(schema, fn {key, value} -> null_typed_paths(key, value, path) end)
  end

  def null_typed_paths(schema, path) when is_list(schema) and is_binary(path) do
    schema
    |> Enum.with_index()
    |> Enum.flat_map(fn {value, index} -> null_typed_paths(value, "#{path}/#{index}") end)
  end

  def null_typed_paths(_scalar, path) when is_binary(path), do: []

  @doc "Every path in a decoded JSON value that holds an explicit `null`."
  @spec null_values(term(), String.t()) :: [String.t()]
  def null_values(nil, path) when is_binary(path), do: [path]

  def null_values(value, path) when is_map(value) and is_binary(path) do
    Enum.flat_map(value, fn {key, item} -> null_values(item, "#{path}/#{key}") end)
  end

  def null_values(value, path) when is_list(value) and is_binary(path) do
    value
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, index} -> null_values(item, "#{path}/#{index}") end)
  end

  def null_values(_value, path) when is_binary(path), do: []

  defp null_typed_paths("type", "null", path), do: ["#{path}/type"]

  defp null_typed_paths("type", types, path) when is_list(types) do
    if "null" in types, do: ["#{path}/type"], else: []
  end

  defp null_typed_paths(key, value, path), do: null_typed_paths(value, "#{path}/#{key}")

  defp conditional_errors(%{"if" => condition, "then" => branch}, value, root) do
    if errors(value, condition, root) == [], do: errors(value, branch, root), else: []
  end

  defp conditional_errors(_schema, _value, _root), do: []

  # A string that carries JSON (`contentMediaType`) is checked as the value it
  # decodes to.
  defp content_errors(
         %{"contentMediaType" => "application/json", "contentSchema" => content},
         value,
         root
       )
       when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> Enum.map(errors(decoded, content, root), &"content: #{&1}")
      {:error, _reason} -> ["content is not JSON"]
    end
  end

  defp content_errors(_schema, _value, _root), do: []

  defp keyword_errors({"$ref", "#/$defs/" <> name}, value, root),
    do: errors(value, Map.fetch!(root["$defs"], name), root)

  defp keyword_errors({"allOf", schemas}, value, root),
    do: Enum.flat_map(schemas, &errors(value, &1, root))

  defp keyword_errors({"anyOf", schemas}, value, root) do
    if Enum.any?(schemas, &(errors(value, &1, root) == [])),
      do: [],
      else: ["matched no anyOf branch"]
  end

  defp keyword_errors({"oneOf", schemas}, value, root) do
    case Enum.count(schemas, &(errors(value, &1, root) == [])) do
      1 -> []
      matched -> ["matched #{matched} oneOf branches"]
    end
  end

  defp keyword_errors({"properties", properties}, value, root) when is_map(value) do
    Enum.flat_map(properties, fn {key, subschema} ->
      case Map.fetch(value, key) do
        {:ok, sub} -> Enum.map(errors(sub, subschema, root), &"#{key}: #{&1}")
        :error -> []
      end
    end)
  end

  defp keyword_errors({"items", subschema}, value, root) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, index} ->
      Enum.map(errors(item, subschema, root), &"[#{index}] #{&1}")
    end)
  end

  defp keyword_errors(keyword, value, _root), do: value_errors(keyword, value)

  defp value_errors({"type", types}, value) when is_list(types) do
    if Enum.any?(types, &type?(value, &1)), do: [], else: ["expected #{Enum.join(types, "|")}"]
  end

  defp value_errors({"type", type}, value) do
    if type?(value, type), do: [], else: ["expected #{type}, got #{inspect(value)}"]
  end

  defp value_errors({"required", keys}, value) when is_map(value) do
    keys |> Enum.reject(&Map.has_key?(value, &1)) |> Enum.map(&"missing #{&1}")
  end

  defp value_errors({"enum", allowed}, value) do
    if value in allowed, do: [], else: ["#{inspect(value)} outside enum"]
  end

  defp value_errors({"const", expected}, value) do
    if value === expected, do: [], else: ["#{inspect(value)} is not #{inspect(expected)}"]
  end

  defp value_errors(keyword, value), do: bound_errors(keyword, value)

  # A string's length is counted in code points, as JSON Schema counts it.
  defp bound_errors({"minLength", min}, value) when is_binary(value) do
    if code_points(value) >= min, do: [], else: ["shorter than #{min}"]
  end

  defp bound_errors({"maxLength", max}, value) when is_binary(value) do
    if code_points(value) <= max, do: [], else: ["longer than #{max}"]
  end

  defp bound_errors({"x-max-bytes", max}, value) when is_binary(value) do
    if byte_size(value) <= max, do: [], else: ["more than #{max} bytes"]
  end

  defp bound_errors({"pattern", pattern}, value) when is_binary(value) do
    if Regex.match?(Regex.compile!(pattern), value), do: [], else: ["does not match #{pattern}"]
  end

  defp bound_errors({"minimum", min}, value) when is_number(value) do
    if value >= min, do: [], else: ["below #{min}"]
  end

  defp bound_errors({"maximum", max}, value) when is_number(value) do
    if value <= max, do: [], else: ["above #{max}"]
  end

  defp bound_errors({"minItems", min}, value) when is_list(value) do
    if length(value) >= min, do: [], else: ["fewer than #{min} items"]
  end

  defp bound_errors({"maxItems", max}, value) when is_list(value) do
    if length(value) <= max, do: [], else: ["more than #{max} items"]
  end

  defp bound_errors(keyword, _value), do: inapplicable(keyword)

  # A keyword that does not apply to this value's type passes it; one outside
  # the vocabulary is refused.
  defp inapplicable({keyword, _constraint})
       when keyword in ~w(required properties items minItems maxItems minLength maxLength
                          pattern minimum maximum x-max-bytes),
       do: []

  defp inapplicable({keyword, _constraint}) do
    if keyword in @inert_keywords or String.starts_with?(keyword, "x-"),
      do: [],
      else: ["unsupported schema keyword #{keyword}"]
  end

  defp code_points(value), do: value |> String.codepoints() |> length()

  defp type?(value, "object"), do: is_map(value)
  defp type?(value, "array"), do: is_list(value)
  defp type?(value, "string"), do: is_binary(value)
  defp type?(value, "integer"), do: is_integer(value)
  defp type?(value, "number"), do: is_number(value)
  defp type?(value, "boolean"), do: is_boolean(value)
end
