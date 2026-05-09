defmodule FermixCore.Introspection.Wire do
  @moduledoc """
  Converts introspection snapshots into JSON-safe values for the daemon socket.
  """

  @spec json_safe(term()) :: term()
  def json_safe(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def json_safe(%Date{} = value), do: Date.to_iso8601(value)
  def json_safe(%Time{} = value), do: Time.to_iso8601(value)
  def json_safe(pid) when is_pid(pid), do: inspect(pid)
  def json_safe(atom) when is_atom(atom), do: Atom.to_string(atom)
  def json_safe(value) when is_binary(value) or is_number(value) or is_boolean(value), do: value
  def json_safe(nil), do: nil

  def json_safe(list) when is_list(list) do
    Enum.map(list, &json_safe/1)
  end

  def json_safe(map) when is_map(map) do
    map
    |> plain_map()
    |> Map.new(fn {key, value} -> {json_key(key), json_safe(value)} end)
  end

  def json_safe(value), do: raise(ArgumentError, "non-JSON term: #{inspect(value)}")

  defp plain_map(%{__struct__: _struct} = map), do: Map.from_struct(map)
  defp plain_map(map), do: map

  defp json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_key(key) when is_binary(key), do: key
  defp json_key(key), do: inspect(key)
end
