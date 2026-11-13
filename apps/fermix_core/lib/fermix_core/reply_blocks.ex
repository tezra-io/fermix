defmodule FermixCore.ReplyBlocks do
  @moduledoc """
  The records a reply can be drawn with (M72 §8): one owner for the place
  records a conversation's searches returned, and for the blocks a reply's
  text makes of them.

  The holder keeps, per conversation key, the places `place_search` handed the
  model (`put_places/3`) and the lists `checklist_read` and `checklist_edit`
  read or changed (`put_checklists/3`, M85 §07), until the companion turn
  writer takes them for the reply it writes (`take/2`). It is bounded whichever channel ran the search:
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

  `links/2` is the same reading's other half: the links a reply names that no
  block draws, which are the ones its link previews are made from.

  `checklists/1` is the other block (M85 §07): the lists the turn's list tools
  read or changed, in the order the turn first touched them, at most eight,
  each its id, its newest title and the ids of the rows the turn added or
  changed, none for a list it only read. Ids, never words: a client draws a
  list's rows as they stand now. `build/2` adds it after the places.

  `events/1` is the third (EVENTS_DRAWN_AS_CARDS §04): every event the turn's
  event tools returned, as each tool handed it over (`put_events/3`, the
  card `FermixCore.Temporal.Card` makes of its record), once each in its last
  state, the ones the turn changed first in the order it first changed them
  and the rest by date, at most eight. A receipt, not a live view: the card
  is the event as the reply left it. `build/2` adds it after the lists, and a
  job's delivery keeps the lists and the events (`delivered/1`).

  ## Which blocks a session is sent, and which it draws

  `drawn_types/3` is the one answer to both. A block that is a snapshot of
  tool records (`places`, `events`) is drawn from the protocol version of the
  session's wire that brought it; a kept kind (`checklists`, the owner's
  lists) is drawn by a session that pulled its index. A session is sent the
  types it would draw with every kept kind pulled (`sent_types/2`), since a
  kept kind's block names ids a client pulls to draw, so a session is never
  told a type is drawn that it is not sent. `for_session/4` is the filter
  every row leaves by: a `text_done`, a `row` and each message of a
  `history_page` keep only the blocks their session is sent.
  """

  use GenServer

  @types ["places", "checklists", "events"]
  # The version of each wire that brought a block type (M72 and M85 rode
  # every version as additive keys; events came with companion 8 and mobile
  # 3, the versions in which a row may carry more than two block types).
  @type_versions %{
    "places" => %{companion: 1, mobile: 1},
    "checklists" => %{companion: 1, mobile: 1},
    "events" => %{companion: 8, mobile: 3}
  }
  # The kept kinds, by the block that names them: drawn once their index is pulled.
  @kept_kinds %{"checklists" => :lists}
  @wires [:companion, :mobile]
  # The server events a reply's blocks leave by, on both wires.
  @row_events ["text_done", "row", "history_page"]
  @max_places 10
  @max_checklists 8
  @max_events 8
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

  @typedoc """
  A list a tool read or changed: its id and title, and the ids of the rows the
  call added or changed (none for a list it only read).
  """
  @type checklist_touch :: %{list_id: String.t(), title: String.t(), rows: [String.t()]}

  @typedoc """
  An event an event tool returned, as the `events` block carries it
  (`FermixCore.Temporal.Card`), string keyed.
  """
  @type event_card :: %{required(String.t()) => term()}

  @typedoc "What the holder keeps: a place a search returned, a list a tool touched, an event."
  @type record :: map() | {:checklist, checklist_touch()} | {:event, event_card()}

  @typedoc "A session's wire: the Mac's companion socket, or a phone's mobile session."
  @type wire :: :companion | :mobile

  @typedoc "A kept kind a session pulls the index of: today, the owner's lists."
  @type kept_kind :: :lists

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

  @doc "The most lists one `checklists` block names."
  @spec max_checklists() :: pos_integer()
  def max_checklists, do: @max_checklists

  @doc "The most events one `events` block carries."
  @spec max_events() :: pos_integer()
  def max_events, do: @max_events

  @doc """
  The block types a session on `wire` at protocol `version` draws, in
  `types/0` order, with `pulled` the kept kinds whose index it pulled: each
  snapshot type its version carries, and each kept kind it pulled whose type
  its version carries (moduledoc). The one answer to what the model is told
  is drawn and, through `sent_types/2`, to what the session is sent.
  """
  @spec drawn_types(wire(), pos_integer(), [kept_kind()]) :: [String.t()]
  def drawn_types(wire, version, pulled)
      when wire in @wires and is_integer(version) and version > 0 and is_list(pulled) do
    Enum.filter(@types, fn type ->
      version >= @type_versions[type][wire] and pulled_kind?(type, pulled)
    end)
  end

  defp pulled_kind?(type, pulled) do
    case Map.fetch(@kept_kinds, type) do
      {:ok, kind} -> kind in pulled
      :error -> true
    end
  end

  @doc """
  The block types a session on `wire` at protocol `version` is sent: the ones
  it would draw with every kept kind pulled (`drawn_types/3`), since a kept
  kind's block names what a client pulls to draw.
  """
  @spec sent_types(wire(), pos_integer()) :: [String.t()]
  def sent_types(wire, version), do: drawn_types(wire, version, Map.values(@kept_kinds))

  @doc """
  Server event `type`'s `payload` as a session on `wire` at protocol
  `version` is sent it: a `text_done`'s and a `row`'s `blocks`, and each
  `history_page` message's, keep only the types `sent_types/2` names, and a
  row left with none has no `blocks` key. Every other event is unchanged.
  This is the one filter a row leaves by, on both wires.
  """
  @spec for_session(String.t(), map(), wire(), pos_integer() | nil) :: map()
  def for_session(type, payload, wire, version)
      when type in ["text_done", "row"] and is_map(payload) and is_integer(version),
      do: keep_sent(payload, sent_types(wire, version))

  def for_session("history_page", %{"messages" => messages} = payload, wire, version)
      when is_list(messages) and is_integer(version) do
    sent = sent_types(wire, version)
    %{payload | "messages" => Enum.map(messages, &keep_sent(&1, sent))}
  end

  def for_session(type, payload, wire, _version)
      when is_binary(type) and type not in @row_events and is_map(payload) and wire in @wires,
      do: payload

  defp keep_sent(%{"blocks" => blocks} = row, sent) when is_list(blocks) do
    case Enum.filter(blocks, &(&1["type"] in sent)) do
      [] -> Map.delete(row, "blocks")
      kept -> %{row | "blocks" => kept}
    end
  end

  defp keep_sent(row, _sent), do: row

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
  Keep `touches`, the lists a list tool read or changed, under the
  conversation it ran in, after the records already kept.
  """
  @spec put_checklists(GenServer.server(), conversation_key(), [checklist_touch()]) :: :ok
  def put_checklists(server \\ __MODULE__, conversation_key, touches)
      when is_tuple(conversation_key) and tuple_size(conversation_key) == 3 and is_list(touches) do
    GenServer.call(server, {:put, conversation_key, Enum.map(touches, &checklist_record/1)})
  end

  defp checklist_record(%{list_id: id, title: title, rows: rows})
       when is_binary(id) and is_binary(title) and is_list(rows),
       do: {:checklist, %{list_id: id, title: title, rows: rows}}

  @doc """
  Keep `cards`, the events an event tool returned (`FermixCore.Temporal.Card`),
  under the conversation it ran in, after the records already kept.
  """
  @spec put_events(GenServer.server(), conversation_key(), [event_card()]) :: :ok
  def put_events(server \\ __MODULE__, conversation_key, cards)
      when is_tuple(conversation_key) and tuple_size(conversation_key) == 3 and is_list(cards) do
    GenServer.call(server, {:put, conversation_key, Enum.map(cards, &event_record/1)})
  end

  defp event_record(%{"event_id" => id, "date" => date} = card)
       when is_binary(id) and is_binary(date),
       do: {:event, card}

  @doc """
  The conversation's live records, oldest first, which the holder then
  forgets.
  """
  @spec take(GenServer.server(), conversation_key()) :: [record()]
  def take(server \\ __MODULE__, conversation_key)
      when is_tuple(conversation_key) and tuple_size(conversation_key) == 3 do
    GenServer.call(server, {:take, conversation_key})
  end

  @doc """
  The blocks a reply's `text` makes of `records`: a `places` block with the
  places the text links, when it links any, then a `checklists` block with the
  lists the turn touched, when it touched any, then an `events` block with the
  events its event tools returned, when they returned any. When two records
  name the same link, the later one (the newer search) is the one drawn.
  """
  @spec build(String.t(), [record()]) :: [block()]
  def build(text, records) when is_binary(text) and is_list(records) do
    index = records |> places() |> url_index()

    text
    |> read_links()
    |> Enum.flat_map(&linked_record(index, &1))
    |> Enum.flat_map(&place/1)
    |> Enum.uniq_by(&{&1["name"], &1["location"]})
    |> Enum.take(@max_places)
    |> places_block()
    |> Kernel.++(checklists(records))
    |> Kernel.++(events(records))
  end

  @doc """
  The blocks a job's delivery keeps of its run's `records`: the lists and the
  events, which need no link in the text, so a morning brief that read
  `event_list` draws its agenda. Places stay out: a delivery is not a reply
  whose links name them.
  """
  @spec delivered([record()]) :: [block()]
  def delivered(records) when is_list(records), do: checklists(records) ++ events(records)

  @doc """
  The `events` block `records` make: `[]`, or one block carrying each event
  an event tool returned, once, in its last state, with the latest change the
  turn made to it: the events the turn changed first, in the order it first
  changed them, then the rest by date and time (an event with no time first
  on its day), at most #{@max_events}.
  """
  @spec events([record()]) :: [block()]
  def events(records) when is_list(records) do
    {changed, listed} =
      records
      |> Enum.flat_map(fn
        {:event, card} -> [card]
        _other -> []
      end)
      |> Enum.reduce([], &merge_event/2)
      |> Enum.reverse()
      |> Enum.split_with(&Map.has_key?(&1, "change"))

    (changed ++ Enum.sort_by(listed, &{&1["date"], Map.get(&1, "time", ""), &1["event_id"]}))
    |> Enum.take(@max_events)
    |> events_block()
  end

  # Newest first while folding: an event returned again keeps its place and
  # takes its newest state, and the latest change the turn made to it. An
  # event first only listed and changed later moves to where it was changed.
  defp merge_event(card, merged) do
    case Enum.find_index(merged, &(&1["event_id"] == card["event_id"])) do
      nil ->
        [card | merged]

      index ->
        kept = Enum.at(merged, index)
        newest = keep_change(card, kept)

        if Map.has_key?(kept, "change") or not Map.has_key?(newest, "change"),
          do: List.replace_at(merged, index, newest),
          else: [newest | List.delete_at(merged, index)]
    end
  end

  defp keep_change(%{"change" => _change} = card, _kept), do: card

  defp keep_change(card, %{"change" => change}), do: Map.put(card, "change", change)
  defp keep_change(card, _kept), do: card

  defp events_block([]), do: []
  defp events_block(cards), do: [%{"type" => "events", "events" => cards}]

  @doc """
  The `checklists` block `records` make: `[]`, or one block naming each list a
  list tool touched, in first-touch order, at most #{@max_checklists}, with the
  rows every touch of it added or changed, in the order they were first named.
  """
  @spec checklists([record()]) :: [block()]
  def checklists(records) when is_list(records) do
    records
    |> Enum.flat_map(fn
      {:checklist, touch} -> [touch]
      _place -> []
    end)
    |> Enum.reduce([], &merge_touch/2)
    |> Enum.reverse()
    |> Enum.take(@max_checklists)
    |> checklists_block()
  end

  # Newest first while folding: a list touched again keeps its first place,
  # takes its newest title and adds the rows it had not named.
  defp merge_touch(touch, merged) do
    case Enum.find_index(merged, &(&1.list_id == touch.list_id)) do
      nil ->
        [touch | merged]

      index ->
        List.update_at(merged, index, fn kept ->
          %{kept | title: touch.title, rows: kept.rows ++ (touch.rows -- kept.rows)}
        end)
    end
  end

  defp checklists_block([]), do: []

  defp checklists_block(lists) do
    [
      %{
        "type" => "checklists",
        "lists" =>
          Enum.map(lists, &%{"list_id" => &1.list_id, "title" => &1.title, "rows" => &1.rows})
      }
    ]
  end

  @doc """
  The links a reply's `text` names, in order and once each, less the ones its
  `blocks` draw: a place's `canonical_url` or `source_url`, compared as
  `build/2` matches them. A place's card carries what its page would preview,
  and a listing page's picture is the listing's, so those are never fetched.
  """
  @spec links(String.t(), [block()]) :: [String.t()]
  def links(text, blocks \\ []) when is_binary(text) and is_list(blocks) do
    drawn = blocks |> Enum.flat_map(&drawn_urls/1) |> Enum.flat_map(&url_key/1) |> MapSet.new()

    text
    |> read_links()
    |> Enum.uniq()
    |> Enum.reject(fn link -> link |> url_key() |> Enum.any?(&MapSet.member?(drawn, &1)) end)
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

  defp places(records), do: Enum.filter(records, &is_map/1)

  defp drawn_urls(%{"type" => "places", "places" => places}),
    do: Enum.flat_map(places, &[&1["canonical_url"], &1["source_url"]])

  defp drawn_urls(_block), do: []

  defp read_links(text) do
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
