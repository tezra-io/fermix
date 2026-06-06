defmodule FermixCore.Providers.Error do
  @moduledoc """
  Shared LLM provider error classification.

  Provider adapters return structured errors so agent replies and traces can
  distinguish auth, quota, rate-limit, outage, and transport failures without
  parsing provider-specific log strings.
  """

  @type provider :: atom()
  @type adapter :: atom()
  @type api_error :: %{
          provider: provider(),
          adapter: adapter(),
          status: pos_integer() | nil,
          kind: atom(),
          code: String.t() | nil,
          message: String.t()
        }
  @type transport_error :: %{
          provider: provider(),
          adapter: adapter(),
          reason: term(),
          kind: atom(),
          message: String.t()
        }

  @spec api(provider(), adapter(), pos_integer(), term()) :: {:provider_error, api_error()}
  def api(provider, adapter, status, body)
      when is_atom(provider) and is_atom(adapter) and is_integer(status) and status > 0 do
    decoded = decode_body(body)
    code = error_code(decoded)
    message = error_message(decoded) || "HTTP #{status}"

    {:provider_error,
     %{
       provider: provider,
       adapter: adapter,
       status: status,
       kind: api_kind(status, code, message),
       code: code,
       message: message
     }}
  end

  @doc """
  Credential preflight failure — no usable key/token before any request
  was made. `kind: :auth` routes channel replies to the same "fix your
  auth" message as a provider 401, with `status: nil` marking that no
  HTTP exchange happened.
  """
  @spec auth(provider(), adapter(), String.t()) :: {:provider_error, api_error()}
  def auth(provider, adapter, message)
      when is_atom(provider) and is_atom(adapter) and is_binary(message) do
    {:provider_error,
     %{
       provider: provider,
       adapter: adapter,
       status: nil,
       kind: :auth,
       code: nil,
       message: message
     }}
  end

  @spec not_implemented(provider(), adapter()) :: {:provider_error, api_error()}
  def not_implemented(provider, adapter) when is_atom(provider) and is_atom(adapter) do
    {:provider_error,
     %{
       provider: provider,
       adapter: adapter,
       status: nil,
       kind: :not_implemented,
       code: nil,
       message: "#{provider_label(provider)} #{adapter} adapter is not implemented yet"
     }}
  end

  @spec transport(provider(), adapter(), term()) :: {:provider_transport_error, transport_error()}
  def transport(provider, adapter, reason) when is_atom(provider) and is_atom(adapter) do
    {:provider_transport_error,
     %{
       provider: provider,
       adapter: adapter,
       reason: reason,
       kind: transport_kind(reason),
       message: "#{provider_label(provider)} transport error: #{inspect(reason)}"
     }}
  end

  @spec telemetry_metadata(term()) :: map()
  def telemetry_metadata({:provider_error, error}) when is_map(error) do
    %{
      error_kind: Map.fetch!(error, :kind),
      error_status: Map.fetch!(error, :status),
      error: Map.fetch!(error, :message)
    }
    |> maybe_put(:error_code, Map.get(error, :code))
  end

  def telemetry_metadata({:provider_transport_error, error}) when is_map(error) do
    %{
      error_kind: Map.fetch!(error, :kind),
      transport_error_reason: Map.fetch!(error, :reason),
      error: Map.fetch!(error, :message)
    }
  end

  def telemetry_metadata(:context_length_exceeded) do
    %{error_kind: :context_length, error: "context_length_exceeded"}
  end

  def telemetry_metadata(reason), do: %{error_kind: :provider, error: error_text(reason)}

  @spec provider_label(atom()) :: String.t()
  def provider_label(:openai), do: "OpenAI"
  def provider_label(:openai_codex), do: "Codex"
  def provider_label(:anthropic), do: "Anthropic"
  def provider_label(:xai), do: "xAI"
  def provider_label(provider), do: provider |> to_string() |> String.replace("_", " ")

  defp api_kind(status, code, message) do
    text = String.downcase("#{code || ""} #{message}")

    cond do
      auth_status?(status) -> :auth
      status == 402 -> :quota
      quota_error?(text) -> :quota
      status == 429 -> :rate_limit
      status == 408 -> :timeout
      unavailable_error?(status, text) -> :provider_unavailable
      true -> :provider
    end
  end

  defp auth_status?(status), do: status in [401, 403]

  defp quota_error?(text) do
    String.contains?(text, "insufficient_quota") or String.contains?(text, "quota")
  end

  defp unavailable_error?(status, text) do
    status in 500..599 or String.contains?(text, "overload")
  end

  defp transport_kind(:timeout), do: :timeout
  defp transport_kind(:closed), do: :transport_closed
  defp transport_kind(:econnrefused), do: :network
  defp transport_kind(_reason), do: :transport

  defp decode_body(body) when is_map(body), do: body

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _not_json -> %{"error" => body}
    end
  end

  defp decode_body(body), do: %{"error" => inspect(body)}

  defp error_code(body) when is_map(body) do
    body
    |> error_object()
    |> case do
      error when is_map(error) -> string_value(error, "code", :code)
      _other -> nil
    end
  end

  defp error_message(body) when is_map(body) do
    case error_object(body) do
      error when is_map(error) ->
        string_value(error, "message", :message) || string_value(body, "message", :message)

      error when is_binary(error) ->
        error

      _other ->
        string_value(body, "message", :message)
    end
  end

  defp error_object(body), do: Map.get(body, "error", Map.get(body, :error))

  defp string_value(map, string_key, atom_key) do
    case Map.get(map, string_key, Map.get(map, atom_key)) do
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp error_text(reason) when is_binary(reason), do: reason
  defp error_text(reason), do: inspect(reason)
end
