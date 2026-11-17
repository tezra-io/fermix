defmodule FermixCore.PhoneCalls.Outcome.Claim do
  @moduledoc """
  What the outcome extraction says the call established, read strictly
  (M94 §7, "Completion reporting").

  The answer is one JSON object, alone or inside one code fence, with only
  the keys below; `outcome` and `commitment` are required, the rest default
  to null or empty. A value of the wrong type, a word outside its set, an
  unknown key, or a list or string past its bound is malformed, never
  repaired: a claim is the model's reading, and `Outcome.verify/3` is what
  decides what survives of it.
  """

  alias FermixCore.PhoneCalls.Brief
  alias FermixCore.PhoneCalls.Limits

  # Each bound reads the one it answers to. A quote is evidence an excerpt
  # holds (`Limits.max_excerpt_bytes/0`); a value is a fact the report shows
  # (`Limits.max_report_fact_bytes/0`); a note is the record's text
  # (`Limits.max_record_text_bytes/0`); each fact and option is an excerpt
  # (`Limits.max_evidence_excerpts/0`); a criterion or an alternative is
  # one of the brief's (`Brief.bounds/0`); the reply's size and the
  # corrections a claim may list are the feature's own
  # (`Limits.max_extraction_reply_bytes/0`, `Limits.max_claim_corrections/0`).

  @outcomes %{
    "confirmed" => :confirmed,
    "unavailable" => :unavailable,
    "options" => :options,
    "needs_owner" => :needs_owner,
    "unknown" => :unknown
  }
  @commitments %{
    "completed" => :completed,
    "offered" => :offered,
    "requested" => :requested,
    "none" => :none
  }
  @fact_fields %{
    "date" => :date,
    "local_time" => :local_time,
    "party" => :party,
    "terms" => :terms,
    "reference" => :reference
  }
  @correction_fields Map.put(@fact_fields, "other", :other)

  @keys ~w(outcome commitment confirmation_quote readback_quote criteria facts alternative
           corrections options reason_quote contradiction note)

  @type outcome :: :confirmed | :unavailable | :options | :needs_owner | :unknown
  @type fact_field :: :date | :local_time | :party | :terms | :reference
  @type t :: %{
          outcome: outcome(),
          commitment: :completed | :offered | :requested | :none,
          confirmation_quote: String.t() | nil,
          readback_quote: String.t() | nil,
          criteria: [%{index: pos_integer(), quote: String.t()}],
          facts: [%{field: fact_field(), value: String.t(), quote: String.t()}],
          alternative: pos_integer() | nil,
          corrections: [%{field: fact_field() | :other, quote: String.t()}],
          options: [%{value: String.t(), quote: String.t()}],
          reason_quote: String.t() | nil,
          contradiction: String.t() | nil,
          note: String.t() | nil
        }
  @type malformed :: {:malformed, atom() | {atom(), String.t()}}

  @doc "The extraction's reply text, read as a claim."
  @spec parse(String.t()) :: {:ok, t()} | {:error, malformed()}
  def parse(content) when is_binary(content) do
    with {:ok, json} <- unfenced(content),
         {:ok, decoded} <- decode(json),
         do: from_map(decoded)
  end

  @doc "A decoded JSON object, read as a claim."
  @spec from_map(term()) :: {:ok, t()} | {:error, malformed()}
  def from_map(map) when is_map(map) do
    with :ok <- known_keys(map),
         {:ok, outcome} <- word(map, "outcome", @outcomes, :bad_outcome),
         {:ok, commitment} <- word(map, "commitment", @commitments, :bad_commitment),
         {:ok, lists} <- lists(map),
         {:ok, texts} <- texts(map),
         {:ok, alternative} <- index(Map.get(map, "alternative"), "alternative") do
      {:ok,
       Map.merge(lists, texts)
       |> Map.merge(%{outcome: outcome, commitment: commitment, alternative: alternative})}
    end
  end

  def from_map(_other), do: malformed(:not_an_object)

  # -- the reply's shape ----------------------------------------------------------

  defp unfenced(content) do
    if byte_size(content) > Limits.max_extraction_reply_bytes(),
      do: malformed(:too_long),
      else: fenced_or_plain(content)
  end

  defp fenced_or_plain(content) do
    trimmed = String.trim(content)

    case Regex.run(~r/\A```(?:json)?[ \t]*\n(.*)\n```\z/s, trimmed) do
      [_whole, inner] -> {:ok, inner}
      nil -> {:ok, trimmed}
    end
  end

  defp decode(json) do
    case Jason.decode(json) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _other} -> malformed(:not_an_object)
      {:error, _reason} -> malformed(:not_json)
    end
  end

  defp known_keys(map) do
    if Enum.all?(Map.keys(map), &(&1 in @keys)), do: :ok, else: malformed(:unknown_key)
  end

  defp word(map, key, words, reason) do
    case Map.fetch(words, Map.get(map, key)) do
      {:ok, atom} -> {:ok, atom}
      :error -> malformed(reason)
    end
  end

  # -- lists ------------------------------------------------------------------------

  defp lists(map) do
    with {:ok, criteria} <-
           list(map, "criteria", Brief.bounds().completion_criteria, &criterion/1),
         {:ok, facts} <- list(map, "facts", Limits.max_evidence_excerpts(), &fact/1),
         {:ok, corrections} <-
           list(map, "corrections", Limits.max_claim_corrections(), &correction/1),
         {:ok, options} <- list(map, "options", Limits.max_evidence_excerpts(), &option/1) do
      {:ok, %{criteria: criteria, facts: facts, corrections: corrections, options: options}}
    end
  end

  defp list(map, key, max, each) do
    case Map.get(map, key) do
      nil -> {:ok, []}
      items when is_list(items) and length(items) <= max -> items |> Enum.map(each) |> collect()
      items when is_list(items) -> malformed({:too_many, key})
      _other -> malformed({:not_a_list, key})
    end
  end

  defp collect(results) do
    case Enum.find(results, &match?({:error, _}, &1)) do
      nil -> {:ok, Enum.map(results, fn {:ok, value} -> value end)}
      failed -> failed
    end
  end

  defp criterion(%{"index" => index, "quote" => quote} = item) when map_size(item) == 2 do
    with {:ok, index} <- index(index, "criteria"),
         {:ok, quote} <- text(quote, Limits.max_excerpt_bytes(), "quote"),
         do: {:ok, %{index: index, quote: quote}}
  end

  defp criterion(_item), do: malformed({:bad_item, "criteria"})

  defp fact(%{"field" => field, "value" => value, "quote" => quote} = item)
       when map_size(item) == 3 do
    with {:ok, field} <- field(field, @fact_fields, {:bad_field, "facts"}),
         {:ok, value} <- text(value, Limits.max_report_fact_bytes(), "value"),
         {:ok, quote} <- text(quote, Limits.max_excerpt_bytes(), "quote"),
         do: {:ok, %{field: field, value: value, quote: quote}}
  end

  defp fact(_item), do: malformed({:bad_item, "facts"})

  defp correction(%{"field" => field, "quote" => quote} = item) when map_size(item) == 2 do
    with {:ok, field} <- field(field, @correction_fields, {:bad_field, "corrections"}),
         {:ok, quote} <- text(quote, Limits.max_excerpt_bytes(), "quote"),
         do: {:ok, %{field: field, quote: quote}}
  end

  defp correction(_item), do: malformed({:bad_item, "corrections"})

  defp option(%{"value" => value, "quote" => quote} = item) when map_size(item) == 2 do
    with {:ok, value} <- text(value, Limits.max_report_fact_bytes(), "value"),
         {:ok, quote} <- text(quote, Limits.max_excerpt_bytes(), "quote"),
         do: {:ok, %{value: value, quote: quote}}
  end

  defp option(_item), do: malformed({:bad_item, "options"})

  defp field(word, fields, reason) do
    case Map.fetch(fields, word) do
      {:ok, field} -> {:ok, field}
      :error -> malformed(reason)
    end
  end

  # -- scalars ----------------------------------------------------------------------

  defp texts(map) do
    with {:ok, confirmation} <-
           optional_text(map, "confirmation_quote", Limits.max_excerpt_bytes()),
         {:ok, readback} <- optional_text(map, "readback_quote", Limits.max_excerpt_bytes()),
         {:ok, reason} <- optional_text(map, "reason_quote", Limits.max_excerpt_bytes()),
         {:ok, contradiction} <-
           optional_text(map, "contradiction", Limits.max_record_text_bytes()),
         {:ok, note} <- optional_text(map, "note", Limits.max_record_text_bytes()) do
      {:ok,
       %{
         confirmation_quote: confirmation,
         readback_quote: readback,
         reason_quote: reason,
         contradiction: contradiction,
         note: note
       }}
    end
  end

  defp optional_text(map, key, max) do
    case Map.get(map, key) do
      nil -> {:ok, nil}
      value -> text(value, max, key)
    end
  end

  defp text(value, max, name) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" -> malformed({:blank, name})
      byte_size(trimmed) > max -> malformed({:too_long, name})
      true -> {:ok, trimmed}
    end
  end

  defp text(_value, _max, name), do: malformed({:not_a_string, name})

  defp index(nil, "alternative"), do: {:ok, nil}

  defp index(n, name) when is_integer(n) and n >= 1 do
    if n <= max_index(), do: {:ok, n}, else: malformed({:bad_index, name})
  end

  defp index(_n, name), do: malformed({:bad_index, name})

  # A criterion's or an alternative's number: the brief holds no more of either.
  defp max_index, do: max(Brief.bounds().completion_criteria, Brief.bounds().list_items)

  defp malformed(reason), do: {:error, {:malformed, reason}}
end
