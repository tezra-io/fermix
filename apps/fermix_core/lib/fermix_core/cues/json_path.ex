defmodule FermixCore.Cues.JsonPath do
  @moduledoc """
  The dot paths cue sources read a JSON document by: a JSON API feed
  (`Cues.FeedParser`), a webhook (`Cues.Webhook`) and a stream with no preset
  (`Cues.JsonStream`), so all three read the same paths the same way.

  A path is `"."` (the document itself) or at most 16 segments joined by dots,
  each 1 to 128 characters with no dot and no whitespace. A segment names an
  object key; on a list, a segment that is a whole number indexes it. Nothing
  in a path is evaluated. `fields/3` reads a whole cue item by its paths, the
  same for a JSON API feed and a stream.

  Pure: no I/O, no clock.
  """

  alias FermixCore.Plugins.CanonicalJson

  @max_segments 16
  @segment ~r/^[^.\s]{1,128}$/u
  @max_id_bytes 512

  @doc "Whether `path` is `\".\"` or a dot path of at most 16 well-formed segments."
  @spec valid?(term()) :: boolean()
  def valid?("."), do: true

  def valid?(path) when is_binary(path) do
    segments = String.split(path, ".")
    length(segments) <= @max_segments and Enum.all?(segments, &Regex.match?(@segment, &1))
  end

  def valid?(_path), do: false

  @doc """
  The value at `path` in `document`, or `:error` when a segment names a key
  the object lacks, an index the list does not have, or steps into a scalar.
  The walk takes one step per segment of `path`.
  """
  @spec lookup(term(), String.t()) :: {:ok, term()} | :error
  def lookup(document, "."), do: {:ok, document}

  def lookup(document, path) when is_binary(path),
    do: path |> String.split(".") |> Enum.reduce_while({:ok, document}, &step/2)

  @doc """
  The text at `path`: a string trimmed (nil when blank) or an integer as its
  decimal text; nil for anything else, for a missing value, and for a nil path.
  """
  @spec scalar(term(), String.t() | nil) :: String.t() | nil
  def scalar(_document, nil), do: nil

  def scalar(document, path) when is_binary(path) do
    case lookup(document, path) do
      {:ok, value} when is_binary(value) -> blank_to_nil(String.trim(value))
      {:ok, value} when is_integer(value) -> Integer.to_string(value)
      _other -> nil
    end
  end

  @doc """
  The time at `path` read as RFC 3339, or nil when it is missing, empty or
  not a time.
  """
  @spec time(term(), String.t() | nil) :: DateTime.t() | nil
  def time(document, path) do
    with text when is_binary(text) <- scalar(document, path),
         {:ok, at, _offset} <- DateTime.from_iso8601(text) do
      at
    else
      _absent_or_unparsed -> nil
    end
  end

  @doc """
  The item fields of one JSON entry read by `paths` (at least `id_path`), as
  `Cues.Item.new/2` takes them: identity at `id_path` (nil when missing, which
  the reader refuses; replaced by `"sha256:"` and its digest past 512 bytes),
  revision `"1"` and type `default_type` when their paths find nothing,
  subject and time (`time/2`) nil, data the entry itself, no title. A JSON API
  feed reads each item this way with type `"feed.item"`, a stream with no
  preset with `"stream.item"`.
  """
  @spec fields(term(), map(), String.t()) :: map()
  def fields(entry, %{id_path: id_path} = paths, default_type)
      when is_binary(id_path) and is_binary(default_type) do
    %{
      item_id: entry |> scalar(id_path) |> bounded_id(),
      revision: scalar(entry, paths[:revision_path]) || "1",
      type: scalar(entry, paths[:type_path]) || default_type,
      subject: scalar(entry, paths[:subject_path]),
      occurred_at: time(entry, paths[:time_path]),
      datacontenttype: "application/json",
      data: entry,
      title: nil
    }
  end

  defp bounded_id(id) when is_binary(id) and byte_size(id) > @max_id_bytes do
    {:ok, digest} = CanonicalJson.digest([id])
    "sha256:" <> digest
  end

  defp bounded_id(id), do: id

  defp step(key, {:ok, %{} = object}) do
    case Map.fetch(object, key) do
      {:ok, value} -> {:cont, {:ok, value}}
      :error -> {:halt, :error}
    end
  end

  defp step(key, {:ok, list}) when is_list(list) do
    case Integer.parse(key) do
      {index, ""} when index >= 0 and index < length(list) -> {:cont, {:ok, Enum.at(list, index)}}
      _other -> {:halt, :error}
    end
  end

  defp step(_key, _acc), do: {:halt, :error}

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(text), do: text
end
