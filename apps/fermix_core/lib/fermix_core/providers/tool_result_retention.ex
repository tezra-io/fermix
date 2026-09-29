defmodule FermixCore.Providers.ToolResultRetention do
  @moduledoc """
  Replaces the text of tool results already in a provider's replayed history.

  Every provider surface re-sends the whole transcript on every continuation,
  so a tool result that the agent loop has compressed into a digest
  (docs/design/IN_LOOP_CONTEXT_OVERFLOW.md §3.3) has to be swapped in the
  adapter's own history shape: a `tool_result` block on Anthropic, a
  `function_call_output` item on the Responses surfaces, a `role: "tool"`
  message on Chat Completions. Each adapter contributes only its carrier
  shape through the two injected functions; the rule is shared here.

  Substitution only: no unit is added or removed, so tool-call / tool-result
  pairing cannot break, and a unit whose id has no entry is untouched. An
  empty substitution map returns `units` unchanged, byte for byte.
  """

  @type substitutions :: %{optional(String.t()) => String.t()}

  @doc """
  Replace the text of every unit whose `id_of` value has an entry in
  `substitutions`.

  `id_of` returns the tool-result id a unit carries, or `nil` for a unit that
  is not a tool-result carrier. `replace` returns the same unit with its text
  swapped for the substitution. Units are never reordered or dropped.
  """
  @spec substitute([unit], substitutions(), (unit -> String.t() | nil), (unit, String.t() -> unit)) ::
          [unit]
        when unit: term()
  def substitute(units, substitutions, _id_of, _replace)
      when is_list(units) and substitutions == %{},
      do: units

  def substitute(units, substitutions, id_of, replace)
      when is_list(units) and is_map(substitutions) and is_function(id_of, 1) and
             is_function(replace, 2) do
    Enum.map(units, fn unit ->
      case id_of.(unit) do
        nil -> unit
        id -> substitute_unit(unit, Map.fetch(substitutions, id), replace)
      end
    end)
  end

  defp substitute_unit(unit, :error, _replace), do: unit
  defp substitute_unit(unit, {:ok, text}, replace) when is_binary(text), do: replace.(unit, text)
end
