defmodule FermixCore.Providers.ModelListing do
  @moduledoc """
  Live model discovery for setup surfaces (M12 follow-up).

  Four providers can answer "which models can I actually use right now?"
  better than the static catalog: Ollama (only the locally installed
  models matter), OpenRouter (the upstream catalog moves weekly), Venice
  (a moving catalog whose per-model privacy tier is what the person picks
  by — M49 §3.3) and OpenAI Codex (it signs in with ChatGPT, the account's
  plan decides, and nothing is shipped for it — M57 §6.2). The static `ModelCatalog` stays
  authoritative for wizard defaults and
  context-window budgeting; this module only feeds setup-time pickers and
  the Ollama server-detection banner. One signal only: the configured URL
  either serves a model list or it doesn't — no host binary sniffing (a
  remote server has no local binary). Setup-time reads with tight
  timeouts — never on the turn path.
  """

  alias FermixCore.Auth.ChatGPT
  alias FermixCore.Auth.Store
  alias FermixCore.Auth.TokenSupervisor
  alias FermixCore.Config
  alias FermixCore.Net.Egress
  alias FermixCore.Providers.Descriptor
  alias FermixCore.Providers.ModelCatalog
  alias FermixCore.Providers.Telemetry, as: ProviderTelemetry

  @receive_timeout_ms 2_000
  # The DevKit's bound on a listed model's display name (M57 protocol §5.3).
  @max_display_name_length 200

  @type live_model :: %{
          id: String.t(),
          label: String.t(),
          context_window: pos_integer() | nil
        }

  @doc "Whether the provider has a live model-listing source."
  @spec live?(atom()) :: boolean()
  def live?(:ollama), do: true
  def live?(:openrouter), do: true
  def live?(:venice), do: true
  def live?(:openai_codex), do: true
  def live?(provider) when is_atom(provider), do: false

  @doc """
  Live models for a provider. Ollama lists the models actually installed
  on the configured server (`GET <root>/api/tags`); OpenRouter lists the
  public upstream catalog (`GET <base>/models`), tool-capable models only,
  newest first; Venice lists its text catalog
  (`GET <base>/models?type=text`, public), tool-capable models only, by
  family then newest. OpenAI Codex lists the signed-in account's catalog
  (`GET <base>/models` with its bearer), `visibility == "list"` entries in
  the server's order, and refuses while the sign-in cannot carry a turn.
  `base_url:`/`req_options:` are injectable; defaults come from the
  provider's config block, then its descriptor.
  """
  @spec live_models(atom(), keyword()) :: {:ok, [live_model()]} | {:error, String.t()}
  def live_models(:ollama, opts) do
    base_url = resolved_base_url(:ollama, opts)
    url = String.trim_trailing(base_url, "/v1") <> "/api/tags"

    case get_json(url, opts) do
      {:ok, %{"models" => models}} when is_list(models) -> {:ok, ollama_entries(models)}
      {:ok, _body} -> {:error, "unexpected response from #{url}"}
      {:error, reason} -> {:error, reason}
    end
  end

  def live_models(:openrouter, opts) do
    url = resolved_base_url(:openrouter, opts) <> "/models"

    case get_json(url, opts) do
      {:ok, %{"data" => models}} when is_list(models) -> {:ok, openrouter_entries(models)}
      {:ok, _body} -> {:error, "unexpected response from #{url}"}
      {:error, reason} -> {:error, reason}
    end
  end

  def live_models(:venice, opts) do
    url = resolved_base_url(:venice, opts) <> "/models?type=text"

    case get_json(url, opts) do
      {:ok, %{"data" => models}} when is_list(models) -> {:ok, venice_entries(models)}
      {:ok, _body} -> {:error, "unexpected response from #{url}"}
      {:error, reason} -> {:error, reason}
    end
  end

  # OpenAI Codex on a ChatGPT plan (M57 §6.2): the signed-in account's own catalog, read
  # with its bearer. Not the standard list shape: `{"models": [{slug,
  # display_name, visibility}]}`. Only `visibility == "list"` entries are for
  # display, in the server's order. A listed entry without a usable slug or
  # name fails the whole listing (the DevKit's `invalid_model_catalog`): a
  # picker that silently drops rows would hide a changed contract.
  def live_models(:openai_codex, opts) do
    url = resolved_base_url(:openai_codex, opts) <> "/models"
    started = System.monotonic_time(:millisecond)

    result =
      with {:ok, bearer} <- chatgpt_bearer(opts),
           {:ok, body} <- get_json(url, [{:bearer, bearer} | opts]) do
        chatgpt_entries(body, url)
      end

    emit_chatgpt_listing(result, System.monotonic_time(:millisecond) - started)
    result
  end

  def live_models(provider, _opts) when is_atom(provider) do
    raise ArgumentError,
          "no live model listing for #{inspect(provider)}; check live?/1 before calling"
  end

  @doc """
  The family a Venice model's own `name` belongs to: its first run of ASCII
  letters, downcased. "Kimi K3" and "Kimi K2.6" are both `kimi`, "GPT-6 Astra"
  is `gpt`, "MiMo-V2.5" is `mimo`. The live listing groups by it (M49 §3.3), so
  the newest model of every family heads its group. A name with no letters has
  no family and sorts first under the empty string.
  """
  @spec model_family(String.t()) :: String.t()
  def model_family(name) when is_binary(name) do
    case Regex.run(~r/[A-Za-z]+/, name) do
      [match] -> String.downcase(match)
      nil -> ""
    end
  end

  defp resolved_base_url(provider, opts) do
    Keyword.get(opts, :base_url) ||
      Keyword.get(provider_config(provider), :base_url) ||
      Descriptor.fetch!(provider).default_base_url
  end

  defp provider_config(provider) do
    case Config.provider(provider) do
      {:ok, config} -> config
      {:error, :not_configured} -> []
    end
  end

  # `:chatgpt_route_status` and `:token_server` replace the auth facade and the
  # token supervisor (tests); `:access_token` skips the token server entirely.
  defp chatgpt_bearer(opts) do
    route_status = Keyword.get(opts, :chatgpt_route_status, &ChatGPT.route_status/1)

    case route_status.([]) do
      :ok -> chatgpt_token(opts)
      {:error, reason} -> {:error, ChatGPT.failure_sentence(reason)}
    end
  end

  defp chatgpt_token(opts) do
    case Keyword.get(opts, :access_token) do
      token when is_binary(token) and token != "" ->
        {:ok, token}

      _absent ->
        server = Keyword.get(opts, :token_server, TokenSupervisor)

        case server.get_token(Store.profile(:openai_codex)) do
          {:ok, token} when is_binary(token) and token != "" -> {:ok, token}
          other -> {:error, "no ChatGPT access token is available (#{inspect(other)})"}
        end
    end
  end

  defp chatgpt_entries(%{"models" => models}, url) when is_list(models) do
    models
    |> Enum.filter(&match?(%{"visibility" => "list"}, &1))
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {model, index}, {:ok, acc} ->
      case chatgpt_entry(model) do
        {:ok, entry} ->
          {:cont, {:ok, [entry | acc]}}

        :error ->
          {:halt, {:error, "listed model #{index} from #{url} has no usable slug or name"}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp chatgpt_entries(_body, url), do: {:error, "unexpected response from #{url}"}

  defp chatgpt_entry(%{"slug" => slug, "display_name" => name})
       when is_binary(slug) and slug != "" and is_binary(name) and name != "" do
    if String.length(name) <= @max_display_name_length do
      {:ok, %{id: slug, label: name, context_window: catalog_window(:openai_codex, slug)}}
    else
      :error
    end
  end

  defp chatgpt_entry(_model), do: :error

  # The listing is a call on the person's ChatGPT credential, so it rides the
  # provider-call stream like the turns do (M57 §9). It has no run, so it
  # carries no session id.
  defp emit_chatgpt_listing(result, duration_ms) do
    metadata =
      case result do
        {:ok, models} -> %{status: :ok, models_count: length(models)}
        {:error, reason} -> %{status: :error, error: reason}
      end

    metadata
    |> Map.merge(%{provider: :openai_codex, adapter: :model_listing, agent: "model_listing"})
    |> ProviderTelemetry.emit_call(max(duration_ms, 0))
  end

  defp ollama_entries(models) do
    for %{"name" => name} = model <- models do
      %{
        id: name,
        label: ollama_label(name, model),
        context_window: catalog_window(:ollama, name)
      }
    end
  end

  defp ollama_label(name, model) do
    case get_in(model, ["details", "parameter_size"]) do
      size when is_binary(size) and size != "" -> "#{name} (#{size})"
      _absent -> name
    end
  end

  # Tool-capable only (the agent loop is tool-driven); permissive when the
  # field is absent. Sorted by id so same-vendor models cluster together
  # (anthropic/*, openai/*, x-ai/*, …) — that ordering makes the long upstream
  # catalog navigable in the setup picker, where the user filters by typing.
  defp openrouter_entries(models) do
    models
    |> Enum.filter(&openrouter_tool_capable?/1)
    |> Enum.flat_map(fn
      %{"id" => id} = model when is_binary(id) -> [openrouter_entry(id, model)]
      _malformed -> []
    end)
    |> Enum.sort_by(& &1.id)
  end

  defp openrouter_tool_capable?(%{"supported_parameters" => parameters})
       when is_list(parameters) do
    "tools" in parameters
  end

  defp openrouter_tool_capable?(_model), do: true

  defp openrouter_entry(id, model) do
    %{
      id: id,
      label: presence(Map.get(model, "name")) || id,
      context_window: positive_integer(Map.get(model, "context_length"))
    }
  end

  # Tool-capable only, for the reason openrouter_entries/1 filters: Fermix sends
  # `tools` on every request, so a model that cannot call them cannot run the
  # loop at all. Ordered by family ascending then `created` descending (M49
  # §3.3), with the id breaking a same-day tie so the order is deterministic —
  # that grouping is what makes a 100-plus-entry picker navigable, and both
  # setup doors render it as-is.
  defp venice_entries(models) do
    models
    |> Enum.flat_map(&venice_sortable/1)
    |> Enum.sort_by(fn {family, created, id, _entry} -> {family, -created, id} end)
    |> Enum.map(fn {_family, _created, _id, entry} -> entry end)
  end

  defp venice_sortable(%{"id" => id, "model_spec" => %{"name" => name} = spec} = model)
       when is_binary(id) and is_binary(name) do
    capabilities = Map.get(spec, "capabilities", %{})

    venice_entry(
      id,
      name,
      model,
      venice_tier(spec, capabilities),
      Map.get(capabilities, "supportsFunctionCalling") == true
    )
  end

  defp venice_sortable(_malformed), do: []

  defp venice_entry(_id, _name, _model, _tier, false), do: []

  # A tier that cannot be read is a model that cannot be labelled truthfully,
  # and the label is the only place the wire carries privacy. Offered without a
  # suffix beside its labelled neighbours it would read as the private default,
  # so it is dropped — the same answer openrouter_entries/1 gives a malformed
  # entry.
  defp venice_entry(_id, _name, _model, :unknown, true), do: []

  defp venice_entry(id, name, model, tier, true) do
    entry = %{
      id: id,
      label: name <> tier,
      context_window: positive_integer(Map.get(model, "context_length"))
    }

    [{model_family(name), venice_created(model), id, entry}]
  end

  # The two words Venice publishes in `model_spec.privacy`, plus the enclave
  # marker: "(TEE)" and never "E2EE", because an `e2ee-*` id called by a plain
  # client runs in the enclave while Venice's own edge still sees plaintext.
  defp venice_tier(%{"privacy" => "private"}, %{"supportsTeeAttestation" => true}),
    do: " · Private (TEE)"

  defp venice_tier(%{"privacy" => "private"}, _capabilities), do: " · Private"
  defp venice_tier(%{"privacy" => "anonymized"}, _capabilities), do: " · Anonymized"
  defp venice_tier(_spec, _capabilities), do: :unknown

  # A model with no publication date sorts last inside its family rather than
  # reordering the ones that have one.
  defp venice_created(%{"created" => created}) when is_integer(created), do: created
  defp venice_created(_model), do: 0

  # Quiet catalog lookup — context_window_for/2 emits unknown_model
  # telemetry, which a setup-page render must not spam.
  defp catalog_window(provider, id) do
    ModelCatalog.models_for(provider)
    |> Enum.find_value(fn entry -> if entry.id == id, do: entry.context_window end)
  end

  defp get_json(url, opts) do
    request =
      Req.new(
        url: url,
        method: :get,
        retry: false,
        headers: bearer_headers(Keyword.get(opts, :bearer)),
        receive_timeout: Keyword.get(opts, :receive_timeout_ms, @receive_timeout_ms)
      )
      |> Req.merge(Keyword.get(opts, :req_options, []))
      |> Egress.attach(:direct)

    case Req.request(request) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: 200}} ->
        {:error, "unexpected response from #{url}"}

      {:ok, %Req.Response{status: status}} ->
        {:error, "HTTP #{status} from #{url}"}

      {:error, %Req.TransportError{reason: :econnrefused}} ->
        {:error, "connection refused at #{url}"}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, "timed out reaching #{url}"}

      {:error, reason} ->
        {:error, "request to #{url} failed: #{inspect(reason)}"}
    end
  end

  defp bearer_headers(nil), do: []

  defp bearer_headers(bearer) when is_binary(bearer),
    do: [{"authorization", "Bearer " <> bearer}, {"accept", "application/json"}]

  defp presence(value) when is_binary(value) and value != "", do: value
  defp presence(_value), do: nil

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: nil
end
