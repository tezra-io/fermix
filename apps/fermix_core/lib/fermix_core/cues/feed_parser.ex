defmodule FermixCore.Cues.FeedParser do
  @moduledoc """
  Turns a feed response into cue item fields (M60 §6.4, §6.8, §6.9).

  Pure: no I/O, no clock, no process. The feed worker fetches the body, feeds
  it to a reader (`reader/2`, `read/2` for each piece, `finish/1`) and hands
  each result to `Cues.Item.new/2`. `parse/3` and `parse_json_api/3` are the
  same reader given a whole body.

  Formats: RSS 2.0, Atom 1.0 and JSON Feed 1.0/1.1, and a JSON API with
  configured dot paths (the reader's `:paths`).

  XML is read as it arrives, one item at a time (`Cues.FeedXml`), and each
  item is turned into its fields as it closes, so what a read holds is one
  item and the fields of the items kept, not the feed: at most 32 MiB of XML
  is read, an item may hold at most 4 MiB. Saxy creates no atoms and skips a
  DTD without reading it. Entity references other than XML's five predefined
  ones stay literal (`expand_entity: :keep`), so an internal entity (billion
  laughs) is never expanded and an external one is never read or fetched.
  JSON is held, at most 4 MiB, and decoded whole with string keys, so it
  creates no atoms either. Past any of these limits the reader returns
  `:read_limit`.

  Identity: an item's `guid` (RSS), `id` (Atom) or `id` (JSON Feed). An item
  without one takes `"sha256:"` plus the digest of its link, title and time as
  written, never the link alone, so whoever submits a link first does not own
  it. An id longer than 512 bytes is replaced by its digest.

  An item older than the reader's `:stale_before` (the receipt horizon) is
  skipped: `Cues.Item` would refuse it as stale, and a feed that lists its
  past is not delivering late, so it is neither a cue nor a gap; the read
  counts it as `skipped`. Of the rest, one read keeps at most 100, the newest
  by their time, whatever order the feed lists them in; an undated item ranks
  below every dated one, and ties go to the feed's order. Kept items come back
  in the feed's order; ordering for insert (oldest first) is `Cues.Ingest`'s
  job. The ones left out come back as `{:truncated, …}` with their count and
  time range, for the worker's `page_limit` gap.

  Text fields are plain text with bounded length: HTML is stripped from
  summaries and HTML-typed titles through `Tools.SnippetSanitizer`.
  """

  alias FermixCore.Cues.FeedXml
  alias FermixCore.Cues.JsonPath
  alias FermixCore.Plugins.CanonicalJson
  alias FermixCore.Tools.SnippetSanitizer

  @max_xml_bytes 32 * 1024 * 1024
  @max_json_bytes 4 * 1024 * 1024
  # The blank bytes a body may start with before its first one decides.
  @max_sniff_bytes 65_536
  @bom <<0xEF, 0xBB, 0xBF>>
  @max_items 100
  @max_id_bytes 512
  @max_link_bytes 2_048
  @max_title_chars 300
  @max_summary_chars 2_000
  @max_author_chars 200
  @max_categories 20
  @max_category_chars 100
  @max_scan_chars 65_536
  @max_text_depth 32
  @max_name_chars 64

  @item_type "feed.item"
  @data_content_type "application/json"
  @json_feed_versions ["https://jsonfeed.org/version/1", "https://jsonfeed.org/version/1.1"]
  @path_keys [:items_path, :id_path, :revision_path, :type_path, :subject_path, :time_path]
  @required_path_keys [:items_path, :id_path]

  @comment ~r/<!--.*?-->/s
  @script_or_style ~r/<(script|style)\b[^>]*>.*?<\/\1\s*>/is
  @whitespace ~r/\s+/u
  @space_before_punctuation ~r/\s+([.,;:!?])/u

  @months %{
    "jan" => 1,
    "feb" => 2,
    "mar" => 3,
    "apr" => 4,
    "may" => 5,
    "jun" => 6,
    "jul" => 7,
    "aug" => 8,
    "sep" => 9,
    "oct" => 10,
    "nov" => 11,
    "dec" => 12
  }

  # RFC 822 zone names, in minutes east of UTC. Military single letters are
  # left out on purpose: RFC 1123 notes their signs were specified backwards.
  @zones %{
    "ut" => 0,
    "utc" => 0,
    "gmt" => 0,
    "z" => 0,
    "est" => -300,
    "edt" => -240,
    "cst" => -360,
    "cdt" => -300,
    "mst" => -420,
    "mdt" => -360,
    "pst" => -480,
    "pdt" => -420
  }

  @rfc822 ~r/^(?:[A-Za-z]{3},\s*)?(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4}|\d{2})\s+(\d{2}):(\d{2})(?::(\d{2}))?\s+([A-Za-z]{1,3}|[+-]\d{4})$/

  @type fields :: %{
          item_id: String.t() | nil,
          revision: String.t(),
          type: String.t(),
          subject: String.t() | nil,
          occurred_at: DateTime.t() | nil,
          datacontenttype: String.t(),
          data: term(),
          title: String.t() | nil
        }

  @type truncation ::
          :complete
          | {:truncated,
             %{count: pos_integer(), range_from: DateTime.t() | nil, range_to: DateTime.t() | nil}}

  @typedoc "What a read left out: past the 100 kept, and past the horizon."
  @type outcome :: %{truncation: truncation(), skipped: non_neg_integer()}

  @type paths :: %{
          required(:items_path) => String.t(),
          required(:id_path) => String.t(),
          optional(:revision_path) => String.t(),
          optional(:type_path) => String.t(),
          optional(:subject_path) => String.t(),
          optional(:time_path) => String.t()
        }

  @type error ::
          :read_limit
          | :not_a_feed
          | :content_type_mismatch
          | :invalid_feed
          | :invalid_json
          | :no_items_list
          | {:invalid_xml, String.t()}
          | {:unsupported_feed, String.t()}
          | {:invalid_path, atom()}

  @enforce_keys [:mode, :declared, :options]
  defstruct @enforce_keys ++ [head: <<>>, json: [], xml: nil, size: 0]

  @typedoc """
  A feed being read: `:sniff` until its first byte that is not blank decides
  the syntax, then `:xml` or `:json`; `:json_api` from the start.
  """
  @opaque t :: %__MODULE__{
            mode: :sniff | :xml | :json | :json_api,
            declared: :xml | :json | :unknown,
            options: map(),
            head: binary(),
            json: iodata(),
            xml: FeedXml.t() | nil,
            size: non_neg_integer()
          }

  @doc """
  A reader for a feed whose response has `content_type` (or nil). A JSON or
  XML media type must agree with the body; any other type (`text/html`,
  `text/plain`, none) lets the body's first character decide.

  Options:

    * `:base_url`, the feed's absolute URL, against which relative item links
      are resolved; without it a relative link stays as written.
    * `:stale_before`, a `DateTime`: an item older than it is skipped.
      Without it no item is.
    * `:paths`, for a JSON API whose items sit at `paths.items_path`. Each
      path is a dot path of object keys (a numeric segment indexes a list);
      `"."` is the document itself. Nothing in a path is evaluated. `id_path`
      is required; an item with no scalar at it comes back with `item_id:
      nil`, which `Cues.Item.new/2` refuses as invalid. Missing optional
      values: revision `"1"`, type `"feed.item"`, subject and time nil. The
      body is JSON whatever `content_type` says.
  """
  @spec reader(String.t() | nil, keyword()) :: {:ok, t()} | {:error, error()}
  def reader(content_type, opts \\ [])
      when (is_binary(content_type) or is_nil(content_type)) and is_list(opts) do
    opts = Keyword.validate!(opts, base_url: nil, stale_before: nil, paths: nil)
    stale_before = Keyword.fetch!(opts, :stale_before)
    true = is_nil(stale_before) or is_struct(stale_before, DateTime)

    options = %{
      base_url: opts |> Keyword.fetch!(:base_url) |> base_url!(),
      stale_before: stale_before,
      paths: Keyword.fetch!(opts, :paths)
    }

    case options.paths do
      nil -> {:ok, new_reader(:sniff, content_type, options)}
      paths -> with :ok <- validate_paths(paths), do: {:ok, new_reader(:json_api, nil, options)}
    end
  end

  @doc "Reads the next piece of the body, any size."
  @spec read(t(), binary()) :: {:ok, t()} | {:error, error()}
  def read(%__MODULE__{} = reader, chunk) when is_binary(chunk),
    do: consume(%{reader | size: reader.size + byte_size(chunk)}, chunk)

  @doc "Ends the body: the kept items' fields and what was left out."
  @spec finish(t()) :: {:ok, [fields()], outcome()} | {:error, error()}
  def finish(%__MODULE__{mode: :sniff}), do: {:error, :not_a_feed}

  def finish(%__MODULE__{mode: :xml} = reader) do
    case FeedXml.finish(reader.xml) do
      {:ok, document} -> xml_items(document)
      {:error, reason} -> {:error, xml_error(reason)}
    end
  end

  def finish(%__MODULE__{mode: :json} = reader) do
    with {:ok, document} <- decode_json(IO.iodata_to_binary(reader.json)),
         {:ok, format, entries, context} <- json_feed(document) do
      context = Map.put(context, :base_url, reader.options.base_url)

      entries
      |> Enum.reduce(keeper(reader.options), &keep_feed_item(&1, format, context, &2))
      |> kept()
    end
  end

  def finish(%__MODULE__{mode: :json_api} = reader) do
    paths = reader.options.paths

    with {:ok, document} <- decode_json(strip_bom(IO.iodata_to_binary(reader.json))),
         {:ok, entries} <- items_at(document, paths.items_path) do
      entries |> Enum.reduce(keeper(reader.options), &keep_api_item(&1, paths, &2)) |> kept()
    end
  end

  @doc "Reads a whole RSS, Atom or JSON Feed body (`reader/2`'s options but `:paths`)."
  @spec parse(binary(), String.t() | nil, keyword()) ::
          {:ok, [fields()], outcome()} | {:error, error()}
  def parse(body, content_type, opts \\ [])
      when is_binary(body) and (is_binary(content_type) or is_nil(content_type)) and is_list(opts) do
    true = not Keyword.has_key?(opts, :paths)
    read_whole(body, content_type, opts)
  end

  @doc "Reads a whole JSON API body whose items sit at `paths.items_path` (see `reader/2`)."
  @spec parse_json_api(binary(), paths(), keyword()) ::
          {:ok, [fields()], outcome()} | {:error, error()}
  def parse_json_api(body, paths, opts \\ [])
      when is_binary(body) and is_map(paths) and is_list(opts) do
    opts = Keyword.validate!(opts, [:stale_before])
    read_whole(body, nil, [{:paths, paths} | opts])
  end

  defp read_whole(body, content_type, opts) do
    with {:ok, reader} <- reader(content_type, opts),
         {:ok, reader} <- read(reader, body),
         do: finish(reader)
  end

  @doc """
  Checks a JSON API path map: `items_path` and `id_path` present, only the six
  known keys, each a path `Cues.JsonPath.valid?/1` accepts.
  """
  @spec validate_paths(map()) :: :ok | {:error, {:invalid_path, atom()}}
  def validate_paths(paths) when is_map(paths) do
    missing = Enum.find(@required_path_keys, &(not Map.has_key?(paths, &1)))

    invalid =
      Enum.find(paths, fn {key, path} -> key not in @path_keys or not JsonPath.valid?(path) end)

    cond do
      missing -> {:error, {:invalid_path, missing}}
      invalid -> {:error, {:invalid_path, elem(invalid, 0)}}
      true -> :ok
    end
  end

  # --- reading ----------------------------------------------------------------

  defp new_reader(mode, content_type, options),
    do: %__MODULE__{mode: mode, declared: declared_syntax(content_type), options: options}

  # The first chunk is the head as it is, so a whole body is not copied.
  defp consume(%{mode: :sniff, head: <<>>} = reader, chunk), do: sniff(%{reader | head: chunk})
  defp consume(%{mode: :sniff} = reader, chunk), do: sniff(%{reader | head: reader.head <> chunk})

  defp consume(%{mode: :xml} = reader, chunk) do
    with :ok <- within(reader, @max_xml_bytes) do
      case FeedXml.read(reader.xml, chunk) do
        {:ok, xml} -> {:ok, %{reader | xml: xml}}
        {:error, reason} -> {:error, xml_error(reason)}
      end
    end
  end

  defp consume(%{mode: mode} = reader, chunk) when mode in [:json, :json_api] do
    with :ok <- within(reader, @max_json_bytes), do: {:ok, %{reader | json: [reader.json, chunk]}}
  end

  defp within(%{size: size}, max) when size > max, do: {:error, :read_limit}
  defp within(_reader, _max), do: :ok

  # The body's start is held until its first byte that is not blank, past a
  # byte-order mark, decides the syntax; then all of it goes on.
  defp sniff(%{head: head} = reader) do
    case sniffed_syntax(head) do
      :more ->
        {:ok, reader}

      sniffed ->
        with {:ok, syntax} <- decide_syntax(reader.declared, sniffed), do: start(syntax, reader)
    end
  end

  defp start(:xml, reader) do
    base_url = reader.options.base_url
    on_item = fn item, format, keeper -> keep_item(item, format, base_url, keeper) end
    xml = FeedXml.new(on_item, keeper(reader.options))
    consume(%{reader | mode: :xml, xml: xml, head: <<>>}, strip_bom(reader.head))
  end

  defp start(:json, reader),
    do: consume(%{reader | mode: :json, head: <<>>}, strip_bom(reader.head))

  defp keep_feed_item(entry, format, context, keeper) do
    time = entry |> raw_time(format, context) |> parse_time()
    keep(keeper, time, fn -> feed_fields(entry, format, context) end)
  end

  defp keep_api_item(entry, paths, keeper) do
    time = JsonPath.time(entry, paths[:time_path])
    keep(keeper, time, fn -> JsonPath.fields(entry, paths, @item_type) end)
  end

  # An item's fields are made as it closes, before Atom's feed-level author
  # may have been read; `xml_items/1` fills that in at the end.
  defp keep_item(item, format, base_url, keeper) do
    {format, context} = xml_format(format)
    context = Map.merge(context, %{author: nil, base_url: base_url})
    time = item |> raw_time(format, context) |> parse_time()
    keep(keeper, time, fn -> feed_fields(item, format, context) end)
  end

  defp xml_items(%{format: format, root: {_name, _attrs, children}, acc: keeper}) do
    {:ok, items, outcome} = kept(keeper)
    {:ok, Enum.map(items, &with_feed_author(&1, format, children)), outcome}
  end

  defp xml_format(:rss), do: {:rss, %{}}
  defp xml_format({:atom, prefix}), do: {:atom, %{prefix: prefix}}

  defp with_feed_author(%{data: %{"author" => nil}} = fields, {:atom, prefix}, children) do
    author = children |> atom_author(prefix) |> plain_text(@max_author_chars)
    %{fields | data: %{fields.data | "author" => author}}
  end

  defp with_feed_author(fields, _format, _children), do: fields

  defp xml_error({:invalid_xml, %Saxy.ParseError{} = error}),
    do: {:invalid_xml, bounded_name(Exception.message(error))}

  defp xml_error({:unsupported_feed, name}), do: {:unsupported_feed, bounded_name(name)}
  defp xml_error(reason) when reason in [:invalid_feed, :read_limit], do: reason

  # --- detection ------------------------------------------------------------

  # A UTF-8 byte-order mark; Saxy refuses a document that starts with one.
  defp strip_bom(@bom <> body), do: body
  defp strip_bom(body), do: body

  defp decide_syntax(_declared, :unknown), do: {:error, :not_a_feed}
  defp decide_syntax(:unknown, sniffed), do: {:ok, sniffed}
  defp decide_syntax(same, same), do: {:ok, same}
  defp decide_syntax(_declared, _sniffed), do: {:error, :content_type_mismatch}

  defp declared_syntax(nil), do: :unknown

  defp declared_syntax(content_type) do
    media =
      content_type |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase()

    cond do
      media in ["application/json", "application/feed+json"] -> :json
      media in ["application/xml", "text/xml"] -> :xml
      String.ends_with?(media, "+json") -> :json
      String.ends_with?(media, "+xml") -> :xml
      true -> :unknown
    end
  end

  # `:more` while the start is blank, or could still be a byte-order mark.
  defp sniffed_syntax(head) when byte_size(head) < byte_size(@bom) do
    if head == binary_part(@bom, 0, byte_size(head)), do: :more, else: sniffed_text(head)
  end

  defp sniffed_syntax(head), do: head |> strip_bom() |> sniffed_text()

  # A blank start past 64 KiB is no feed, however the body was split.
  defp sniffed_text(text) do
    rest = String.trim_leading(text)

    cond do
      byte_size(text) - byte_size(rest) > @max_sniff_bytes -> :unknown
      rest == "" or incomplete_character?(rest) -> :more
      String.starts_with?(rest, "<") -> :xml
      String.starts_with?(rest, "{") -> :json
      true -> :unknown
    end
  end

  # A chunk can end inside a character, blank or not; the next one completes it.
  defp incomplete_character?(text) when byte_size(text) < 4,
    do: match?({:incomplete, "", _rest}, :unicode.characters_to_binary(text))

  defp incomplete_character?(_text), do: false

  defp decode_json(body) do
    case Jason.decode(body) do
      {:ok, document} -> {:ok, document}
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_json}
    end
  end

  defp json_feed(%{"version" => version, "items" => items} = feed)
       when version in @json_feed_versions and is_list(items) do
    if Enum.all?(items, &is_map/1),
      do: {:ok, :json_feed, items, %{author: json_author(feed)}},
      else: {:error, :invalid_feed}
  end

  defp json_feed(%{"version" => version})
       when is_binary(version) and version not in @json_feed_versions,
       do: {:error, {:unsupported_feed, bounded_name(version)}}

  defp json_feed(_document), do: {:error, :invalid_feed}

  # --- per-format fields ----------------------------------------------------

  defp feed_fields(entry, format, context) do
    raw = raw_fields(entry, format, context)
    time = raw_time(entry, format, context)
    title = raw.title
    link = link(raw.link, context.base_url)

    %{
      item_id: item_id(raw.id, raw.link, raw.title_source, raw_time_text(time)),
      revision: "1",
      type: @item_type,
      subject: nil,
      occurred_at: parse_time(time),
      datacontenttype: @data_content_type,
      data: %{
        "title" => title,
        "link" => link,
        "summary" => raw.summary,
        "author" => raw.author,
        "categories" => raw.categories
      },
      title: title
    }
  end

  defp raw_fields({_name, _attrs, children}, :rss, _context) do
    title_source = text(children, "title")

    %{
      id: text(children, "guid"),
      link: text(children, "link"),
      title_source: title_source,
      title: html_text(title_source, @max_title_chars),
      summary:
        html_text(first_text(children, ["description", "content:encoded"]), @max_summary_chars),
      author: html_text(first_text(children, ["dc:creator", "author"]), @max_author_chars),
      categories: children |> elements("category") |> Enum.map(&element_text/1) |> categories()
    }
  end

  defp raw_fields({_name, _attrs, children}, :atom, context) do
    prefix = context.prefix
    title = element(children, prefix <> "title")

    %{
      id: text(children, prefix <> "id"),
      link: atom_link(children, prefix),
      title_source: title && element_text(title),
      title: atom_text(title, @max_title_chars),
      summary:
        atom_text(
          first_element(children, [prefix <> "summary", prefix <> "content"]),
          @max_summary_chars
        ),
      author: plain_text(atom_author(children, prefix) || context.author, @max_author_chars),
      categories:
        children
        |> elements(prefix <> "category")
        |> Enum.map(&attribute(&1, "term"))
        |> categories()
    }
  end

  defp raw_fields(item, :json_feed, context) do
    title_source = string_at(item, "title")

    %{
      id: json_id(item["id"]),
      link: string_at(item, "url"),
      title_source: title_source,
      title: plain_text(title_source, @max_title_chars),
      summary: json_summary(item),
      author: plain_text(json_author(item) || context.author, @max_author_chars),
      categories: item |> Map.get("tags") |> List.wrap() |> categories()
    }
  end

  # The time as written, tagged with the grammar it must follow.
  defp raw_time({_name, _attrs, children}, :rss, _context) do
    case text(children, "pubDate") do
      nil -> tagged(:rfc3339, text(children, "dc:date"))
      pub_date -> {:rfc822, pub_date}
    end
  end

  defp raw_time({_name, _attrs, children}, :atom, %{prefix: prefix}),
    do: tagged(:rfc3339, first_text(children, [prefix <> "published", prefix <> "updated"]))

  defp raw_time(item, :json_feed, _context),
    do: tagged(:rfc3339, string_at(item, "date_published") || string_at(item, "date_modified"))

  defp tagged(_grammar, nil), do: nil
  defp tagged(grammar, text), do: {grammar, text}

  defp raw_time_text(nil), do: nil
  defp raw_time_text({_grammar, text}), do: text

  defp atom_link(children, prefix) do
    children
    |> elements(prefix <> "link")
    |> Enum.find(&(attribute(&1, "rel") in [nil, "alternate"]))
    |> then(&(&1 && attribute(&1, "href")))
  end

  defp atom_author(children, prefix) do
    case element(children, prefix <> "author") do
      {_name, _attrs, author} -> text(author, prefix <> "name")
      nil -> nil
    end
  end

  # Atom text constructs: `text` is plain already; `html` and `xhtml` are markup.
  defp atom_text(nil, _max), do: nil

  defp atom_text(element, max) do
    case attribute(element, "type") do
      type when type in ["html", "xhtml"] -> html_text(element_text(element), max)
      _text -> plain_text(element_text(element), max)
    end
  end

  defp json_id(id) when is_binary(id), do: id
  defp json_id(id) when is_integer(id), do: Integer.to_string(id)
  defp json_id(_id), do: nil

  defp json_summary(item) do
    case {string_at(item, "summary"), string_at(item, "content_text")} do
      {nil, nil} -> html_text(string_at(item, "content_html"), @max_summary_chars)
      {nil, content_text} -> plain_text(content_text, @max_summary_chars)
      {summary, _content_text} -> plain_text(summary, @max_summary_chars)
    end
  end

  defp json_author(%{"authors" => [%{"name" => name} | _rest]}) when is_binary(name), do: name
  defp json_author(%{"author" => %{"name" => name}}) when is_binary(name), do: name
  defp json_author(_object), do: nil

  # --- JSON API -------------------------------------------------------------

  defp items_at(document, path) do
    case JsonPath.lookup(document, path) do
      {:ok, items} when is_list(items) -> {:ok, items}
      _other -> {:error, :no_items_list}
    end
  end

  # --- identity, links, truncation -------------------------------------------

  defp item_id(raw_id, raw_link, raw_title, raw_time) do
    case trimmed(raw_id) do
      nil -> digest_id([trimmed(raw_link), trimmed(raw_title), trimmed(raw_time)])
      id -> bounded_id(id)
    end
  end

  defp bounded_id(nil), do: nil
  defp bounded_id(id) when byte_size(id) > @max_id_bytes, do: digest_id([id])
  defp bounded_id(id), do: id

  defp digest_id(parts) do
    {:ok, digest} = CanonicalJson.digest(parts)
    "sha256:" <> digest
  end

  defp link(nil, _base_url), do: nil

  defp link(raw, base_url) do
    case trimmed(raw) do
      nil -> nil
      href when byte_size(href) > @max_link_bytes -> nil
      href when is_binary(base_url) -> base_url |> URI.merge(href) |> URI.to_string()
      href -> href
    end
  end

  defp base_url!(nil), do: nil

  defp base_url!(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        url

      _other ->
        raise ArgumentError,
              "base_url must be an absolute http or https URL, got: #{inspect(url)}"
    end
  end

  # --- the newest 100 ----------------------------------------------------------

  defp keeper(options) do
    %{
      kept: :gb_trees.empty(),
      next: 0,
      stale_before: options.stale_before,
      skipped: 0,
      dropped: %{count: 0, from: nil, to: nil}
    }
  end

  # An entry older than `stale_before` is skipped and only counted: Ingest
  # would refuse it as stale, and a feed listing its past is no late arrival
  # and no gap. `to_fields` runs only for an entry that goes in.
  defp keep(keeper, time, to_fields) do
    if past?(keeper, time),
      do: %{keeper | skipped: keeper.skipped + 1},
      else: rank_in(keeper, time, to_fields)
  end

  defp past?(%{stale_before: %DateTime{} = cutoff}, %DateTime{} = time),
    do: DateTime.compare(time, cutoff) == :lt

  defp past?(_keeper, _time), do: false

  # Ranked by time, newest highest; an undated entry ranks below every dated
  # one, and of two equal ranks the earlier in the feed is higher.
  defp rank_in(keeper, time, to_fields) do
    index = keeper.next
    rank = if time, do: {1, DateTime.to_unix(time, :microsecond), -index}, else: {0, 0, -index}
    keeper = %{keeper | next: index + 1}

    cond do
      :gb_trees.size(keeper.kept) < @max_items ->
        %{keeper | kept: :gb_trees.insert(rank, {index, to_fields.(), time}, keeper.kept)}

      rank > elem(:gb_trees.smallest(keeper.kept), 0) ->
        {_rank, {_index, _fields, out_time}, kept} = :gb_trees.take_smallest(keeper.kept)
        kept = :gb_trees.insert(rank, {index, to_fields.(), time}, kept)
        dropped(%{keeper | kept: kept}, out_time)

      true ->
        dropped(keeper, time)
    end
  end

  defp dropped(%{dropped: dropped} = keeper, time) do
    %{
      keeper
      | dropped: %{
          count: dropped.count + 1,
          from: earliest(dropped.from, time),
          to: latest(dropped.to, time)
        }
    }
  end

  defp earliest(nil, time), do: time
  defp earliest(from, nil), do: from
  defp earliest(from, time), do: Enum.min([from, time], DateTime)

  defp latest(nil, time), do: time
  defp latest(to, nil), do: to
  defp latest(to, time), do: Enum.max([to, time], DateTime)

  # The kept fields in the feed's order, and what was left out.
  defp kept(keeper) do
    items =
      keeper.kept
      |> :gb_trees.values()
      |> Enum.sort_by(fn {index, _fields, _time} -> index end)
      |> Enum.map(fn {_index, fields, _time} -> fields end)

    {:ok, items, %{truncation: truncation(keeper.dropped), skipped: keeper.skipped}}
  end

  defp truncation(%{count: 0}), do: :complete

  defp truncation(%{count: count, from: from, to: to}),
    do: {:truncated, %{count: count, range_from: from, range_to: to}}

  # --- XML helpers ------------------------------------------------------------

  defp element(children, name), do: Enum.find(children, &match?({^name, _attrs, _children}, &1))

  defp elements(children, name),
    do: Enum.filter(children, &match?({^name, _attrs, _children}, &1))

  defp first_element(children, names), do: Enum.find_value(names, &element(children, &1))

  defp text(children, name) do
    case element(children, name) do
      nil -> nil
      found -> found |> element_text() |> trimmed()
    end
  end

  defp first_text(children, names), do: Enum.find_value(names, &text(children, &1))

  defp attribute({_name, attrs, _children}, key) do
    Enum.find_value(attrs, fn
      {^key, value} -> value
      _other -> nil
    end)
  end

  # The text of an element and its descendants (Atom `xhtml` content nests
  # markup), a space between nested elements, at most 32 levels deep.
  defp element_text({_name, _attrs, children}),
    do: children |> text_nodes(0) |> IO.iodata_to_binary()

  defp text_nodes(_children, depth) when depth > @max_text_depth, do: []

  defp text_nodes(children, depth) do
    Enum.map(children, fn
      text when is_binary(text) -> text
      {_name, _attrs, nested} -> [" ", text_nodes(nested, depth + 1), " "]
      _other -> []
    end)
  end

  # --- text -------------------------------------------------------------------

  defp html_text(nil, _max), do: nil

  defp html_text(html, max) do
    html
    |> String.slice(0, @max_scan_chars)
    |> String.replace(@comment, " ")
    |> String.replace(@script_or_style, " ")
    |> SnippetSanitizer.sanitize()
    |> plain_text(max)
  end

  defp plain_text(nil, _max), do: nil

  defp plain_text(text, max) do
    text
    |> String.slice(0, @max_scan_chars)
    |> String.replace(@whitespace, " ")
    |> String.replace(@space_before_punctuation, "\\1")
    |> String.trim()
    |> String.slice(0, max)
    |> blank_to_nil()
  end

  defp categories(values) do
    values
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&plain_text(&1, @max_category_chars))
    |> Enum.reject(&is_nil/1)
    |> Enum.take(@max_categories)
  end

  defp string_at(object, key) do
    case Map.get(object, key) do
      value when is_binary(value) -> trimmed(value)
      _other -> nil
    end
  end

  defp trimmed(nil), do: nil
  defp trimmed(text), do: text |> String.trim() |> blank_to_nil()

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(text), do: text

  defp bounded_name(text), do: String.slice(text, 0, @max_name_chars)

  # --- time -------------------------------------------------------------------

  defp parse_time(nil), do: nil
  defp parse_time({:rfc3339, text}), do: rfc3339(String.trim(text))
  defp parse_time({:rfc822, text}), do: rfc822(String.trim(text))

  defp rfc3339(text) do
    case DateTime.from_iso8601(text) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp rfc822(text) do
    with [_all, day, month, year, hour, minute, second, zone] <- Regex.run(@rfc822, text),
         {:ok, month} <- Map.fetch(@months, String.downcase(month)),
         {:ok, offset} <- zone_offset(zone),
         {:ok, naive} <- naive(year, month, day, hour, minute, second) do
      naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.add(-offset * 60, :second)
    else
      _unparseable -> nil
    end
  end

  defp naive(year, month, day, hour, minute, second) do
    NaiveDateTime.new(
      full_year(String.to_integer(year)),
      month,
      String.to_integer(day),
      String.to_integer(hour),
      String.to_integer(minute),
      if(second == "", do: 0, else: String.to_integer(second))
    )
  end

  # RFC 822 allowed two-digit years; read 00-49 as 20xx and 50-99 as 19xx.
  defp full_year(year) when year < 50, do: 2000 + year
  defp full_year(year) when year < 100, do: 1900 + year
  defp full_year(year), do: year

  defp zone_offset(<<sign, hours::binary-size(2), minutes::binary-size(2)>>)
       when sign in [?+, ?-] do
    {hours, minutes} = {String.to_integer(hours), String.to_integer(minutes)}

    if hours <= 23 and minutes <= 59,
      do: {:ok, if(sign == ?+, do: 1, else: -1) * (hours * 60 + minutes)},
      else: :error
  end

  defp zone_offset(name), do: Map.fetch(@zones, String.downcase(name))
end
