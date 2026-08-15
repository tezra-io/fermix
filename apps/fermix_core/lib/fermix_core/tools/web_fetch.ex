defmodule FermixCore.Tools.WebFetch do
  @moduledoc """
  Fetch a public web page and return markdown-light text.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Net.Guard
  alias FermixCore.Tools.HtmlText
  alias FermixCore.Tools.Support

  @max_body_bytes 1_048_576
  @max_redirects 5

  @impl true
  def name, do: "web_fetch"

  @impl true
  def description,
    do:
      "Fetch ONE known public HTTP(S) URL and return readable markdown-light text. USE WHEN the content is in the server HTML; do NOT use for JavaScript-rendered or interactive pages (use browser)."

  @impl true
  def parameters do
    %{
      type: "object",
      required: ["url"],
      properties: %{url: %{type: "string", description: "Public HTTP(S) URL to fetch."}}
    }
  end

  @impl true
  def when_to_use,
    do:
      "To read or verify a source you already have the URL for — fetch it rather than describing it from memory. Readable text of one known static URL; not JS-rendered or interactive pages (use browser). Cite that exact URL when the page's content reaches your answer."

  @impl true
  def examples,
    do: [%{args: %{"url" => "https://hexdocs.pm/req/Req.html"}, note: "read one known page"}]

  @impl true
  def failure_modes do
    [
      %{tag: "blocked_url", description: "NetGuard rejected the URL or redirect target"},
      %{tag: "too_large", description: "response body exceeded 1MB"},
      %{tag: "redirect_limit", description: "more than five redirects"},
      %{tag: "network", description: "transport or HTTP failure"}
    ]
  end

  @impl true
  def requires_setup, do: nil

  @impl true
  def category, do: :web

  @impl true
  def execute(args, context) when is_map(args) and is_map(context) do
    Support.run(name(), put_trace_metadata(context), fn -> do_execute(args, context) end)
  end

  defp do_execute(args, context) do
    with {:ok, url} <- Support.required_string(args, "url"),
         {:ok, pinned} <- pin(url, context) do
      fetch(pinned, context, 0)
    else
      {:error, reason} -> Support.error(format_guard_error(reason))
    end
  end

  defp pin(url, context) do
    case Guard.resolve_and_validate(url, resolver: resolver(context)) do
      :ok ->
        # IP-literal URL (no DNS to rebind). The Guard already verified
        # the literal is public; connect to it directly.
        {:ok, %{url: url, pinned_ip: nil}}

      {:ok, ip} ->
        {:ok,
         %{url: rewrite_url_with_ip(url, ip), pinned_ip: ip, original_host: original_host(url)}}

      {:error, _reason} = err ->
        err
    end
  end

  defp rewrite_url_with_ip(url, ip) do
    uri = URI.parse(url)
    %{uri | host: ip_to_string(ip)} |> URI.to_string()
  end

  defp original_host(url), do: URI.parse(url).host

  defp ip_to_string({_a, _b, _c, _d} = ip), do: :inet.ntoa(ip) |> to_string()

  defp ip_to_string({_a, _b, _c, _d, _e, _f, _g, _h} = ip),
    do: "[" <> (ip |> :inet.ntoa() |> to_string()) <> "]"

  defp fetch(_pinned, _context, redirects) when redirects > @max_redirects do
    Support.error("redirect_limit: exceeded #{@max_redirects} redirects")
  end

  defp fetch(pinned, context, redirects) do
    case Req.get(pinned.url, request_options(context, pinned)) do
      {:ok, %{status: status} = response} when status in 200..299 ->
        render_response(response)

      {:ok, %{status: status} = response} when status in 300..399 ->
        follow_redirect(pinned, response, context, redirects)

      {:ok, %{status: status}} ->
        Support.error("network: HTTP #{status}")

      {:error, reason} ->
        Support.error("network: #{inspect(reason)}")
    end
  end

  defp render_response(%{private: %{fermix_body_cap: :too_large}}) do
    Support.error("too_large: response body exceeded #{@max_body_bytes} bytes")
  end

  defp render_response(%{body: body}) when is_binary(body) do
    with {:ok, doc} <- Floki.parse_document(ensure_utf8(body)) do
      {:ok, Tool.success(HtmlText.extract(doc))}
    else
      {:error, reason} -> Support.error("parse_failed: #{inspect(reason)}")
    end
  end

  defp render_response(%{body: body}) when is_map(body) or is_list(body),
    do: Support.success_json(body)

  defp render_response(%{body: body}), do: {:ok, Tool.success(to_string(body))}

  # Fetched pages arrive in arbitrary charsets; a non-UTF-8 body (e.g. a Latin-1
  # page) carries invalid byte sequences that make the unicode-flagged regex in
  # the text renderer raise (`:re.run` badarg, crashing the tool) and would also
  # break JSON-encoding the result. Replace invalid sequences with U+FFFD so the
  # whole pipeline — Floki, HtmlText, and the returned text — is valid UTF-8.
  # A valid body (the common case) is returned unchanged.
  defp ensure_utf8(body) when is_binary(body) do
    if String.valid?(body), do: body, else: scrub_utf8(body, <<>>)
  end

  defp scrub_utf8(<<>>, acc), do: acc

  defp scrub_utf8(<<codepoint::utf8, rest::binary>>, acc),
    do: scrub_utf8(rest, acc <> <<codepoint::utf8>>)

  defp scrub_utf8(<<_byte, rest::binary>>, acc),
    do: scrub_utf8(rest, acc <> "�")

  defp stream_body({:data, data}, {req, %{body: body} = response}) when is_binary(data) do
    next_size = byte_size(body) + byte_size(data)

    if next_size > @max_body_bytes do
      response = Req.Response.put_private(response, :fermix_body_cap, :too_large)
      {:halt, {req, response}}
    else
      {:cont, {req, %{response | body: body <> data}}}
    end
  end

  defp stream_body({:data, data}, {req, response}) when is_binary(data) do
    stream_body({:data, data}, {req, %{response | body: ""}})
  end

  defp follow_redirect(pinned, response, context, redirects) do
    case get_header(response.headers, "location") do
      nil ->
        Support.error("network: redirect missing location")

      location ->
        # Resolve the redirect target against the original (pre-pinning)
        # host so relative locations land on the correct hostname before
        # we re-pin the new target's DNS.
        original_url = original_url(pinned)
        target = original_url |> URI.merge(location) |> URI.to_string()

        with :ok <- Guard.validate_redirect(target, original_url, resolver: resolver(context)),
             {:ok, next_pinned} <- pin(target, context) do
          fetch(next_pinned, context, redirects + 1)
        else
          {:error, reason} -> Support.error(format_guard_error(reason))
        end
    end
  end

  defp original_url(%{original_host: nil, url: url}), do: url

  defp original_url(%{original_host: host, url: url}) do
    %{URI.parse(url) | host: host} |> URI.to_string()
  end

  defp original_url(%{url: url}), do: url

  defp request_options(context, pinned) do
    context
    |> base_request_options(pinned)
    |> Keyword.put(:into, &stream_body/2)
  end

  defp base_request_options(context, pinned) do
    headers =
      [{"user-agent", user_agent()}]
      |> maybe_put_host_header(pinned)

    [
      redirect: false,
      retry: false,
      receive_timeout: 15_000,
      connect_options: connect_options(pinned),
      headers: headers
    ]
    |> Keyword.merge(Map.get(context, :req_options, []))
  end

  defp base_request_options(context) do
    base_request_options(context, %{url: nil, pinned_ip: nil, original_host: nil})
  end

  defp maybe_put_host_header(headers, %{original_host: host})
       when is_binary(host) and host != "" do
    [{"host", host} | headers]
  end

  defp maybe_put_host_header(headers, _pinned), do: headers

  defp connect_options(%{original_host: host}) when is_binary(host) and host != "" do
    # Pin SNI to the original hostname so TLS still validates the cert
    # against the name the user asked for, even though the socket
    # connects to the validated IP literal.
    [timeout: 3_000, transport_opts: [server_name_indication: String.to_charlist(host)]]
  end

  defp connect_options(_pinned), do: [timeout: 3_000]

  defp put_trace_metadata(context) do
    Map.put(context, :tool_trace, %{request_headers: redacted_request_headers(context)})
  end

  defp redacted_request_headers(context) do
    context
    |> base_request_options()
    |> Keyword.get(:headers, [])
    |> Guard.redact_headers_for_trace()
  end

  defp resolver(context), do: Map.get(context, :net_resolver, nil)

  defp user_agent do
    "fermix/#{Application.spec(:fermix_core, :vsn) || "0.1.0"}"
  end

  defp get_header(headers, name) when is_map(headers) do
    headers
    |> Map.get(String.downcase(name))
    |> header_value()
  end

  defp get_header(headers, name) when is_list(headers) do
    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(to_string(key)) == String.downcase(name), do: header_value(value)
    end)
  end

  defp get_header(_headers, _name), do: nil
  defp header_value([value | _rest]), do: value
  defp header_value(value) when is_binary(value), do: value
  defp header_value(_value), do: nil

  defp format_guard_error({:blocked_host, reason}), do: "blocked_url: #{reason}"

  defp format_guard_error({:resolved_to_private_address, ip}),
    do: "blocked_url: resolved to #{inspect(ip)}"

  defp format_guard_error(reason), do: "blocked_url: #{inspect(reason)}"
end
