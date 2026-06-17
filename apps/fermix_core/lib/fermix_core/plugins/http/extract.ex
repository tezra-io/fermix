defmodule FermixCore.Plugins.Http.Extract do
  @moduledoc """
  Response shaping for the `http` rail (§5.3): a dot-path + field selection,
  deliberately **not** JSONPath. `path` is dot-separated keys with `[*]` list
  traversal (`a.b[*].c`); `fields` picks keys from each result object. No
  filters, no expressions — this is the firewall against the extractor becoming
  a query language.

  Absent `extract` (nil) returns the whole body unchanged.
  """

  @doc """
  Apply an `extract` spec (`%{"path" => "a.b[*].c", "fields" => [...]}`, both
  optional) to a decoded JSON `body`. Nil spec returns `body` verbatim.
  """
  @spec apply(map() | nil, term()) :: term()
  def apply(nil, body), do: body

  def apply(spec, body) when is_map(spec) do
    body
    |> navigate(Map.get(spec, "path"))
    |> pick(Map.get(spec, "fields"))
  end

  defp navigate(body, nil), do: body
  defp navigate(body, ""), do: body

  defp navigate(body, path) when is_binary(path) do
    path
    |> split_segments()
    |> Enum.reduce(body, &step/2)
  end

  # Split "a.b[*].c" into ["a", "b", :each, "c"].
  defp split_segments(path) do
    path
    |> String.split(".")
    |> Enum.flat_map(&expand_segment/1)
  end

  defp expand_segment(segment) do
    case String.split(segment, "[*]") do
      ["", ""] -> [:each]
      [key, ""] -> [key, :each]
      [key] -> [key]
      parts -> Enum.intersperse(Enum.reject(parts, &(&1 == "")), :each) ++ [:each]
    end
  end

  defp step(:each, value) when is_list(value), do: Enum.flat_map(value, &List.wrap/1)
  defp step(:each, _value), do: []
  defp step(key, value) when is_map(value), do: Map.get(value, key)
  defp step(key, values) when is_list(values), do: Enum.map(values, &map_get(&1, key))
  defp step(_key, _value), do: nil

  defp map_get(v, key) when is_map(v), do: Map.get(v, key)
  defp map_get(_v, _key), do: nil

  defp pick(value, nil), do: value
  defp pick(value, []), do: value

  defp pick(value, fields) when is_list(value), do: Enum.map(value, &pick(&1, fields))

  defp pick(value, fields) when is_map(value) and is_list(fields),
    do: Map.take(value, fields)

  defp pick(value, _fields), do: value
end
