defmodule FermixCore.Tools.WebSearch.Backends.Support do
  @moduledoc false

  alias FermixCore.Net.Guard

  @type result :: %{title: String.t(), url: String.t(), snippet: String.t()}

  @spec credential(keyword(), atom(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def credential(opts, key, label) when is_list(opts) and is_atom(key) and is_binary(label) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value not in ["", "@keyring"] -> {:ok, value}
      _value -> {:error, "auth_failed: missing #{label}"}
    end
  end

  @spec configured?(keyword(), atom()) :: boolean()
  def configured?(opts, key) when is_list(opts) and is_atom(key) do
    match?({:ok, _}, credential(opts, key, Atom.to_string(key)))
  end

  @doc """
  Normalizes a backend error reason to a string so the `{:error, String.t()}`
  contract holds. `Net.Guard` returns structured terms (e.g.
  `{:dns_resolution_failed, _}`); wrap those as `network:` rather than letting
  a non-string reason reach callers that pattern-match on it (e.g. the doctor
  probe's `String.starts_with?/2`).
  """
  @spec error_string(term()) :: String.t()
  def error_string(reason) when is_binary(reason), do: reason
  def error_string(reason), do: "network: #{inspect(reason)}"

  @spec trace_metadata(keyword()) :: map()
  def trace_metadata(request_options) when is_list(request_options) do
    request_headers =
      request_options
      |> Keyword.get(:headers, [])
      |> Guard.redact_headers_for_trace()

    %{request_headers: request_headers}
  end

  @spec decode_body(term()) :: {:ok, map()} | {:error, String.t()}
  def decode_body(%{} = body), do: {:ok, body}

  def decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _decoded} -> {:error, "parser_changed: non-object JSON response"}
      {:error, reason} -> {:error, "parser_changed: #{inspect(reason)}"}
    end
  end

  def decode_body(_body), do: {:error, "parser_changed: non-JSON response body"}

  @spec response_json(map()) :: {:ok, map()} | {:error, String.t()}
  def response_json(%{status: status, body: body}) when status in 200..299, do: decode_body(body)

  def response_json(%{status: status}) when status in [401, 403],
    do: {:error, "auth_failed: HTTP #{status}"}

  def response_json(%{status: 429}), do: {:error, "rate_limited: HTTP 429"}
  def response_json(%{status: status}), do: {:error, "provider_error: HTTP #{status}"}

  @spec normalize_results(term(), (map() -> result() | nil)) ::
          {:ok, [result()]} | {:error, String.t()}
  def normalize_results(results, mapper) when is_list(results) and is_function(mapper, 1) do
    normalized =
      results
      |> Enum.map(&map_result(&1, mapper))
      |> Enum.reject(&is_nil/1)

    {:ok, normalized}
  end

  def normalize_results(_results, _mapper), do: {:error, "parser_changed: missing results array"}

  @spec text(term()) :: String.t()
  def text(value) when is_binary(value), do: String.trim(value)
  def text(value) when is_number(value), do: value |> to_string() |> String.trim()
  def text(_value), do: ""

  @spec join_texts(term()) :: String.t()
  def join_texts(values) when is_list(values) do
    values
    |> Enum.map(&text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  def join_texts(value), do: text(value)

  @spec keep_result(result()) :: result() | nil
  def keep_result(%{title: title, url: url} = result) do
    if text(title) != "" and text(url) != "", do: result
  end

  defp map_result(%{} = result, mapper), do: result |> mapper.() |> normalize_result()
  defp map_result(_result, _mapper), do: nil

  defp normalize_result(%{title: title, url: url, snippet: snippet}) do
    keep_result(%{title: text(title), url: text(url), snippet: text(snippet)})
  end

  defp normalize_result(_result), do: nil
end
