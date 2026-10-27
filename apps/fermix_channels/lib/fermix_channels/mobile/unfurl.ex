defmodule FermixChannels.Mobile.Unfurl do
  @moduledoc """
  SSRF-safe host-side link-preview resolution for the links a timeline row
  names, which `FermixChannels.LinkPreviews` chooses.

  No client ever fetches page or thumbnail URLs. Every target and redirect is
  resolved, checked by `FermixCore.Net.Guard` and pinned to the checked address
  (`FermixCore.Net.PinnedUrl`); Host and TLS SNI retain the original hostname.
  Resolution is bounded to four links, as many as a row keeps, five redirects,
  and a one-MiB body per response. A preview keeps the link it was read for
  (`link`) beside the address its page answered from after redirects (`url`),
  so a client pairs it with the link as written.
  """

  alias FermixCore.Net.Egress
  alias FermixCore.Net.PinnedUrl
  alias FermixCore.Net.TimeoutPolicy

  @max_links 4
  @max_redirects 5
  @max_body_bytes 1_048_576

  @typedoc "A stored thumbnail: its content ref, image type and size."
  @type image :: %{ref: String.t(), mime: String.t(), size_bytes: non_neg_integer()}

  @type preview :: %{
          required(:link) => String.t(),
          required(:url) => String.t(),
          required(:site) => String.t(),
          required(:title) => String.t(),
          required(:description) => String.t() | nil,
          required(:image) => image() | nil
        }

  @spec resolve([String.t()], keyword()) ::
          {:ok, [preview()], [{String.t(), term()}]} | {:error, term()}
  def resolve(links, opts \\ []) when is_list(links) and is_list(opts) do
    with :ok <- validate_options(opts) do
      links
      |> Enum.uniq()
      |> Enum.take(@max_links)
      |> Enum.reduce({[], []}, &resolve_link(&1, &2, opts))
      |> then(fn {previews, warnings} ->
        {:ok, Enum.reverse(previews), Enum.reverse(warnings)}
      end)
    end
  end

  defp resolve_link(url, {previews, warnings}, opts) do
    case fetch_page(url, opts, 0) do
      {:ok, final_url, response} ->
        case build_preview(url, final_url, response, opts) do
          {:ok, preview, thumbnail_warnings} ->
            {[preview | previews], Enum.reverse(thumbnail_warnings, warnings)}

          {:error, reason} ->
            {previews, [{url, reason} | warnings]}
        end

      {:error, reason} ->
        {previews, [{url, reason} | warnings]}
    end
  end

  defp fetch_page(_url, _opts, redirects) when redirects > @max_redirects,
    do: {:error, :redirect_limit}

  defp fetch_page(url, opts, redirects) do
    with {:ok, pinned} <- pin(url, opts),
         {:ok, response} <- request(pinned, opts),
         :ok <- body_cap(response) do
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

  defp build_preview(link, url, %{body: body}, opts) when is_binary(body) do
    with {:ok, document} <- Floki.parse_document(valid_utf8(body)),
         {:ok, title} <- preview_title(document),
         {:ok, image, warnings} <- preview_image(document, url, opts) do
      site = meta(document, "og:site_name") || URI.parse(url).host || ""

      {:ok,
       %{
         link: link,
         url: url,
         site: site,
         title: title,
         description: meta(document, "og:description"),
         image: image
       }, warnings}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_preview(_link, _url, _response, _opts), do: {:error, :invalid_body}

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

    case fetch_resource(url, opts, 0) do
      {:ok, response} -> store_thumbnail(url, response, opts)
      {:error, reason} -> {:ok, nil, [{url, reason}]}
    end
  end

  defp fetch_resource(_url, _opts, redirects) when redirects > @max_redirects,
    do: {:error, :redirect_limit}

  defp fetch_resource(url, opts, redirects) do
    with {:ok, pinned} <- pin(url, opts),
         {:ok, response} <- request(pinned, opts),
         :ok <- body_cap(response) do
      handle_resource_response(url, response, opts, redirects)
    end
  end

  defp handle_resource_response(_url, %{status: status} = response, _opts, _redirects)
       when status in 200..299,
       do: {:ok, response}

  defp handle_resource_response(url, %{status: status} = response, opts, redirects)
       when status in 300..399 do
    with {:ok, location} <- redirect_location(response),
         target <- url |> URI.merge(location) |> URI.to_string() do
      fetch_resource(target, opts, redirects + 1)
    end
  end

  defp handle_resource_response(_url, %{status: status}, _opts, _redirects),
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
    case image_type(response) do
      {:ok, mime} -> do_store_thumbnail(store, url, body, mime)
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

  defp do_store_thumbnail(store, url, body, mime) do
    case store.(body, mime) do
      {:ok, ref} when is_binary(ref) ->
        {:ok, %{ref: ref, mime: mime, size_bytes: byte_size(body)}, []}

      {:error, reason} ->
        {:ok, nil, [{url, {:store_failed, reason}}]}

      other ->
        {:ok, nil, [{url, {:invalid_store_result, other}}]}
    end
  end

  defp pin(url, opts), do: PinnedUrl.pin(url, resolver: Keyword.get(opts, :resolver))

  # An injected `:request` is handed what `PinnedUrl.request/3` would send.
  # Through a proxy the tunnel is opened to the pinned address, never the name.
  defp request(pinned, opts) do
    options = request_options(opts)

    case Keyword.get(opts, :request) do
      nil -> PinnedUrl.request(pinned, options, Egress.active())
      request -> request.(pinned, PinnedUrl.request_options(pinned, options))
    end
  end

  defp request_options(opts) do
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
    |> Keyword.put(:into, capped_collector(@max_body_bytes))
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

  defp body_cap(%{private: %{fermix_body_cap: _received}}), do: {:error, :body_too_large}

  defp body_cap(%{body: body}) when is_binary(body) and byte_size(body) <= @max_body_bytes,
    do: :ok

  defp body_cap(%{body: body}) when is_binary(body), do: {:error, :body_too_large}
  defp body_cap(_response), do: {:error, :invalid_body}

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
    cond do
      not is_nil(Keyword.get(opts, :resolver)) and
          not is_function(Keyword.get(opts, :resolver), 1) ->
        {:error, :invalid_resolver}

      not is_nil(Keyword.get(opts, :request)) and not is_function(Keyword.get(opts, :request), 2) ->
        {:error, :invalid_request}

      not is_nil(Keyword.get(opts, :store_thumbnail)) and
          not is_function(Keyword.get(opts, :store_thumbnail), 2) ->
        {:error, :invalid_thumbnail_store}

      true ->
        :ok
    end
  end
end
