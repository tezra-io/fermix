defmodule FermixCore.ReplyBlocks do
  @moduledoc """
  The records a reply can be drawn with (M72 §8): one owner for the place
  records a conversation's searches returned, and for the blocks a reply's
  text makes of them.

  The holder keeps, per conversation key, the places `place_search` handed the
  model (`put_places/3`), until the companion turn writer takes them for the
  reply it writes (`take/2`). It is bounded whichever channel ran the search:
  a record expires 30 minutes after it was put, a conversation keeps its newest
  50, and expired records of every conversation are dropped on each call, so a
  conversation that never takes holds nothing past the window.

  `build/2` is pure. The link is the reference: it reads the links in a reply's
  text in order (a markdown link's target or a bare URL) and keeps the places
  whose `canonical_url` or `source_url` the text links, compared with scheme
  and host in lower case, without the fragment and without a trailing slash on
  the path. Places come in the order the text first links them, once each, at
  most ten, and a place with no usable coordinates is left out (it stays a link
  in the text). A place is a subset of the M31 record under its own names, as
  `priv/companion/protocol.schema.json` (`place`) exports it; an Apple Maps
  place carries its `apple_place_id` too, which a Mac opens it by (M72 §14.1).
  A reply that links none gets no block.
  """

  use GenServer

  @types ["places"]
  @max_places 10
  @max_categories 5
  @max_records 50
  @ttl_ms 30 * 60 * 1_000

  # A link a reader clicks: a markdown link's target (the text between its
  # brackets may hold anything but a bracket), an autolink, or a bare URL. A
  # bare URL stops at a bracket or a parenthesis, so the markdown around one,
  # bold included, is never read as part of it.
  @link ~r{\[[^\]\n]*\]\((https?://[^\s)]+)[^)\n]*\)|<(https?://[^\s>]+)>|(https?://[^\s<>"'()\[\]]+)}iu
  @trailing_punctuation ~r/[.,;:!?*_~]+\z/u

  @typedoc "A conversation's key, as `FermixCore.Agents.ConversationKey` derives it."
  @type conversation_key :: FermixCore.Agents.ConversationKey.t()

  @typedoc "One block under a reply, string keyed as the wire carries it."
  @type block :: %{required(String.t()) => term()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "The block types a reply may carry, one block of each at most."
  @spec types() :: [String.t()]
  def types, do: @types

  @doc "The most places one `places` block holds."
  @spec max_places() :: pos_integer()
  def max_places, do: @max_places

  @doc "The most categories one place carries."
  @spec max_categories() :: pos_integer()
  def max_categories, do: @max_categories

  @doc "The most place records a conversation keeps, newest kept."
  @spec max_records() :: pos_integer()
  def max_records, do: @max_records

  @doc "How long a place record is kept after it was put, in milliseconds."
  @spec ttl_ms() :: pos_integer()
  def ttl_ms, do: @ttl_ms

  @doc """
  Keep `places`, the records a search handed the model, under the
  conversation it ran in, after the ones already kept.
  """
  @spec put_places(GenServer.server(), conversation_key(), [map()]) :: :ok
  def put_places(server \\ __MODULE__, conversation_key, places)
      when is_tuple(conversation_key) and tuple_size(conversation_key) == 3 and is_list(places) do
    GenServer.call(server, {:put, conversation_key, places})
  end

  @doc """
  The conversation's live records, oldest first, which the holder then
  forgets.
  """
  @spec take(GenServer.server(), conversation_key()) :: [map()]
  def take(server \\ __MODULE__, conversation_key)
      when is_tuple(conversation_key) and tuple_size(conversation_key) == 3 do
    GenServer.call(server, {:take, conversation_key})
  end

  @doc """
  The blocks a reply's `text` makes of `records`: `[]`, or one `places` block
  with the places the text links. When two records name the same link, the
  later one (the newer search) is the one drawn.
  """
  @spec build(String.t(), [map()]) :: [block()]
  def build(text, records) when is_binary(text) and is_list(records) do
    index = url_index(records)

    text
    |> links()
    |> Enum.flat_map(&linked_record(index, &1))
    |> Enum.flat_map(&place/1)
    |> Enum.uniq_by(&{&1["name"], &1["location"]})
    |> Enum.take(@max_places)
    |> places_block()
  end

  # `:clock` answers the time in milliseconds; a test injects its own.
  @impl true
  def init(opts) do
    case Keyword.get(opts, :clock, &monotonic_ms/0) do
      clock when is_function(clock, 0) -> {:ok, %{clock: clock, conversations: %{}}}
      other -> {:stop, {:invalid_clock, other}}
    end
  end

  @impl true
  def handle_call({:put, key, places}, _from, state) do
    now = state.clock.()
    stamped = Enum.map(places, &{now, &1})
    conversations = sweep(state.conversations, now)
    kept = Enum.take(Map.get(conversations, key, []) ++ stamped, -@max_records)
    {:reply, :ok, %{state | conversations: Map.put(conversations, key, kept)}}
  end

  def handle_call({:take, key}, _from, state) do
    {records, conversations} = Map.pop(sweep(state.conversations, state.clock.()), key, [])
    {:reply, Enum.map(records, &elem(&1, 1)), %{state | conversations: conversations}}
  end

  defp sweep(conversations, now) do
    conversations
    |> Enum.map(fn {key, records} -> {key, Enum.filter(records, &live?(&1, now))} end)
    |> Enum.reject(fn {_key, records} -> records == [] end)
    |> Map.new()
  end

  defp live?({put_at, _place}, now), do: now - put_at < @ttl_ms

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  # -- building --------------------------------------------------------------

  defp links(text) do
    @link
    |> Regex.scan(text, capture: :all_but_first)
    |> Enum.map(&link/1)
  end

  defp link([markdown]), do: markdown
  defp link(["", autolink]), do: autolink
  defp link(["", "", bare]), do: String.replace(bare, @trailing_punctuation, "")

  # Later records overwrite earlier ones, so the newest search names the link.
  defp url_index(records) do
    Enum.reduce(records, %{}, fn record, index ->
      record
      |> Map.take([:canonical_url, :source_url])
      |> Map.values()
      |> Enum.flat_map(&url_key/1)
      |> Enum.reduce(index, &Map.put(&2, &1, record))
    end)
  end

  defp linked_record(index, url) do
    case url_key(url) do
      [key] -> index |> Map.get(key) |> List.wrap()
      [] -> []
    end
  end

  defp url_key(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host} = uri} when is_binary(scheme) and is_binary(host) ->
        [
          {String.downcase(scheme), uri.userinfo, String.downcase(host), uri.port,
           path_key(uri.path), uri.query}
        ]

      _invalid ->
        []
    end
  end

  defp url_key(_url), do: []

  defp path_key(nil), do: ""
  defp path_key(path), do: String.replace_suffix(path, "/", "")

  defp places_block([]), do: []
  defp places_block(places), do: [%{"type" => "places", "places" => places}]

  # A place's card: its name and coordinates, then each fact the source gave.
  defp place(%{name: name} = record) when is_binary(name) and name != "" do
    case location(Map.get(record, :location)) do
      {:ok, location} -> [card(record, name, location)]
      :error -> []
    end
  end

  defp place(_record), do: []

  defp card(record, name, location) do
    %{"name" => name, "location" => location}
    |> put_text("canonical_url", Map.get(record, :canonical_url))
    |> put_text("source_url", Map.get(record, :source_url))
    |> put_text("apple_place_id", Map.get(record, :apple_place_id))
    |> put_text("address", Map.get(record, :address))
    |> put_present("rating", rating(Map.get(record, :rating)))
    |> put_text("price_range", Map.get(record, :price_range))
    |> put_present("categories", categories(Map.get(record, :categories)))
    |> put_present("opening_hours", hours(Map.get(record, :opening_hours)))
    |> put_present("distance", distance(Map.get(record, :distance)))
  end

  defp location(%{latitude: latitude, longitude: longitude})
       when is_number(latitude) and latitude >= -90 and latitude <= 90 and
              is_number(longitude) and longitude >= -180 and longitude <= 180,
       do: {:ok, %{"latitude" => latitude, "longitude" => longitude}}

  defp location(_location), do: :error

  defp rating(rating) when is_map(rating) do
    %{}
    |> put_number("value", Map.get(rating, :value))
    |> put_number("best", Map.get(rating, :best))
    |> put_number("count", Map.get(rating, :count))
    |> nil_when_empty()
  end

  defp rating(_rating), do: nil

  defp categories(categories) when is_list(categories) do
    case categories |> Enum.filter(&(is_binary(&1) and &1 != "")) |> Enum.take(@max_categories) do
      [] -> nil
      kept -> kept
    end
  end

  defp categories(_categories), do: nil

  # Today's hours only, as the source wrote them; the other days stay out.
  defp hours(%{current_day: current_day}) when is_binary(current_day) and current_day != "",
    do: %{"current_day" => current_day}

  defp hours(_hours), do: nil

  # A distance means nothing without its units, so it needs both.
  defp distance(%{value: value, units: units})
       when is_number(value) and is_binary(units) and units != "",
       do: %{"value" => value, "units" => units}

  defp distance(_distance), do: nil

  defp put_text(map, key, value) when is_binary(value) and value != "",
    do: Map.put(map, key, value)

  defp put_text(map, _key, _value), do: map

  defp put_number(map, key, value) when is_number(value), do: Map.put(map, key, value)
  defp put_number(map, _key, _value), do: map

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp nil_when_empty(map) when map_size(map) == 0, do: nil
  defp nil_when_empty(map), do: map
end
