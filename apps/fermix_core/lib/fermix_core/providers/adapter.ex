defmodule FermixCore.Providers.Adapter do
  @moduledoc """
  Per-provider conversion + LLM continuation.

  Adapters translate normalized capabilities into provider-native tool
  shapes, post the chat/continuation requests, and parse the responses
  back into a normalized `provider_turn`. They do **not** execute
  capabilities — that responsibility lives in `FermixCore.AgentLoop`.

  Routing is a deterministic function of `(provider, model, auth_mode,
  base_url)` — see `for_route/1`. Routing on model string alone is unsafe:
  `gpt-4o` direct on `api.openai.com` should hit the Responses API, but the
  same model name proxied through OpenRouter's `/v1/chat/completions`
  must use Chat Completions.

  Codex is treated as a separate provider key (`:openai_codex`) because
  the wire surface — URL, request body, response shape, streaming —
  diverges from the standard `api.openai.com/v1/responses` flow.

  ## Streaming deltas (optional)

  `chat/3`/`continue/3` opts may carry `:stream_callback` — a 1-arity
  function (see `FermixCore.AgentLoop.stream_callback/0`). Adapters whose
  `supports_streaming?/0` is true SHOULD invoke it as
  `cb.({:text_delta, cumulative})` while consuming the provider stream,
  where `cumulative` is the composed answer text so far. Non-streaming
  adapters ignore the opt — no behaviour change, no extra callback to
  implement. See docs/design/CHANNEL_STREAMING.md §5.2.
  """

  alias FermixCore.Capabilities.Capability
  alias FermixCore.Providers.Descriptor

  @type message :: %{
          required(:role) => String.t(),
          required(:content) => String.t(),
          optional(:tool_call_id) => String.t(),
          optional(:tool_calls) => [map()]
        }

  @type tool_result :: %{
          required(:call_id) => String.t(),
          required(:output) => String.t()
        }

  @type normalized_tool_call :: %{
          required(:id) => String.t(),
          required(:call_id) => String.t(),
          required(:name) => String.t(),
          required(:arguments) => map() | String.t()
        }

  @type usage :: %{
          required(:prompt_tokens) => non_neg_integer(),
          required(:completion_tokens) => non_neg_integer(),
          required(:total_tokens) => non_neg_integer()
        }

  @type provider_turn :: %{
          required(:content) => String.t(),
          required(:tool_calls) => [normalized_tool_call()],
          required(:provider_state) => term(),
          required(:usage) => usage(),
          required(:model) => String.t()
        }

  @type route_key :: %{
          required(:provider) => atom(),
          required(:model) => String.t(),
          required(:auth_mode) => :api_key | :oauth | :none,
          required(:base_url) => String.t()
        }

  @callback chat([message()], [Capability.t()], keyword()) ::
              {:ok, provider_turn()} | {:error, term()}

  @callback continue(provider_state :: term(), [tool_result()], keyword()) ::
              {:ok, provider_turn()} | {:error, term()}

  @callback to_provider_tools([Capability.t()]) :: term()

  @callback parse_tool_calls(response :: term()) :: [normalized_tool_call()]

  @callback parse_response(response :: term()) :: provider_turn()

  @callback supports_streaming?() :: boolean()

  @optional_callbacks supports_streaming?: 0

  @api_openai "https://api.openai.com"

  # Dispatch derives from the Descriptor registry: a module adapter maps
  # directly; `:routed` keeps the Responses-vs-ChatCompletions split for
  # direct OpenAI (model string alone is unsafe — see moduledoc).
  @spec for_route(route_key()) :: module()
  def for_route(%{provider: provider} = route_key) when is_atom(provider) do
    case Descriptor.fetch(provider) do
      {:ok, %{adapter: :routed}} ->
        routed_openai_adapter(Map.fetch!(route_key, :model), Map.fetch!(route_key, :base_url))

      {:ok, %{adapter: adapter}} when is_atom(adapter) ->
        adapter

      :error ->
        raise ArgumentError,
              "no adapter for #{inspect(provider)} #{Map.get(route_key, :model)} at " <>
                "#{Map.get(route_key, :base_url)} — register one or set provider explicitly"
    end
  end

  defp routed_openai_adapter(model, base_url) when is_binary(model) and is_binary(base_url) do
    if openai_direct?(base_url) and responses_eligible_model?(model) do
      FermixCore.Providers.OpenAI.Responses
    else
      FermixCore.Providers.OpenAI.ChatCompletions
    end
  end

  defp openai_direct?(base_url), do: String.starts_with?(base_url, @api_openai)

  defp responses_eligible_model?("gpt-" <> _), do: true
  defp responses_eligible_model?("o" <> _), do: true
  defp responses_eligible_model?(_), do: false
end
