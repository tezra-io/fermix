defmodule FermixCore.Providers.Error do
  @moduledoc """
  Shared LLM provider error classification.

  Provider adapters return structured errors so agent replies and traces can
  distinguish auth, quota, rate-limit, outage, and transport failures without
  parsing provider-specific log strings.

  `:plan_not_eligible` is ChatGPT plan usage refusing the signed-in account or
  workspace (or Fermix's sign-in) outright, and `:invalid_request` is that route
  refusing the request itself. Neither is a credential fault, and neither is
  failover-eligible: both are setup facts a fallback would only hide.
  """

  @empty_body_message "The response body was empty, so the provider gave no reason for this status."

  @type provider :: atom()
  @type adapter :: atom()

  @typedoc """
  Where the failure happened relative to response data — a MEASURED value.
  A streaming adapter that counts response chunks tags `:before_response`
  (zero chunks seen) or `:mid_stream` (data already flowed); an adapter that
  cannot measure gets `:unknown`, never a guess. Consumers that treat
  `:before_response` as proof of a zero-data failure (e.g.
  `Transient.pre_response_timeout?/1`) depend on this: an unmeasured error
  must not default into the proven class. Failover does NOT key on stage
  (it is diagnostic there — see `Failover.eligible?/1`); it rides telemetry
  as `transport_stage`.
  """
  @type stage :: :before_response | :mid_stream | :unknown

  @type api_error :: %{
          :provider => provider(),
          :adapter => adapter(),
          :status => pos_integer() | nil,
          :kind => atom(),
          :code => String.t() | nil,
          :message => String.t(),
          :stage => stage(),
          # Present on rate-limit/quota errors when the provider body carried
          # them (OpenAI/Codex usage limits); nil otherwise.
          optional(:resets_at) => non_neg_integer() | nil,
          optional(:plan_type) => String.t() | nil,
          # The request field the provider named when it refused part of the
          # body (`error.param`); present only when the body carried one.
          optional(:param) => String.t(),
          # The server's own declared-failure sentence, set explicitly by the
          # call site (never parsed out of :message) so channel replies can
          # quote the provider verbatim; nil otherwise.
          optional(:provider_words) => String.t() | nil
        }
  @type transport_error :: %{
          provider: provider(),
          adapter: adapter(),
          reason: term(),
          kind: atom(),
          message: String.t(),
          stage: stage()
        }

  @spec api(provider(), adapter(), pos_integer(), term(), keyword()) ::
          {:provider_error, api_error()}
  def api(provider, adapter, status, body, opts \\ [])
      when is_atom(provider) and is_atom(adapter) and is_integer(status) and status > 0 do
    decoded = decode_body(body)
    code = error_code(decoded)
    message = api_message(body, decoded, status)

    {:provider_error,
     %{
       provider: provider,
       adapter: adapter,
       status: status,
       kind: api_kind(status, code, message),
       code: code,
       message: message,
       resets_at: resets_at(decoded),
       plan_type: plan_type(decoded),
       provider_words: Keyword.get(opts, :provider_words),
       stage: stage_opt(opts)
     }
     |> maybe_put(:param, error_param(decoded))}
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
       message: message,
       stage: :before_response
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
       message: "#{provider_label(provider)} #{adapter} adapter is not implemented yet",
       stage: :before_response
     }}
  end

  @spec transport(provider(), adapter(), term(), keyword()) ::
          {:provider_transport_error, transport_error()}
  def transport(provider, adapter, reason, opts \\ [])
      when is_atom(provider) and is_atom(adapter) do
    {:provider_transport_error,
     %{
       provider: provider,
       adapter: adapter,
       reason: reason,
       kind: transport_kind(reason),
       message:
         Keyword.get(opts, :message) ||
           "#{provider_label(provider)} transport error: #{inspect(reason)}",
       stage: stage_opt(opts)
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
  def provider_label(:xai), do: "SpaceXAI"
  def provider_label(:chatgpt), do: "ChatGPT"
  def provider_label(provider), do: provider |> to_string() |> String.replace("_", " ")

  # Sign in with ChatGPT plan usage names every refusal with a stable code
  # (M57 §8; the protocol reference §7.2, including the DevKit's `_v2_`
  # aliases). The code decides the kind whatever the status says: a usage limit
  # arrives as a 429 before the stream and inside `response.failed` (an intact
  # 200) after it, and both are the same verdict.
  @code_kinds %{
    "subscription_sharing_usage_limit_exceeded" => :quota,
    "subscription_sharing_usage_unavailable" => :provider_unavailable,
    "subscription_sharing_user_unavailable" => :provider_unavailable,
    "subscription_sharing_v2_user_unavailable" => :provider_unavailable,
    "subscription_sharing_user_not_eligible" => :plan_not_eligible,
    "subscription_sharing_v2_user_not_eligible" => :plan_not_eligible,
    "subscription_sharing_v2_client_not_enabled" => :plan_not_eligible,
    "subscription_sharing_unsupported_capability" => :invalid_request,
    "subscription_sharing_route_not_supported" => :invalid_request,
    "subscription_sharing_v2_route_not_supported" => :invalid_request,
    "subscription_sharing_invalid_user" => :auth,
    "subscription_sharing_v2_invalid_user" => :auth
  }

  defp api_kind(status, code, message) do
    text = String.downcase("#{code || ""} #{message}")

    Map.get(@code_kinds, code) || account_kind(status, text) ||
      availability_kind(status, text) || :provider
  end

  # Account-level verdicts take precedence: a 429 whose body says
  # insufficient_quota is an exhausted account, not a transient rate limit.
  defp account_kind(status, text) do
    cond do
      auth_status?(status) -> :auth
      status == 402 -> :quota
      quota_error?(text) -> :quota
      true -> nil
    end
  end

  defp availability_kind(status, text) do
    cond do
      status == 429 -> :rate_limit
      rate_limit_error?(text) -> :rate_limit
      status == 408 -> :timeout
      unavailable_error?(status, text) -> :provider_unavailable
      true -> nil
    end
  end

  defp auth_status?(status), do: status in [401, 403]

  defp quota_error?(text) do
    String.contains?(text, "insufficient_quota") or String.contains?(text, "quota")
  end

  # A server can declare a rate limit without a 429 wrapper — Codex reports it
  # as a stream `error` event with code `rate_limit_exceeded` on an intact 200.
  defp rate_limit_error?(text) do
    String.contains?(text, "rate_limit") or String.contains?(text, "rate limit")
  end

  defp unavailable_error?(status, text) do
    status in 500..599 or String.contains?(text, "overload") or
      String.contains?(text, "server_error")
  end

  defp transport_kind(:timeout), do: :timeout
  defp transport_kind(:closed), do: :transport_closed
  defp transport_kind(:econnrefused), do: :network
  # Pool-checkout exhaustion: no connection could be obtained at all (the
  # wake-from-sleep race). Deliberately its own kind, NOT :network — it is
  # terminal for failover (every provider shares the dead local network) and is
  # recovered by the scheduled-job runner's transient backoff instead.
  defp transport_kind(:connection_unavailable), do: :connection_unavailable
  # A failed hop through the configured proxy (`FermixCore.Net.Egress`). Neither
  # kind is failover-eligible: every route leaves through the same proxy, so
  # another provider cannot help. An unreachable proxy is worth another try on
  # the same route, like a pool with no connection to give; a refusal is not.
  defp transport_kind(:proxy_unreachable), do: :proxy_unreachable

  defp transport_kind(reason)
       when reason in [:proxy_auth_required, :proxy_refused, :proxy_needs_https],
       do: :proxy_refused

  defp transport_kind(_reason), do: :transport

  defp stage_opt(opts) do
    case Keyword.get(opts, :stage, :unknown) do
      stage when stage in [:before_response, :mid_stream, :unknown] ->
        stage

      other ->
        raise ArgumentError,
              "invalid error stage: #{inspect(other)}; " <>
                "expected :before_response, :mid_stream, or :unknown"
    end
  end

  # A zero-byte or whitespace-only body is not JSON, so it decodes to
  # %{"error" => ""} and its message comes back "" rather than nil: the
  # "HTTP <status>" floor never applied and the error carried nothing (Codex
  # answered a cron run's first call with a bodiless 404, 2026-09-15). Say what
  # is actually known, rather than leave a blank for the operator, or an agent
  # reading the run ledger, to fill with a guess.
  defp api_message(body, decoded, status) do
    if blank_body?(body),
      do: @empty_body_message,
      else: error_message(decoded) || "HTTP #{status}"
  end

  defp blank_body?(body), do: is_binary(body) and String.trim(body) == ""

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
        string_value(error, "message", :message) || body_message(body)

      error when is_binary(error) ->
        error

      _other ->
        body_message(body)
    end
  end

  # Some backends (e.g. the ChatGPT Codex endpoint) return a bare top-level
  # `{"detail": "..."}` with no nested `"error"` object — surface that string
  # instead of collapsing to a bare "HTTP <status>".
  defp body_message(body) do
    string_value(body, "message", :message) || string_value(body, "detail", :detail)
  end

  # Unix-seconds reset time from an OpenAI/Codex usage-limit body, if present.
  defp resets_at(body) when is_map(body) do
    case error_object(body) do
      error when is_map(error) -> number_value(error, "resets_at", :resets_at)
      _other -> nil
    end
  end

  defp error_param(body) when is_map(body) do
    case error_object(body) do
      error when is_map(error) -> string_value(error, "param", :param)
      _other -> nil
    end
  end

  defp plan_type(body) when is_map(body) do
    case error_object(body) do
      error when is_map(error) -> string_value(error, "plan_type", :plan_type)
      _other -> nil
    end
  end

  defp number_value(map, string_key, atom_key) do
    case Map.get(map, string_key, Map.get(map, atom_key)) do
      value when is_number(value) and value >= 0 -> value
      _other -> nil
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
