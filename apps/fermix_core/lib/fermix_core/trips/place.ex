defmodule FermixCore.Trips.Place do
  @moduledoc """
  A stop's place as a trip keeps it (M89 §05, `place_json`): the wire's
  `place` cut to what identifies the place and where it is, `name` and
  `location` always, and `address`, `apple_place_id`, `source_url`,
  `canonical_url` and `categories` where they were given. No rating, price,
  hours or distance: those are a moment's facts about a business, not the
  owner's plan. Pure.

  A record is a map with string keys, as the wire carries it and the store
  keeps it. `cut/1` takes a whole record a device sent (C32), refusing one out
  of its bounds; `from_search/1` takes a place search's record, whose words
  are a provider's, and cuts what is long. Control characters and bidi
  overrides are taken out of every word either way.
  """

  @name_max 200
  @address_max 300
  @id_max 256
  @url_max 2_048
  @category_max 64
  @max_categories 5
  @max_bytes 4_096
  @urls ["source_url", "canonical_url"]
  # Each field by the name a refusal gives it.
  @fields %{
    "name" => :name,
    "address" => :address,
    "apple_place_id" => :apple_place_id,
    "source_url" => :source_url,
    "canonical_url" => :canonical_url
  }
  @control ~r/[\p{Cc}\p{Zl}\p{Zp}\x{202A}-\x{202E}\x{2066}-\x{2069}]/u

  @typedoc "A place as a stop keeps it, string-keyed."
  @type t :: %{required(String.t()) => term()}

  @doc """
  A device's whole record, cut to the stored fields: `{:error, {:invalid_place,
  field}}` names the first field out of its bounds.
  """
  @spec cut(map()) :: {:ok, t()} | {:error, {:invalid_place, atom()}}
  def cut(record) when is_map(record) do
    with {:ok, name} <- text(record, "name", @name_max, :required),
         {:ok, location} <- location(Map.get(record, "location")),
         {:ok, facts} <- facts(record),
         cut = Map.merge(%{"name" => name, "location" => location}, facts),
         :ok <- small(cut) do
      {:ok, cut}
    end
  end

  @doc """
  A place search's record (`PlaceSearch`'s atom-keyed result) as a stop keeps
  it: the name and address cut to their bounds, the first five categories, and
  only links that are https.
  """
  @spec from_search(map()) :: {:ok, t()} | {:error, {:invalid_place, atom()}}
  def from_search(record) when is_map(record) do
    %{
      "name" => clipped(Map.get(record, :name), @name_max),
      "location" => search_location(Map.get(record, :location)),
      "address" => clipped(Map.get(record, :address), @address_max),
      "apple_place_id" => Map.get(record, :apple_place_id),
      "source_url" => https_or_nil(Map.get(record, :source_url)),
      "canonical_url" => https_or_nil(Map.get(record, :canonical_url)),
      "categories" => search_categories(Map.get(record, :categories))
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
    |> cut()
  end

  @doc "A record's location as `Trips.Geo` takes a point, or nil for no place."
  @spec point(t() | nil) :: %{latitude: number(), longitude: number()} | nil
  def point(nil), do: nil

  def point(%{"location" => %{"latitude" => latitude, "longitude" => longitude}}),
    do: %{latitude: latitude, longitude: longitude}

  # --- a record's fields -----------------------------------------------------

  defp facts(record) do
    with {:ok, texts} <- optional_texts(record),
         {:ok, urls} <- optional_urls(record),
         {:ok, categories} <- categories(Map.get(record, "categories")) do
      {:ok, texts |> Map.merge(urls) |> Map.merge(categories)}
    end
  end

  defp optional_texts(record) do
    Enum.reduce_while(["address", "apple_place_id"], {:ok, %{}}, fn key, {:ok, acc} ->
      case text(record, key, max_of(key), :optional) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp max_of("address"), do: @address_max
  defp max_of("apple_place_id"), do: @id_max

  defp optional_urls(record) do
    Enum.reduce_while(@urls, {:ok, %{}}, fn key, {:ok, acc} ->
      case Map.get(record, key) do
        nil -> {:cont, {:ok, acc}}
        url -> https(url, key, acc)
      end
    end)
  end

  defp https(url, key, acc) do
    if https?(url),
      do: {:cont, {:ok, Map.put(acc, key, url)}},
      else: {:halt, {:error, {:invalid_place, Map.fetch!(@fields, key)}}}
  end

  defp https?(url) when is_binary(url) and byte_size(url) <= @url_max do
    match?(
      {:ok, %URI{scheme: "https", host: host}} when is_binary(host) and host != "",
      URI.new(url)
    )
  end

  defp https?(_url), do: false

  # An optional field given empty is absent; a required one is refused.
  defp text(record, key, max, presence) do
    case {Map.get(record, key), presence} do
      {nil, :optional} -> {:ok, nil}
      {value, _presence} when is_binary(value) -> bounded(clean(value), key, max, presence)
      _other -> {:error, {:invalid_place, Map.fetch!(@fields, key)}}
    end
  end

  defp bounded("", _key, _max, :optional), do: {:ok, nil}

  defp bounded(value, key, max, _presence) do
    if value != "" and String.length(value) <= max,
      do: {:ok, value},
      else: {:error, {:invalid_place, Map.fetch!(@fields, key)}}
  end

  defp location(%{"latitude" => latitude, "longitude" => longitude})
       when is_number(latitude) and latitude >= -90 and latitude <= 90 and
              is_number(longitude) and longitude >= -180 and longitude <= 180,
       do: {:ok, %{"latitude" => latitude, "longitude" => longitude}}

  defp location(_location), do: {:error, {:invalid_place, :location}}

  defp categories(nil), do: {:ok, %{}}

  defp categories(list) when is_list(list) and length(list) <= @max_categories do
    cleaned = Enum.map(list, &category/1)

    if Enum.all?(cleaned, &is_binary/1),
      do: {:ok, %{"categories" => cleaned}},
      else: {:error, {:invalid_place, :categories}}
  end

  defp categories(_too_many), do: {:error, {:invalid_place, :categories}}

  defp category(value) when is_binary(value) do
    case clean(value) do
      "" -> nil
      cleaned -> if String.length(cleaned) <= @category_max, do: cleaned
    end
  end

  defp category(_value), do: nil

  defp small(cut) do
    if byte_size(Jason.encode!(cut)) <= @max_bytes,
      do: :ok,
      else: {:error, {:invalid_place, :size}}
  end

  # --- a search's words ------------------------------------------------------

  defp clipped(value, max) when is_binary(value), do: value |> clean() |> String.slice(0, max)
  defp clipped(_value, _max), do: nil

  defp search_location(%{latitude: latitude, longitude: longitude}),
    do: %{"latitude" => latitude, "longitude" => longitude}

  defp search_location(_location), do: nil

  defp https_or_nil(url), do: if(https?(url), do: url)

  defp search_categories(list) when is_list(list) do
    list
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&clipped(&1, @category_max))
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(@max_categories)
    |> case do
      [] -> nil
      kept -> kept
    end
  end

  defp search_categories(_categories), do: nil

  defp clean(value), do: value |> String.replace(@control, "") |> String.trim()
end
