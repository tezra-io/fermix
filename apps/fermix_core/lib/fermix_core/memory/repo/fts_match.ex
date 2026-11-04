defmodule FermixCore.Memory.Repo.FtsMatch do
  @moduledoc """
  The one way user or model text becomes an FTS5 `MATCH` argument. The text is
  words, never FTS syntax: it is split on whitespace and each token is passed as
  a quoted phrase, ANDed, so a hyphen, `OR`, `NEAR(`, a column filter or a stray
  quote are all literal words. A query with no searchable token is refused
  rather than run as an empty MATCH.
  """

  @spec expression(String.t()) :: {:ok, String.t()} | {:error, :empty_query}
  def expression(query) when is_binary(query) do
    tokens =
      query
      |> String.split(~r/\s+/u, trim: true)
      |> Enum.filter(&searchable_token?/1)

    case tokens do
      [] -> {:error, :empty_query}
      tokens -> {:ok, Enum.map_join(tokens, " AND ", &quoted_token/1)}
    end
  end

  # A token with no letter or digit cannot be tokenized by FTS5 and would make
  # the phrase a syntax error, so it is dropped.
  defp searchable_token?(token), do: Regex.match?(~r/[\p{L}\p{N}]/u, token)

  defp quoted_token(token), do: ~s("#{String.replace(token, ~s("), ~s(""))}")
end
