defmodule FermixCore.Management.Providers do
  @moduledoc """
  `providers.set_primary`, `providers.models.list` and `providers.probe.start`
  (M34 native setup §7.3).

  The first two answer inside the request; the probe is metered and is therefore
  a job. Nothing here re-implements a refusal: making a provider primary commits
  through the same tail every other write uses, so the external-change refusal
  and the baseline re-record apply identically from either door.

  A live model listing never degrades to the catalog. The two are different
  answers to different questions — "what can this server run right now" against
  "what does this build know about" — and serving one under the other's label is
  the failure this refuses.
  """

  alias FermixCore.Auth.Redaction
  alias FermixCore.Management.Jobs
  alias FermixCore.Management.Settings
  alias FermixCore.Providers.Descriptor
  alias FermixCore.Providers.ModelCatalog
  alias FermixCore.Providers.ModelListing
  alias FermixCore.Providers.Selection
  alias FermixCore.Providers.Telemetry, as: ProviderTelemetry
  alias FermixCore.Setup.Doctor
  alias FermixCore.Setup.Wizard

  require Logger

  @default_limit 50
  @max_limit 200
  @probe_agent "management_job"

  @type error ::
          {:invalid_params, String.t(), String.t()}
          | {:unavailable, String.t()}
          | {:busy, String.t()}
          | {:external_change, [String.t()]}
          | {:config_unreadable, String.t()}

  @doc """
  Makes one configured provider the primary.

  An unconfigured provider is refused before anything is written: promoting a
  provider with no credential would leave the daemon with a primary it cannot
  call.
  """
  @spec set_primary(String.t(), keyword()) :: {:ok, map()} | {:error, error()}
  def set_primary(provider, opts \\ []) when is_binary(provider) and is_list(opts) do
    with {:ok, id} <- fetch_provider(provider),
         :ok <- require_configured(id, opts) do
      commit_primary(id, opts)
    end
  end

  @doc """
  One page of models for a provider, from the catalog this build ships or from
  the provider's own live listing.
  """
  @spec models(map(), keyword()) :: {:ok, map()} | {:error, error()}
  def models(params, opts \\ []) when is_map(params) and is_list(opts) do
    with {:ok, provider} <- fetch_provider(Map.get(params, "provider")),
         {:ok, live?} <- fetch_live(params),
         {:ok, limit} <- fetch_limit(params),
         {:ok, offset} <- fetch_cursor(params),
         {:ok, source, entries} <- entries(provider, live?, opts) do
      {:ok, page(entries, Map.get(params, "query"), offset, limit, source)}
    end
  end

  @doc """
  Starts a metered call against the provider, single-flight per provider.

  The call carries the job's id as its `session_id`, so the metered request is
  attributable to the run that issued it rather than appearing unparented.
  """
  @spec probe_start(String.t(), keyword()) :: {:ok, map()} | {:error, error()}
  def probe_start(provider, opts \\ []) when is_binary(provider) and is_list(opts) do
    with {:ok, id} <- fetch_provider(provider) do
      start_probe(id, provider, opts)
    end
  end

  defp start_probe(id, provider, opts) do
    started =
      Jobs.start(
        :provider_probe,
        Keyword.merge(Keyword.get(opts, :jobs, []),
          name: provider,
          run: probe_run(id, opts)
        )
      )

    case started do
      {:ok, view} -> {:ok, view}
      {:error, :busy} -> {:error, {:busy, "provider_probe"}}
    end
  end

  defp probe_run(id, opts) do
    probe = Keyword.get(opts, :probe, &Doctor.probe_provider/2)
    probe_opts = Keyword.get(opts, :probe_opts, [])

    fn job_id, report ->
      report.({:phase, "calling"})
      probe(probe, id, job_id, probe_opts)
    end
  end

  defp probe(probe, id, job_id, probe_opts) do
    started = System.monotonic_time(:millisecond)
    result = probe.(id, probe_opts)
    duration_ms = max(System.monotonic_time(:millisecond) - started, 0)

    emit_call(id, job_id, result, duration_ms)
    probe_outcome(result)
  end

  # The single provider emitter, never a hand-rolled event: the probe is a real
  # metered call and belongs in the same stream as every other one.
  defp emit_call(id, job_id, result, duration_ms) do
    ProviderTelemetry.emit_call(
      %{
        provider: id,
        model: probe_model(result),
        status: probe_status(result),
        agent: @probe_agent
      },
      duration_ms,
      session_id: job_id
    )
  end

  defp probe_model({:ok, %{model: model}}), do: model
  defp probe_model({:error, _reason}), do: nil

  defp probe_status({:ok, _ok}), do: "ok"
  defp probe_status({:error, {kind, _reason}}), do: Atom.to_string(kind)
  defp probe_status({:error, {kind, _status, _body}}), do: Atom.to_string(kind)

  defp probe_outcome({:ok, %{model: model, latency_ms: latency_ms}}) do
    {:ok, %{"model" => model, "latency_ms" => latency_ms}}
  end

  defp probe_outcome({:error, reason}), do: {:error, {:unavailable, probe_sentence(reason)}}

  defp probe_sentence({:misconfigured, reason}), do: "The provider is not configured: #{reason}."

  defp probe_sentence({:auth_scope_mismatch, surface, hint}),
    do: "#{surface} refused the credential: #{hint}."

  defp probe_sentence({:server_error, status, _body}),
    do: "The provider answered HTTP #{status}."

  # A transport reason is an internal term: a struct, a socket option, a path.
  # It goes to the daemon log rather than to the sentence a client renders.
  defp probe_sentence({:network, reason}) do
    Logger.error(
      "management providers: the provider could not be reached: " <>
        Redaction.format(reason)
    )

    "The provider could not be reached. See the daemon log."
  end

  defp commit_primary(id, opts) do
    commit = Keyword.get(opts, :commit, &Wizard.mark_primary/1)

    case commit.(id) do
      {:ok, _report} -> {:ok, %{"restart" => Settings.restart(), "side_effects" => []}}
      {:error, {:external_change, sections}} -> {:error, {:external_change, sections}}
      {:error, {:config_unreadable, sentence}} -> {:error, {:config_unreadable, sentence}}
      {:error, reason} -> {:error, {:invalid_params, "provider", save_sentence(reason)}}
    end
  end

  defp save_sentence(reason) do
    Logger.error(
      "management providers: the primary provider could not be saved: " <>
        Redaction.format(reason)
    )

    "The primary provider could not be saved. See the daemon log."
  end

  defp require_configured(id, opts) do
    configured? = Keyword.get(opts, :configured?, &Selection.configured?/1)

    if configured?.(id) do
      :ok
    else
      {:error, {:invalid_params, "provider", "This provider has no credentials yet."}}
    end
  end

  defp entries(provider, false, _opts), do: {:ok, "catalog", catalog_entries(provider)}

  defp entries(provider, true, opts) do
    if ModelListing.live?(provider) do
      live_entries(provider, Keyword.get(opts, :live_models, &ModelListing.live_models/2))
    else
      {:error, {:unavailable, "model_listing"}}
    end
  end

  defp live_entries(provider, live_models) do
    case live_models.(provider, []) do
      {:ok, models} -> {:ok, "live", Enum.map(models, &%{"id" => &1.id, "label" => &1.label})}
      {:error, _reason} -> {:error, {:unavailable, "model_listing"}}
    end
  end

  defp catalog_entries(provider) do
    provider
    |> ModelCatalog.models_for()
    |> Enum.map(&%{"id" => &1.id, "label" => &1.label})
  end

  defp page(entries, query, offset, limit, source) do
    matching = filter(entries, query)
    models = matching |> Enum.drop(offset) |> Enum.take(limit)
    remaining = length(matching) - offset - length(models)

    %{
      "models" => models,
      "cursor" => next_cursor(remaining, offset + length(models)),
      "source" => source,
      "truncated" => remaining > 0
    }
  end

  defp filter(entries, nil), do: entries

  defp filter(entries, query) when is_binary(query) do
    needle = String.downcase(query)

    Enum.filter(entries, fn entry ->
      String.contains?(String.downcase(entry["id"]), needle) or
        String.contains?(String.downcase(entry["label"]), needle)
    end)
  end

  defp next_cursor(remaining, _offset) when remaining <= 0, do: nil
  defp next_cursor(_remaining, offset), do: Base.url_encode64("#{offset}", padding: false)

  defp fetch_provider(provider) when is_binary(provider) do
    case Enum.find(Descriptor.ids(), &(Atom.to_string(&1) == provider)) do
      nil -> {:error, {:invalid_params, "provider", "This daemon has no such provider."}}
      id -> {:ok, id}
    end
  end

  defp fetch_provider(_provider),
    do: {:error, {:invalid_params, "provider", "A provider name is required."}}

  defp fetch_live(%{"live" => live?}) when is_boolean(live?), do: {:ok, live?}

  defp fetch_live(_params),
    do: {:error, {:invalid_params, "live", "Say whether the listing should be live."}}

  defp fetch_limit(params) do
    case Map.get(params, "limit", @default_limit) do
      limit when is_integer(limit) and limit >= 1 and limit <= @max_limit -> {:ok, limit}
      _invalid -> {:error, {:invalid_params, "limit", "A page holds 1 to 200 models."}}
    end
  end

  defp fetch_cursor(params) do
    case Map.get(params, "cursor") do
      nil ->
        {:ok, 0}

      cursor when is_binary(cursor) ->
        decode_cursor(cursor)

      _invalid ->
        {:error, {:invalid_params, "cursor", "The cursor is not one this daemon minted."}}
    end
  end

  defp decode_cursor(cursor) do
    with {:ok, decoded} <- Base.url_decode64(cursor, padding: false),
         {offset, ""} when offset >= 0 <- Integer.parse(decoded) do
      {:ok, offset}
    else
      _invalid ->
        {:error, {:invalid_params, "cursor", "The cursor is not one this daemon minted."}}
    end
  end
end
