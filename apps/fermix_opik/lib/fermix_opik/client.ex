defmodule FermixOpik.Client do
  @moduledoc """
  Thin HTTP client for Opik's native REST batch ingestion.

  Posts whole traces (trace row + its spans) to the batch endpoints. A finished
  trace is upserted by id, so re-sending is idempotent. For a default local
  docker-compose Opik no auth is needed; Opik Cloud needs `api_key` +
  `workspace`, sent as headers.
  """

  require Logger

  @type config :: %{
          base_url: String.t(),
          api_key: String.t() | nil,
          workspace: String.t() | nil
        }

  @doc """
  Send one closed trace (`%{trace: map, spans: [map]}`) to Opik.

  Returns `:ok` on success, `{:error, reason}` otherwise. Never raises.
  """
  @spec send_trace(config(), %{trace: map(), spans: [map()]}, keyword()) :: :ok | {:error, term()}
  def send_trace(config, %{trace: trace, spans: spans}, opts \\ []) do
    with :ok <- post(config, "/v1/private/traces/batch", %{traces: [trace]}, opts) do
      post_spans(config, spans, opts)
    end
  end

  defp post_spans(_config, [], _opts), do: :ok

  defp post_spans(config, spans, opts),
    do: post(config, "/v1/private/spans/batch", %{spans: spans}, opts)

  defp post(config, path, body, opts) do
    url = config.base_url <> path
    req = Keyword.get(opts, :req_module, Req)

    case req.post(url,
           json: sanitize(body),
           headers: headers(config),
           retry: false,
           receive_timeout: 10_000
         ) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status, body: resp_body}} ->
        Logger.warning("Opik rejected #{path}: HTTP #{status} #{inspect(resp_body)}")
        {:error, {:http, status}}

      {:error, reason} ->
        Logger.warning("Opik request to #{path} failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Recursively walk the payload and replace non-UTF8 binaries with a placeholder.
  # Tool outputs (e.g. fetched web pages) may contain non-UTF8 bytes that would
  # cause Jason.encode!/1 to raise — this keeps the Sender alive on bad traces.
  defp sanitize(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {sanitize(k), sanitize(v)} end)
  end

  defp sanitize(list) when is_list(list), do: Enum.map(list, &sanitize/1)

  defp sanitize(binary) when is_binary(binary) do
    if String.valid?(binary), do: binary, else: "[non-utf8: #{byte_size(binary)} bytes]"
  end

  defp sanitize(other), do: other

  defp headers(config) do
    []
    |> maybe_header("authorization", config[:api_key])
    |> maybe_header("comet-workspace", config[:workspace])
  end

  defp maybe_header(headers, _name, nil), do: headers
  defp maybe_header(headers, _name, ""), do: headers
  defp maybe_header(headers, name, value), do: [{name, value} | headers]
end
