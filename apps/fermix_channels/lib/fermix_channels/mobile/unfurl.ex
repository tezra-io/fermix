defmodule FermixChannels.Mobile.Unfurl do
  @moduledoc """
  SSRF-safe host-side link-preview resolution for the links a timeline row
  names, which `FermixChannels.LinkPreviews` chooses.

  No client ever fetches page, thumbnail or icon URLs. Every target and
  redirect is resolved, checked by `FermixCore.Net.Guard` and pinned to the
  checked address (`FermixCore.Net.PinnedUrl`); Host and TLS SNI retain the
  original hostname. Resolution is bounded to four links, as many as a row
  keeps, five redirects, and a one-MiB body per response. A preview keeps the
  link it was read for (`link`) beside the address its page answered from
  after redirects (`url`), so a client pairs it with the link as written.

  A preview also carries the site's icon (`icon`), read from the head the
  page already gave (Links in the sentence, note 01): a PNG `rel="icon"`
  nearest 64 px, else `apple-touch-icon`, else another icon that is not SVG,
  and `/favicon.ico` at the page's final origin when that fails or none is
  declared, so at most two icon fetches a site. An icon is at most 64 KiB,
  cut as it streams, of a type the phones decode (PNG, GIF, JPEG, WebP, ICO),
  its first bytes saying so; SVG is refused by type and by href, since
  rasterising an untrusted SVG is a parser the daemon does not have. Links on
  one origin share one icon fetch. A refused or missing icon is a warning,
  and the preview goes out without one.

  Each preview is handed to `:on_preview` as it resolves, so a caller can
  publish it before a slower link's page answers.
  """

  alias FermixCore.Net.Egress
  alias FermixCore.Net.PinnedUrl
  alias FermixCore.Net.TimeoutPolicy

  @max_links 4
  @max_redirects 5
  @max_body_bytes 1_048_576
  @max_icon_bytes 65_536
  @icon_size_px 64
  @icon_types ~w(image/png image/gif image/jpeg image/webp image/x-icon image/vnd.microsoft.icon)
  # Each injected seam and the arity it must have.
  @option_arities [
    resolver: {1, :invalid_resolver},
    request: {2, :invalid_request},
    store_thumbnail: {2, :invalid_thumbnail_store},
    on_preview: {1, :invalid_on_preview}
  ]

  @typedoc "A stored thumbnail or icon: its content ref, image type and size."
  @type image :: %{ref: String.t(), mime: String.t(), size_bytes: non_neg_integer()}

  @type preview :: %{
          required(:link) => String.t(),
          required(:url) => String.t(),
          required(:site) => String.t(),
          required(:title) => String.t(),
          required(:description) => String.t() | nil,
          required(:image) => image() | nil,
          required(:icon) => image() | nil
        }

  @spec resolve([String.t()], keyword()) ::
          {:ok, [preview()], [{String.t(), term()}]} | {:error, term()}
  def resolve(links, opts \\ []) when is_list(links) and is_list(opts) do
    with :ok <- validate_options(opts) do
      links
      |> Enum.uniq()
      |> Enum.take(@max_links)
      |> Enum.reduce({[], [], %{}}, &resolve_link(&1, &2, opts))
      |> then(fn {previews, warnings, _icons} ->
        {:ok, Enum.reverse(previews), Enum.reverse(warnings)}
      end)
    end
  end

  # The accumulator: previews and warnings newest first, and each origin's
  # icon once it was looked for, shared by every later link on it.
  defp resolve_link(url, {previews, warnings, icons}, opts) do
    case fetch_page(url, opts, 0) do
      {:ok, final_url, response} ->
        resolve_page(url, final_url, response, {previews, warnings, icons}, opts)

      {:error, reason} ->
        {previews, [{url, reason} | warnings], icons}
    end
  end

  defp resolve_page(link, url, response, {previews, warnings, icons}, opts) do
    with {:ok, document} <- parse_page(response),
         {:ok, title} <- preview_title(document),
         {:ok, image, image_warnings} <- preview_image(document, url, opts),
         {:ok, icon, icon_warnings, icons} <- preview_icon(document, url, icons, opts) do
      preview = build_preview(link, url, document, title, image, icon)
      notify(preview, opts)
      {[preview | previews], Enum.reverse(image_warnings ++ icon_warnings, warnings), icons}
    else
      {:error, reason} -> {previews, [{link, reason} | warnings], icons}
    end
  end

  defp fetch_page(_url, _opts, redirects) when redirects > @max_redirects,
    do: {:error, :redirect_limit}

  defp fetch_page(url, opts, redirects) do
    with {:ok, pinned} <- pin(url, opts),
         {:ok, response} <- request(pinned, opts, @max_body_bytes),
         :ok <- body_cap(response, @max_body_bytes) do
      handle_page_response(url, response, opts, redirects)
    end
  end

  defp handle_page_response(url, %{status: status} = response, _opts, _redirects)
       when status in 200..299 do
    {:ok, url, response}
  end

  defp handle_page_response(url, %{status: status} = response, opts, redirects)
       when status in 300..399 do
    with {:ok, location} <- redirect_location(response),
         target <- url |> URI.merge(location) |> URI.to_string() do
      fetch_page(target, opts, redirects + 1)
    end
  end

  defp handle_page_response(_url, %{status: status}, _opts, _redirects),
    do: {:error, {:http_status, status}}

  defp parse_page(%{body: body}) when is_binary(body), do: Floki.parse_document(valid_utf8(body))
  defp parse_page(_response), do: {:error, :invalid_body}

  defp build_preview(link, url, document, title, image, icon) do
    %{
      link: link,
      url: url,
      site: meta(document, "og:site_name") || URI.parse(url).host || "",
      title: title,
      description: meta(document, "og:description"),
      image: image,
      icon: icon
    }
  end

  defp notify(preview, opts) do
    case Keyword.get(opts, :on_preview) do
      nil -> :ok
      on_preview -> on_preview.(preview)
    end
  end

  defp preview_title(document) do
    value = meta(document, "og:title") || document |> Floki.find("title") |> Floki.text()

    case clean(value) do
      nil -> {:error, :missing_title}
      title -> {:ok, title}
    end
  end

  defp preview_image(document, page_url, opts) do
    case meta(document, "og:image") do
      nil -> {:ok, nil, []}
      image -> fetch_thumbnail(page_url, image, opts)
    end
  end

  defp fetch_thumbnail(page_url, image, opts) do
    url = page_url |> URI.merge(image) |> URI.to_string()

    case fetch_resource(url, opts, 0, @max_body_bytes) do
      {:ok, response} -> store_thumbnail(url, response, opts)
      {:error, reason} -> {:ok, nil, [{url, reason}]}
    end
  end

  # Links on one origin share one icon: the first looks for it, the rest reuse
  # what it found, or that it found nothing.
  defp preview_icon(document, page_url, icons, opts) do
    origin = origin(page_url)

    case Map.fetch(icons, origin) do
      {:ok, icon} ->
        {:ok, icon, [], icons}

      :error ->
        {icon, warnings} = fetch_icon(document, page_url, opts)
        {:ok, icon, warnings, Map.put(icons, origin, icon)}
    end
  end

  defp origin(url) do
    uri = URI.parse(url)
    {uri.scheme, uri.host, uri.port}
  end

  # At most two fetches a site: the best icon the head declares, then
  # `/favicon.ico` at the page's origin when that fails or none is declared.
  defp fetch_icon(document, page_url, opts) do
    favicon = page_url |> URI.merge("/favicon.ico") |> URI.to_string()

    [declared_icon(document, page_url), favicon]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> try_icons(opts, [])
  end

  defp try_icons([], _opts, warnings), do: {nil, Enum.reverse(warnings)}

  defp try_icons([url | rest], opts, warnings) do
    case fetch_icon_url(url, opts) do
      {:ok, icon} -> {icon, Enum.reverse(warnings)}
      {:error, reason} -> try_icons(rest, opts, [{url, reason} | warnings])
    end
  end

  # The head's best icon, absolute: a PNG `icon` nearest 64 px, then
  # `apple-touch-icon`, then any other icon that is not SVG.
  defp declared_icon(document, page_url) do
    document
    |> Floki.find("link[rel][href]")
    |> Enum.map(&icon_candidate/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.min_by(&elem(&1, 0), &<=/2, fn -> nil end)
    |> case do
      nil -> nil
      {_rank, href} -> page_url |> URI.merge(href) |> URI.to_string()
    end
  end

  defp icon_candidate({"link", attrs, _children}) do
    rel = attrs |> attr("rel") |> String.downcase() |> String.split()
    href = attrs |> attr("href") |> String.trim()
    type = attrs |> attr("type") |> base_type()

    cond do
      href == "" or svg?(href, type) -> nil
      "icon" in rel and png?(href, type) -> {{0, size_distance(attr(attrs, "sizes"))}, href}
      "apple-touch-icon" in rel or "apple-touch-icon-precomposed" in rel -> {{1, 0}, href}
      "icon" in rel -> {{2, 0}, href}
      true -> nil
    end
  end

  defp icon_candidate(_node), do: nil

  defp attr(attrs, name) do
    case List.keyfind(attrs, name, 0) do
      {^name, value} -> value
      nil -> ""
    end
  end

  defp svg?(href, type), do: type == "image/svg+xml" or extension?(href, ".svg")
  defp png?(href, type), do: type == "image/png" or extension?(href, ".png")

  defp extension?(href, extension) do
    case URI.parse(href).path do
      nil -> false
      path -> path |> String.downcase() |> String.ends_with?(extension)
    end
  end

  # How far the nearest declared width is from 64 px; an undeclared size
  # ranks after every declared one (a number sorts before an atom).
  defp size_distance(sizes) do
    sizes
    |> String.downcase()
    |> String.split()
    |> Enum.flat_map(&declared_width/1)
    |> Enum.map(&abs(&1 - @icon_size_px))
    |> Enum.min(fn -> :unsized end)
  end

  defp declared_width(token) do
    case Integer.parse(token) do
      {width, "x" <> _height} when width > 0 -> [width]
      _other -> []
    end
  end

  defp fetch_icon_url(url, opts) do
    with {:ok, response} <- fetch_resource(url, opts, 0, @max_icon_bytes),
         {:ok, mime} <- icon_type(response),
         :ok <- icon_bytes(response, mime) do
      store_image(Keyword.get(opts, :store_thumbnail), response.body, mime)
    end
  end

  defp icon_type(response) do
    mime = response |> content_type() |> base_type()
    if mime in @icon_types, do: {:ok, mime}, else: {:error, {:unsupported_icon_type, mime}}
  end

  # The phone decodes these bytes, so they must be one of the formats it was
  # told to expect, whatever the server called them.
  defp icon_bytes(%{body: body}, mime) do
    if image_bytes?(body), do: :ok, else: {:error, {:unrecognised_icon_bytes, mime}}
  end

  defp image_bytes?(<<0x89, "PNG\r\n\x1A\n", _rest::binary>>), do: true
  defp image_bytes?(<<"GIF87a", _rest::binary>>), do: true
  defp image_bytes?(<<"GIF89a", _rest::binary>>), do: true
  defp image_bytes?(<<0xFF, 0xD8, 0xFF, _rest::binary>>), do: true
  defp image_bytes?(<<"RIFF", _size::32, "WEBP", _rest::binary>>), do: true
  defp image_bytes?(<<0, 0, 1, 0, _rest::binary>>), do: true
  defp image_bytes?(_bytes), do: false

  defp fetch_resource(_url, _opts, redirects, _max_bytes) when redirects > @max_redirects,
    do: {:error, :redirect_limit}

  defp fetch_resource(url, opts, redirects, max_bytes) do
    with {:ok, pinned} <- pin(url, opts),
         {:ok, response} <- request(pinned, opts, max_bytes),
         :ok <- body_cap(response, max_bytes) do
      handle_resource_response(url, response, opts, redirects, max_bytes)
    end
  end

  defp handle_resource_response(_url, %{status: status} = response, _opts, _redirects, _max)
       when status in 200..299,
       do: {:ok, response}

  defp handle_resource_response(url, %{status: status} = response, opts, redirects, max_bytes)
       when status in 300..399 do
    with {:ok, location} <- redirect_location(response),
         target <- url |> URI.merge(location) |> URI.to_string() do
      fetch_resource(target, opts, redirects + 1, max_bytes)
    end
  end

  defp handle_resource_response(_url, %{status: status}, _opts, _redirects, _max_bytes),
    do: {:error, {:http_status, status}}

  defp store_thumbnail(url, %{body: body} = response, opts) when is_binary(body) do
    case Keyword.get(opts, :store_thumbnail) do
      nil ->
        {:ok, nil, []}

      store when is_function(store, 2) ->
        store_image_thumbnail(store, url, body, response)
    end
  end

  defp store_thumbnail(url, _response, _opts), do: {:ok, nil, [{url, :invalid_body}]}

  # A stored thumbnail is recorded as an `:image` blob and rendered as one by
  # every device, so only an image response may be stored. Anything else is
  # skipped and reported; the preview still goes out without an image.
  defp store_image_thumbnail(store, url, body, response) do
    with {:ok, mime} <- image_type(response),
         {:ok, image} <- store_image(store, body, mime) do
      {:ok, image, []}
    else
      {:error, reason} -> {:ok, nil, [{url, reason}]}
    end
  end

  defp image_type(response) do
    mime = response |> content_type() |> base_type()

    if String.starts_with?(mime, "image/") and mime != "image/",
      do: {:ok, mime},
      else: {:error, {:unsupported_thumbnail_type, mime}}
  end

  defp base_type(content_type) do
    content_type
    |> String.split(";", parts: 2)
    |> List.first()
    |> String.trim()
    |> String.downcase()
  end

  # A thumbnail and an icon are stored the same way, as image blobs; with no
  # store injected, nothing is stored and the preview carries none.
  defp store_image(nil, _body, _mime), do: {:ok, nil}

  defp store_image(store, body, mime) do
    case store.(body, mime) do
      {:ok, ref} when is_binary(ref) ->
        {:ok, %{ref: ref, mime: mime, size_bytes: byte_size(body)}}

      {:error, reason} ->
        {:error, {:store_failed, reason}}

      other ->
        {:error, {:invalid_store_result, other}}
    end
  end

  defp pin(url, opts), do: PinnedUrl.pin(url, resolver: Keyword.get(opts, :resolver))

  # An injected `:request` is handed what `PinnedUrl.request/3` would send.
  # Through a proxy the tunnel is opened to the pinned address, never the name.
  defp request(pinned, opts, max_bytes) do
    options = request_options(opts, max_bytes)

    case Keyword.get(opts, :request) do
      nil -> PinnedUrl.request(pinned, options, Egress.active())
      request -> request.(pinned, PinnedUrl.request_options(pinned, options))
    end
  end

  defp request_options(opts, max_bytes) do
    base = [
      method: :get,
      retry: false,
      receive_timeout: TimeoutPolicy.receive_timeout_for(:unfurl),
      connect_options: [timeout: 3_000],
      headers: [{"user-agent", user_agent()}]
    ]

    base
    |> Keyword.merge(Keyword.get(opts, :req_options, []))
    |> Keyword.put(:decode_body, false)
    |> Keyword.put(:into, capped_collector(max_bytes))
  end

  defp capped_collector(max) do
    fn {:data, data}, {request, response} -> collect_chunk(data, request, response, max) end
  end

  defp collect_chunk(data, request, %{body: body} = response, max)
       when is_binary(data) and is_binary(body) do
    received = byte_size(body) + byte_size(data)

    if received > max do
      capped = Req.Response.put_private(response, :fermix_body_cap, received)
      {:halt, {request, capped}}
    else
      {:cont, {request, %{response | body: body <> data}}}
    end
  end

  defp body_cap(%{private: %{fermix_body_cap: _received}}, _max), do: {:error, :body_too_large}

  defp body_cap(%{body: body}, max) when is_binary(body) and byte_size(body) <= max, do: :ok
  defp body_cap(%{body: body}, _max) when is_binary(body), do: {:error, :body_too_large}
  defp body_cap(_response, _max), do: {:error, :invalid_body}

  defp redirect_location(response) do
    case header(response, "location") do
      nil -> {:error, :redirect_missing_location}
      location -> {:ok, location}
    end
  end

  defp content_type(response), do: header(response, "content-type") || "application/octet-stream"

  defp header(%{headers: headers}, name) when is_map(headers) do
    headers |> Map.get(name) |> first_header()
  end

  defp header(%{headers: headers}, name) when is_list(headers) do
    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(to_string(key)) == name, do: first_header(value)
    end)
  end

  defp header(_response, _name), do: nil
  defp first_header([value | _rest]), do: value
  defp first_header(value) when is_binary(value), do: value
  defp first_header(_value), do: nil

  defp meta(document, property) do
    document
    |> Floki.find(~s(meta[property="#{property}"]))
    |> Floki.attribute("content")
    |> List.first()
    |> clean()
  end

  defp clean(nil), do: nil

  defp clean(value) do
    case String.trim(value) do
      "" -> nil
      cleaned -> cleaned
    end
  end

  defp valid_utf8(body) do
    if String.valid?(body), do: body, else: scrub_utf8(body, <<>>)
  end

  defp scrub_utf8(<<>>, acc), do: acc

  defp scrub_utf8(<<codepoint::utf8, rest::binary>>, acc),
    do: scrub_utf8(rest, acc <> <<codepoint::utf8>>)

  defp scrub_utf8(<<_byte, rest::binary>>, acc), do: scrub_utf8(rest, acc <> "�")

  defp user_agent do
    "fermix/#{Application.spec(:fermix_core, :vsn) || "0.1.0"}"
  end

  defp validate_options(opts) do
    Enum.find_value(@option_arities, :ok, fn {key, {arity, error}} ->
      value = Keyword.get(opts, key)
      if not is_nil(value) and not is_function(value, arity), do: {:error, error}
    end)
  end
end
