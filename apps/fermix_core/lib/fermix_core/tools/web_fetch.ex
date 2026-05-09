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
  def description, do: "Fetch a public HTTP(S) URL and return readable markdown-light text."

  @impl true
  def parameters do
    %{
      type: "object",
      required: ["url"],
      properties: %{url: %{type: "string", description: "Public HTTP(S) URL to fetch."}}
    }
  end

  @impl true
  def when_to_use, do: "Fetch and summarize the contents of a known public URL."

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
         :ok <- Guard.validate(url, resolver: resolver(context)) do
      fetch(url, context, 0)
    else
      {:error, reason} -> Support.error(format_guard_error(reason))
    end
  end

  defp fetch(_url, _context, redirects) when redirects > @max_redirects do
    Support.error("redirect_limit: exceeded #{@max_redirects} redirects")
  end

  defp fetch(url, context, redirects) do
    case Req.get(url, request_options(context)) do
      {:ok, %{status: status} = response} when status in 200..299 ->
        render_response(response)

      {:ok, %{status: status} = response} when status in 300..399 ->
        follow_redirect(url, response, context, redirects)

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
    with {:ok, doc} <- Floki.parse_document(body) do
      {:ok, Tool.success(HtmlText.extract(doc))}
    else
      {:error, reason} -> Support.error("parse_failed: #{inspect(reason)}")
    end
  end

  defp render_response(%{body: body}), do: {:ok, Tool.success(to_string(body))}

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

  defp follow_redirect(url, response, context, redirects) do
    case get_header(response.headers, "location") do
      nil ->
        Support.error("network: redirect missing location")

      location ->
        target = url |> URI.merge(location) |> URI.to_string()

        with :ok <- Guard.validate_redirect(target, url, resolver: resolver(context)) do
          fetch(target, context, redirects + 1)
        else
          {:error, reason} -> Support.error(format_guard_error(reason))
        end
    end
  end

  defp request_options(context) do
    context
    |> base_request_options()
    |> Keyword.put(:into, &stream_body/2)
  end

  defp base_request_options(context) do
    [
      redirect: false,
      retry: false,
      receive_timeout: 15_000,
      connect_options: [timeout: 3_000],
      headers: [{"user-agent", user_agent()}]
    ]
    |> Keyword.merge(Map.get(context, :req_options, []))
  end

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
