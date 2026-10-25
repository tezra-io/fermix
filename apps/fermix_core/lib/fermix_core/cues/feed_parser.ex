defmodule FermixCore.Cues.FeedParser do
  @moduledoc """
  Turns a feed response into cue item fields (M60 §6.4, §6.8, §6.9).

  Pure: no I/O, no clock, no process. The feed worker fetches the body and
  hands each result to `Cues.Item.new/2`.

  Formats: RSS 2.0, Atom 1.0 and JSON Feed 1.0/1.1 through `parse/3`, and a JSON
  API with configured dot paths through `parse_json_api/3`.

  XML goes through Saxy, which creates no atoms and skips a DTD without reading
  it. Entity references other than XML's five predefined ones stay literal
  (`expand_entity: :keep`), so an internal entity (billion laughs) is never
  expanded and an external one is never read or fetched. JSON is decoded with
  string keys, so it creates no atoms either.

  Identity: an item's `guid` (RSS), `id` (Atom) or `id` (JSON Feed). An item
  without one takes `"sha256:"` plus the digest of its link, title and time as
  written, never the link alone, so whoever submits a link first does not own
  it. An id longer than 512 bytes is replaced by its digest.

  One parse keeps at most 100 items, the first ones in the feed's order
  (feeds list newest first); the rest comes back as `{:truncated, …}` with its
  count and time range, for the worker's `page_limit` gap. Ordering for insert
  (oldest first) is `Cues.Ingest`'s job, not this module's.

  Text fields are plain text with bounded length: HTML is stripped from
  summaries and HTML-typed titles through `Tools.SnippetSanitizer`.
  """

  alias FermixCore.Cues.JsonPath
  alias FermixCore.Plugins.CanonicalJson
  alias FermixCore.Tools.SnippetSanitizer

  @max_body_bytes 4 * 1024 * 1024
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

  @type paths :: %{
          required(:items_path) => String.t(),
          required(:id_path) => String.t(),
          optional(:revision_path) => String.t(),
          optional(:type_path) => String.t(),
          optional(:subject_path) => String.t(),
          optional(:time_path) => String.t()
        }

  @type error ::
          :body_too_large
          | :not_a_feed
          | :content_type_mismatch
          | :invalid_feed
          | :invalid_json
          | :no_items_list
          | {:invalid_xml, String.t()}
          | {:unsupported_feed, String.t()}
          | {:invalid_path, atom()}

  @doc """
  Parses an RSS, Atom or JSON Feed body.

  `content_type` is the response's `Content-Type` (or nil). A JSON or XML media
  type must agree with the body; any other type (`text/html`, `text/plain`,
  none) lets the body's first character decide.

  Options: `:base_url`, the feed's absolute URL, against which relative item
  links are resolved; without it a relative link stays as written.
  """
  @spec parse(binary(), String.t() | nil, keyword()) ::
          {:ok, [fields()], truncation()} | {:error, error()}
  def parse(body, content_type, opts \\ [])
      when is_binary(body) and (is_binary(content_type) or is_nil(content_type)) and is_list(opts) do
    base_url =
      opts |> Keyword.validate!(base_url: nil) |> Keyword.fetch!(:base_url) |> base_url!()

    with :ok <- check_size(body),
         body = strip_bom(body),
         {:ok, syntax} <- syntax(content_type, body),
         {:ok, format, entries, context} <- decode_feed(syntax, body) do
      context = Map.put(context, :base_url, base_url)
      {kept, rest} = Enum.split(entries, @max_items)
      times = Enum.map(rest, &(&1 |> raw_time(format, context) |> parse_time()))
      {:ok, Enum.map(kept, &feed_fields(&1, format, context)), truncation(times)}
    end
  end

  @doc """
  Parses a JSON API body whose items sit at `paths.items_path`.

  Each path is a dot path of object keys (a numeric segment indexes a list);
  `"."` is the document itself. Nothing in a path is evaluated. `id_path` is
  required; an item with no scalar at it comes back with `item_id: nil`, which
  `Cues.Item.new/2` refuses as invalid. Missing optional values: revision
  `"1"`, type `"feed.item"`, subject and time nil.
  """
  @spec parse_json_api(binary(), paths(), keyword()) ::
          {:ok, [fields()], truncation()} | {:error, error()}
  def parse_json_api(body, paths, opts \\ [])
      when is_binary(body) and is_map(paths) and is_list(opts) do
    Keyword.validate!(opts, [])

    with :ok <- check_size(body),
         :ok <- validate_paths(paths),
         {:ok, document} <- decode_json(strip_bom(body)),
         {:ok, entries} <- items_at(document, paths.items_path) do
      {kept, rest} = Enum.split(entries, @max_items)
      times = Enum.map(rest, &JsonPath.time(&1, paths[:time_path]))
      {:ok, Enum.map(kept, &JsonPath.fields(&1, paths, @item_type)), truncation(times)}
    end
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

  # --- detection ------------------------------------------------------------

  defp check_size(body) when byte_size(body) > @max_body_bytes, do: {:error, :body_too_large}
  defp check_size(_body), do: :ok

  # A UTF-8 byte-order mark; Saxy refuses a document that starts with one.
  defp strip_bom(<<0xEF, 0xBB, 0xBF, body::binary>>), do: body
  defp strip_bom(body), do: body

  defp syntax(content_type, body),
    do: decide_syntax(declared_syntax(content_type), sniffed_syntax(body))

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

  defp sniffed_syntax(body) do
    case String.trim_leading(body) do
      "<" <> _rest -> :xml
      "{" <> _rest -> :json
      _other -> :unknown
    end
  end

  defp decode_feed(:xml, body) do
    case Saxy.SimpleForm.parse_string(body, expand_entity: :keep) do
      {:ok, root} ->
        xml_feed(root)

      {:error, %Saxy.ParseError{} = error} ->
        {:error, {:invalid_xml, bounded_name(Exception.message(error))}}
    end
  end

  defp decode_feed(:json, body) do
    with {:ok, document} <- decode_json(body), do: json_feed(document)
  end

  defp decode_json(body) do
    case Jason.decode(body) do
      {:ok, document} -> {:ok, document}
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_json}
    end
  end

  defp xml_feed({"rss", _attrs, children}) do
    case element(children, "channel") do
      {_name, _attrs, channel} -> {:ok, :rss, elements(channel, "item"), %{}}
      nil -> {:error, :invalid_feed}
    end
  end

  defp xml_feed({name, _attrs, children}) do
    case atom_prefix(name) do
      {:ok, prefix} ->
        context = %{prefix: prefix, author: atom_author(children, prefix)}
        {:ok, :atom, elements(children, prefix <> "entry"), context}

      :error ->
        {:error, {:unsupported_feed, bounded_name(name)}}
    end
  end

  # An Atom document may bind its namespace to a prefix (`<a:feed>`); every
  # Atom element then carries that prefix.
  defp atom_prefix("feed"), do: {:ok, ""}

  defp atom_prefix(name) do
    case String.split(name, ":", parts: 2) do
      [prefix, "feed"] -> {:ok, prefix <> ":"}
      _other -> :error
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

  defp truncation([]), do: :complete

  defp truncation(times) do
    known = Enum.reject(times, &is_nil/1)
    {:truncated, %{count: length(times), range_from: min_time(known), range_to: max_time(known)}}
  end

  defp min_time([]), do: nil
  defp min_time(times), do: Enum.min(times, DateTime)

  defp max_time([]), do: nil
  defp max_time(times), do: Enum.max(times, DateTime)

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
