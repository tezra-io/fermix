defmodule FermixChannels.Mobile.Unfurl do
  @moduledoc """
  SSRF-safe host-side link-preview resolution for mobile messages.

  The phone never fetches page or thumbnail URLs. Every target and redirect is
  resolved and pinned through `FermixCore.Net.Guard`; Host and TLS SNI retain
  the original hostname. Resolution is bounded to two links, five redirects,
  and a one-MiB body per response.
  """

  alias FermixCore.Net.Guard
  alias FermixCore.Net.TimeoutPolicy

  @max_links 2
  @max_redirects 5
  @max_body_bytes 1_048_576
  @url_regex ~r{https?://[^\s<>"']+}iu
  @trailing_punctuation ~r/[),.;!?\]}]+\z/u

  @type preview :: %{
          required(:url) => String.t(),
          required(:site) => String.t(),
          required(:title) => String.t(),
          required(:description) => String.t() | nil,
          required(:image_ref) => String.t() | nil
        }

  @spec resolve(String.t(), keyword()) ::
          {:ok, [preview()], [{String.t(), term()}]} | {:error, term()}
  def resolve(text, opts \\ []) when is_binary(text) and is_list(opts) do
    with :ok <- validate_options(opts) do
      text
      |> links()
      |> Enum.reduce({[], []}, &resolve_link(&1, &2, opts))
      |> then(fn {previews, warnings} ->
        {:ok, Enum.reverse(previews), Enum.reverse(warnings)}
      end)
    end
  end

  defp links(text) do
    text
    |> then(&Regex.scan(@url_regex, &1, capture: :first))
    |> List.flatten()
    |> Enum.map(&String.replace(&1, @trailing_punctuation, ""))
    |> Enum.uniq()
    |> Enum.take(@max_links)
  end

  defp resolve_link(url, {previews, warnings}, opts) do
    case fetch_page(url, opts, 0) do
      {:ok, final_url, response} ->
        case build_preview(final_url, response, opts) do
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

  defp build_preview(url, %{body: body}, opts) when is_binary(body) do
    with {:ok, document} <- Floki.parse_document(valid_utf8(body)),
         {:ok, title} <- preview_title(document),
         {:ok, image_ref, warnings} <- preview_image(document, url, opts) do
      site = meta(document, "og:site_name") || URI.parse(url).host || ""

      {:ok,
       %{
         url: url,
         site: site,
         title: title,
         description: meta(document, "og:description"),
         image_ref: image_ref
       }, warnings}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_preview(_url, _response, _opts), do: {:error, :invalid_body}

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
        do_store_thumbnail(store, url, body, content_type(response))
    end
  end

  defp store_thumbnail(url, _response, _opts), do: {:ok, nil, [{url, :invalid_body}]}

  defp do_store_thumbnail(store, url, body, mime) do
    case store.(body, mime) do
      {:ok, ref} when is_binary(ref) -> {:ok, ref, []}
      {:error, reason} -> {:ok, nil, [{url, {:store_failed, reason}}]}
      other -> {:ok, nil, [{url, {:invalid_store_result, other}}]}
    end
  end

  defp pin(url, opts) do
    case Guard.resolve_and_validate(url, resolver: Keyword.get(opts, :resolver)) do
      :ok -> {:ok, %{url: url, original_url: url, original_host: URI.parse(url).host}}
      {:ok, ip} -> {:ok, pinned_url(url, ip)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp pinned_url(url, ip) do
    host = URI.parse(url).host
    pinned = %{URI.parse(url) | host: ip_string(ip)} |> URI.to_string()
    %{url: pinned, original_url: url, original_host: host}
  end

  defp request(pinned, opts) do
    request = Keyword.get(opts, :request, &default_request/2)
    request.(pinned, request_options(pinned, opts))
  end

  defp default_request(pinned, options), do: Req.get(pinned.url, options)

  defp request_options(pinned, opts) do
    base = [
      redirect: false,
      retry: false,
      receive_timeout: TimeoutPolicy.receive_timeout_for(:unfurl),
      connect_options: connect_options(pinned.original_host),
      headers: [{"host", pinned.original_host}, {"user-agent", user_agent()}]
    ]

    base
    |> Keyword.merge(Keyword.get(opts, :req_options, []))
    |> Keyword.put(:decode_body, false)
    |> Keyword.put(:into, capped_collector(@max_body_bytes))
  end

  defp connect_options(host) do
    [timeout: 3_000, transport_opts: [server_name_indication: String.to_charlist(host)]]
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

  defp ip_string({_a, _b, _c, _d} = ip), do: ip |> :inet.ntoa() |> to_string()

  defp ip_string({_a, _b, _c, _d, _e, _f, _g, _h} = ip),
    do: "[" <> (ip |> :inet.ntoa() |> to_string()) <> "]"

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
