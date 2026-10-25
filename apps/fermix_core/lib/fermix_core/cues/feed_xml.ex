defmodule FermixCore.Cues.FeedXml do
  @moduledoc """
  Reads an RSS or Atom document as it arrives, one item at a time, for
  `Cues.FeedParser` (M60 §6.9).

  Saxy parses each piece (`Saxy.Partial`) with this module as its handler.
  Entity references other than XML's five stay literal and no DTD is read,
  as with `Saxy.SimpleForm`. The handler builds the tree `Saxy.SimpleForm`
  builds, `{name, attributes, children}`, except that an item leaves the tree
  when it closes and goes to the caller's `on_item` function with the
  caller's accumulator. An item is an `item` under the root `rss`'s
  `channel`, or an Atom `entry` under the root `feed`. What stays is the
  document outside its items: the channel's own elements, Atom's feed-level
  author.

  The root's start tag decides the format: `rss` is RSS, Atom's `feed`
  (prefixed or not) is Atom, anything else stops the parse at once.

  Bounds, so that memory follows one item and not the document's length: an
  item, and the document outside its items, each hold at most 4 MiB of text
  and markup (names and attribute values), past which the read is
  `:read_limit`; elements nest at most 64 deep, past which the feed is
  invalid. Nothing is cut short, so an item is read whole or not at all.
  Saxy is handed at most 64 KiB at a time and emits long text in pieces; it
  still holds one CDATA section, attribute value or DOCTYPE whole until it
  ends, so its own buffer is bounded only by what the caller lets it read.
  """

  @behaviour Saxy.Handler

  @max_piece_bytes 65_536
  @max_text_piece_bytes 65_536
  @max_held_bytes 4 * 1024 * 1024
  @max_depth 64

  @enforce_keys [:partial]
  defstruct @enforce_keys

  @type tree :: {String.t(), [{String.t(), String.t()}], [tree() | String.t()]}
  @type format :: :rss | {:atom, prefix :: String.t()}
  @type on_item :: (tree(), format(), term() -> term())
  @type error ::
          :read_limit
          | :invalid_feed
          | {:invalid_xml, Saxy.ParseError.t()}
          | {:unsupported_feed, String.t()}
  @opaque t :: %__MODULE__{partial: Saxy.Partial.t()}

  @doc """
  A reader that hands each closed item, with the format and `acc`, to
  `on_item`, whose result is the next `acc`.
  """
  @spec new(on_item(), term()) :: t()
  def new(on_item, acc) when is_function(on_item, 3) do
    state = %{
      stack: [],
      depth: 0,
      format: nil,
      channel?: false,
      item_depth: nil,
      held: %{item: 0, outside: 0},
      root: nil,
      on_item: on_item,
      acc: acc,
      error: nil
    }

    options = [expand_entity: :keep, character_data_max_length: @max_text_piece_bytes]
    {:ok, partial} = Saxy.Partial.new(__MODULE__, state, options)
    %__MODULE__{partial: partial}
  end

  @doc "Parses `chunk`, any size, in pieces of at most 64 KiB."
  @spec read(t(), binary()) :: {:ok, t()} | {:error, error()}
  def read(%__MODULE__{} = reader, chunk) when is_binary(chunk), do: read_pieces(reader, chunk)

  @doc """
  Ends the document: the format, the tree outside the items and the last
  accumulator, or why the document is not a feed.
  """
  @spec finish(t()) :: {:ok, %{format: format(), root: tree(), acc: term()}} | {:error, error()}
  def finish(%__MODULE__{partial: partial}) do
    # A stop raised by the last buffered bytes comes back as `{:ok, state}`.
    case Saxy.Partial.terminate(partial) do
      {:ok, %{error: nil} = state} -> result(state)
      {:ok, %{error: error}} -> {:error, error}
      {:error, %Saxy.ParseError{} = error} -> {:error, {:invalid_xml, error}}
    end
  end

  defp read_pieces(reader, <<>>), do: {:ok, reader}

  defp read_pieces(reader, chunk) do
    size = min(byte_size(chunk), @max_piece_bytes)
    <<piece::binary-size(size), rest::binary>> = chunk

    case Saxy.Partial.parse(reader.partial, piece) do
      {:cont, partial} -> read_pieces(%{reader | partial: partial}, rest)
      {:halt, %{error: error}} -> {:error, error}
      {:error, %Saxy.ParseError{} = error} -> {:error, {:invalid_xml, error}}
    end
  end

  defp result(%{format: :rss, channel?: false}), do: {:error, :invalid_feed}
  defp result(state), do: {:ok, %{format: state.format, root: state.root, acc: state.acc}}

  # --- handler ---------------------------------------------------------------

  @impl Saxy.Handler
  def handle_event(:start_element, {name, attributes}, %{depth: 0} = state) do
    case root_format(name) do
      {:ok, format} -> push(%{state | format: format}, name, attributes)
      :error -> {:stop, %{state | error: {:unsupported_feed, name}}}
    end
  end

  def handle_event(:start_element, _element, %{depth: depth} = state) when depth >= @max_depth,
    do: {:stop, %{state | error: :invalid_feed}}

  def handle_event(:start_element, {name, attributes}, state) do
    cond do
      item_start?(state, name) ->
        push(%{state | item_depth: state.depth + 1}, name, attributes)

      state.format == :rss and state.depth == 1 and name == "channel" ->
        push(%{state | channel?: true}, name, attributes)

      true ->
        push(state, name, attributes)
    end
  end

  def handle_event(:characters, text, %{stack: [frame | rest]} = state) do
    hold(%{state | stack: [%{frame | children: [text | frame.children]} | rest]}, byte_size(text))
  end

  def handle_event(:end_element, _name, %{stack: [frame | rest]} = state) do
    tree = {frame.name, frame.attributes, Enum.reverse(frame.children)}
    closed = %{state | stack: rest, depth: state.depth - 1}

    cond do
      state.item_depth == state.depth -> {:ok, item_closed(closed, tree)}
      rest == [] -> {:ok, %{closed | root: tree}}
      true -> {:ok, append(closed, tree)}
    end
  end

  # Prolog, document end, and text outside the root.
  def handle_event(_event, _data, state), do: {:ok, state}

  # --- the tree ----------------------------------------------------------------

  defp root_format("rss"), do: {:ok, :rss}
  defp root_format("feed"), do: {:ok, {:atom, ""}}

  # An Atom document may bind its namespace to a prefix (`<a:feed>`); every
  # Atom element then carries that prefix.
  defp root_format(name) do
    case String.split(name, ":", parts: 2) do
      [prefix, "feed"] -> {:ok, {:atom, prefix <> ":"}}
      _other -> :error
    end
  end

  defp item_start?(%{format: :rss, depth: 2, stack: [%{name: "channel"} | _rest]}, "item"),
    do: true

  defp item_start?(%{format: {:atom, prefix}, depth: 1}, name), do: name == prefix <> "entry"
  defp item_start?(_state, _name), do: false

  defp push(state, name, attributes) do
    frame = %{name: name, attributes: attributes, children: []}
    size = byte_size(name) + Enum.reduce(attributes, 0, &attribute_size/2)
    hold(%{state | stack: [frame | state.stack], depth: state.depth + 1}, size)
  end

  defp attribute_size({key, value}, total), do: total + byte_size(key) + byte_size(value)

  # Counts `size` against the item open now, or the document outside the
  # items, and stops the parse past what either may hold.
  defp hold(state, size) do
    scope = if state.item_depth, do: :item, else: :outside
    held = Map.update!(state.held, scope, &(&1 + size))

    if Map.fetch!(held, scope) > @max_held_bytes,
      do: {:stop, %{state | error: :read_limit}},
      else: {:ok, %{state | held: held}}
  end

  defp append(%{stack: [parent | rest]} = state, tree),
    do: %{state | stack: [%{parent | children: [tree | parent.children]} | rest]}

  defp item_closed(state, tree) do
    acc = state.on_item.(tree, state.format, state.acc)
    %{state | acc: acc, item_depth: nil, held: %{state.held | item: 0}}
  end
end
