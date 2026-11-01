defmodule FermixCore.Providers.DecisionModel do
  @moduledoc """
  A decision model: a hosted model that answers a typed question about some
  text with a calibrated probability instead of writing a reply. Fermix asks
  one yes-or-no question per call (`yes_no/4`); the cue filter's screen is the
  caller (`Cues.Filter.Decision`).

  ## The route

  It runs on a provider the owner already set up, with that provider's own key
  and base URL, so it has no key or setting of its own. Three providers serve
  one, each a constant here, never configuration:

  | Provider | Endpoint | Model |
  |---|---|---|
  | OpenAI | `POST <base>/decisions` (the Decisions API) | `gpt-6-luna` |
  | OpenRouter | `POST <base without /v1>/alpha/decisions` | `~typesafe/jev-latest` (TypeSafe's Jev) |
  | Venice | `POST <base>/decisions` | `jev-latest` (TypeSafe's Jev) |

  The caller passes the owner's choice (`route/1`): one of the three, or nil
  for Automatic, where Fermix picks the primary provider when it serves a
  decision model and is set up, otherwise the first of the three that is set
  up, in the order above. A chosen provider that is not set up is no route,
  never another provider. `pick/2` is the Automatic rule alone, over a primary
  and a set-up check the caller passes, so a settings surface answers from its
  own snapshot. The Jev routes follow the vendor's newest Jev; the answer names
  the model that answered, and the call's telemetry carries it, so an upgrade
  stays visible.

  Set up means `ready?/2`: the provider is configured (`Selection.configured?/2`)
  and its key loaded. A keychain or file secret that never resolved stays in
  application env as its sentinel (`@keyring`, `@file`); sent as a bearer
  token it is a refused call, so here it is no key.

  ## The call

  One attempt, with no retry and no other route: the caller owns retries (the
  cue filter holds and retries a watcher whose provider fails). OpenAI asks a
  `predicate` question, which it may refuse (`{:refused, sentence}`); Jev asks a
  `noul` with yes and no criteria. An answer of any other shape fails as
  `{:parser_changed, sentence}` and is never guessed. HTTP and transport
  failures are `Providers.Error` values (adapter `:decisions`), so a caller
  classifies them as it classifies a chat call's.

  Every call rides `Providers.Telemetry.emit_call/3` with the caller's `agent`
  and `session_id`. The key goes only into the request's header.
  """

  alias FermixCore.Config
  alias FermixCore.Net.HttpClient
  alias FermixCore.Net.TimeoutPolicy
  alias FermixCore.Providers.Descriptor
  alias FermixCore.Providers.Error, as: ProviderError
  alias FermixCore.Providers.Selection
  alias FermixCore.Providers.Telemetry, as: ProviderTelemetry
  alias FermixCore.Setup.SecretWriter

  @providers [:openai, :openrouter, :venice]
  @models %{openai: "gpt-6-luna", openrouter: "~typesafe/jev-latest", venice: "jev-latest"}
  @labels %{openai: "OpenAI · gpt-6-luna", openrouter: "OpenRouter · Jev", venice: "Venice · Jev"}
  @adapter :decisions
  @question "answer"

  @type provider :: :openai | :openrouter | :venice
  @type route :: %{
          provider: provider(),
          model: String.t(),
          url: String.t(),
          api_key: String.t()
        }
  @type question :: %{instructions: String.t(), yes: String.t(), no: String.t()}
  @type answer :: %{probability: float(), model: String.t(), tokens: map()}
  @type failure ::
          {:provider_error, map()}
          | {:provider_transport_error, map()}
          | {:refused, String.t()}
          | {:parser_changed, String.t()}

  @doc "The providers that serve a decision model, in catalog order."
  @spec providers() :: [provider()]
  def providers, do: @providers

  @doc "How a surface names the decision model on `provider`."
  @spec label(provider()) :: String.t()
  def label(provider) when provider in @providers, do: Map.fetch!(@labels, provider)

  @doc """
  Whether `block`, `provider`'s settings as application env holds them (live,
  or a settings snapshot read from it), can carry a decision call: configured,
  with a key that loaded rather than a secret's sentinel.
  """
  @spec ready?(provider(), keyword()) :: boolean()
  def ready?(provider, block) when provider in @providers and is_list(block) do
    Selection.configured?(provider, block) and
      not SecretWriter.sentinel?(Keyword.get(block, :api_key))
  end

  @doc """
  The provider a decision model runs on: the primary (`primary`, shaped as
  `Selection.primary_provider/0` answers) when it serves one and `configured?`
  says it is set up, otherwise the first provider that serves one and is set
  up, in catalog order; `:not_set_up` when none is.
  """
  @spec pick({:ok, atom()} | {:error, term()}, (provider() -> boolean())) ::
          {:ok, provider()} | {:error, :not_set_up}
  def pick(primary, configured?) when is_function(configured?, 1) do
    case Enum.find(lead(primary) ++ @providers, configured?) do
      nil -> {:error, :not_set_up}
      provider -> {:ok, provider}
    end
  end

  # The primary leads only when it serves a decision model; an unreadable
  # primary (two flagged) leaves the catalog order as it is.
  defp lead({:ok, provider}) when provider in @providers, do: [provider]
  defp lead({:ok, provider}) when is_atom(provider), do: []
  defp lead({:error, _reason}), do: []

  @doc """
  The route of the decision model on `choice`, read from application env:
  that provider's when it is `ready?/2`, `{:not_set_up, provider}` when it is
  not; for nil (Automatic) the one `pick/2` picks, or `:not_set_up` when no
  provider that serves one is ready.
  """
  @spec route(provider() | nil) ::
          {:ok, route()} | {:error, :not_set_up | {:not_set_up, provider()}}
  def route(nil) do
    with {:ok, provider} <- pick(Selection.primary_provider(), &ready?(&1, env_block(&1))),
         do: route(provider)
  end

  def route(provider) when provider in @providers do
    block = env_block(provider)

    if ready?(provider, block),
      do: {:ok, build_route(provider, block)},
      else: {:error, {:not_set_up, provider}}
  end

  defp env_block(provider) do
    case Config.provider(provider) do
      {:ok, block} -> block
      {:error, :not_configured} -> []
    end
  end

  # Only a block `ready?/2` passed gets here, so its key is there; a missing one
  # is a bug that fails loud.
  defp build_route(provider, block) do
    %{
      provider: provider,
      model: Map.fetch!(@models, provider),
      url: url(provider, base_url(provider, block)),
      api_key: Keyword.fetch!(block, :api_key)
    }
  end

  defp base_url(provider, block) do
    case Keyword.get(block, :base_url) do
      base when is_binary(base) and base != "" -> String.trim_trailing(base, "/")
      _default -> Descriptor.fetch!(provider).default_base_url
    end
  end

  # OpenRouter serves decisions beside its `/v1` API, not under it.
  defp url(:openrouter, base), do: String.replace_suffix(base, "/v1", "") <> "/alpha/decisions"
  defp url(_provider, base), do: base <> "/decisions"

  @doc """
  Asks one yes-or-no question about `state` on `route`: how likely the answer
  is yes. Opts: `:agent` and `:session_id` (the call's telemetry), and the seam
  `:req_options` (merged into the request).
  """
  @spec yes_no(route(), String.t(), question(), keyword()) ::
          {:ok, answer()} | {:error, failure()}
  def yes_no(
        %{provider: provider} = route,
        state,
        %{instructions: _, yes: _, no: _} = question,
        opts
      )
      when provider in @providers and is_binary(state) and is_list(opts) do
    started = System.monotonic_time(:millisecond)
    body = body(provider, route.model, state, question)
    result = route |> post(body, opts) |> response(provider)
    emit(route, result, System.monotonic_time(:millisecond) - started, opts)
    result
  end

  # --- the request ------------------------------------------------------------------

  defp body(:openai, model, state, question) do
    %{
      model: model,
      input: state,
      questions: [
        %{
          type: "predicate",
          name: @question,
          instructions:
            "#{question.instructions}\n\nYes means: #{question.yes}\nNo means: #{question.no}"
        }
      ]
    }
  end

  defp body(provider, model, state, question) do
    noul = %{
      type: "noul",
      instructions: question.instructions,
      criteria: %{"true" => question.yes, "false" => question.no}
    }

    Map.merge(%{model: model, state: state, questions: %{@question => noul}}, extra(provider))
  end

  # Jev is TypeSafe's alone, so no other host may take the request, and the
  # item is not offered for training.
  defp extra(:openrouter), do: %{provider: %{allow_fallbacks: false, data_collection: "deny"}}
  defp extra(:venice), do: %{}

  defp post(route, body, opts) do
    Req.new(
      url: route.url,
      method: :post,
      json: body,
      receive_timeout: TimeoutPolicy.receive_timeout_for(:decision)
    )
    |> Req.Request.put_header("authorization", "Bearer #{route.api_key}")
    |> Req.merge(Keyword.get(opts, :req_options, []))
    |> HttpClient.request("#{Descriptor.fetch!(route.provider).label} decision")
  end

  # --- the answer -------------------------------------------------------------------

  defp response({:ok, %Req.Response{status: status, body: body}}, provider)
       when status in 200..299,
       do: answer(provider, body)

  defp response({:ok, %Req.Response{status: status, body: body}}, provider),
    do: {:error, ProviderError.api(provider, @adapter, status, body)}

  defp response({:error, %Req.TransportError{reason: reason}}, provider),
    do: {:error, ProviderError.transport(provider, @adapter, reason)}

  defp response({:error, exception}, provider),
    do: {:error, ProviderError.transport(provider, @adapter, exception)}

  defp answer(:openai, %{"answers" => [%{"name" => @question} = answer], "model" => model} = body)
       when is_binary(model),
       do: openai_answer(answer, model, body)

  defp answer(provider, %{"answers" => %{@question => answer}, "model" => model} = body)
       when provider in [:openrouter, :venice] and is_binary(model),
       do: jev_answer(provider, answer, model, body)

  defp answer(provider, _body), do: parser_changed(provider)

  defp openai_answer(%{"type" => "predicate", "probability" => probability}, model, body),
    do: probability(:openai, probability, model, body)

  defp openai_answer(%{"type" => "refusal"}, _model, _body),
    do: {:error, {:refused, "OpenAI's decision model refused to judge this."}}

  defp openai_answer(_answer, _model, _body), do: parser_changed(:openai)

  defp jev_answer(provider, %{"type" => "noul", "noul" => probability}, model, body),
    do: probability(provider, probability, model, body)

  defp jev_answer(provider, _answer, _model, _body), do: parser_changed(provider)

  defp probability(_provider, value, model, body)
       when is_number(value) and value >= 0 and value <= 1,
       do: {:ok, %{probability: value / 1, model: model, tokens: tokens(body)}}

  defp probability(provider, _value, _model, _body), do: parser_changed(provider)

  # Unreported counts are left out, never zero.
  defp tokens(%{"usage" => usage}) when is_map(usage) do
    [prompt: usage["input_tokens"], completion: usage["output_tokens"]]
    |> Enum.filter(fn {_key, count} -> is_integer(count) end)
    |> Map.new()
  end

  defp tokens(_body), do: %{}

  defp parser_changed(provider) do
    {:error,
     {:parser_changed,
      "#{Descriptor.fetch!(provider).label}'s decision model answered in a shape Fermix " <>
        "does not read; its decision API may have changed."}}
  end

  # --- telemetry --------------------------------------------------------------------

  defp emit(route, result, duration_ms, opts) do
    {status, model, tokens, error, output} = telemetry_result(route, result)

    metadata =
      %{
        provider: route.provider,
        adapter: @adapter,
        model: model,
        status: status,
        tokens: tokens,
        reasoning_effort: nil
      }
      |> Map.merge(error)
      |> put_agent(Keyword.get(opts, :agent))

    ProviderTelemetry.emit_call(metadata, max(duration_ms, 0),
      session_id: Keyword.get(opts, :session_id),
      parent_session: Keyword.get(opts, :parent_session),
      output: output
    )
  end

  defp telemetry_result(_route, {:ok, answer}),
    do: {:ok, answer.model, answer.tokens, %{}, "probability #{answer.probability}"}

  defp telemetry_result(route, {:error, {tag, sentence}}) when tag in [:refused, :parser_changed],
    do: {:error, route.model, %{}, %{error_kind: tag, error: sentence}, nil}

  defp telemetry_result(route, {:error, reason}),
    do: {:error, route.model, %{}, ProviderError.telemetry_metadata(reason), nil}

  defp put_agent(metadata, nil), do: metadata
  defp put_agent(metadata, agent), do: Map.put(metadata, :agent, agent)
end
