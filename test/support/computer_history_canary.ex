defmodule FermixTestSupport.ComputerHistoryCanary do
  @moduledoc """
  Shared taint probe for the Computer History privacy invariants (MILESTONE_32
  §14.2). Mint a unique, >=16-byte canary token, plant it in the spool or a
  fixture activity memory, then assert it never reaches a provider request body
  or a trace byte. `present?/2` deep-scans an arbitrary term (maps, lists,
  tuples, atoms, binaries) so a canary hidden anywhere in a captured request or
  telemetry payload is found.
  """

  @prefix "CH-CANARY"

  @doc "Mint a unique canary token (>= 16 bytes). `label` aids test readability."
  @spec token(String.t()) :: String.t()
  def token(label \\ "tok") when is_binary(label) do
    "#{@prefix}-#{label}-#{System.unique_integer([:positive, :monotonic])}-0a1b2c3d4e5f6a7b"
  end

  @doc "Whether `token` appears anywhere inside `term` (deep scan)."
  @spec present?(term(), String.t()) :: boolean()
  def present?(term, token) when is_binary(token), do: scan(term, token)

  @doc "Whether `token` appears nowhere inside `term`."
  @spec absent?(term(), String.t()) :: boolean()
  def absent?(term, token) when is_binary(token), do: not scan(term, token)

  defp scan(term, token) when is_binary(term), do: String.contains?(term, token)
  defp scan(term, token) when is_list(term), do: Enum.any?(term, &scan(&1, token))

  defp scan(term, token) when is_map(term) do
    Enum.any?(term, fn {key, value} -> scan(key, token) or scan(value, token) end)
  end

  defp scan(term, token) when is_tuple(term), do: term |> Tuple.to_list() |> scan(token)

  defp scan(term, token) when is_atom(term) and not is_nil(term),
    do: scan(Atom.to_string(term), token)

  defp scan(_term, _token), do: false
end
