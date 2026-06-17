defmodule FermixCore.Observability do
  @moduledoc """
  Reports the daemon's Opik exporter readiness — from inside the daemon process.

  The exporter (`fermix_opik`) is the in-umbrella `apps/fermix_opik` app, bundled
  into every dev/prod build and absent only from the test build (`only: [:dev,
  :prod]`). This module still never references it at compile time — the probes
  dynamic-dispatch and degrade to "not loaded" — so it also compiles cleanly in
  the exporter-less test build.

  It must run in the daemon process. The env var, loaded modules, and attached
  telemetry handlers it inspects are per-process state — a `fermix doctor` CLI
  process sees its own shell env and an empty handler table, not the daemon's, so
  the daemon answers this over its control socket rather than the CLI introspecting
  itself.
  """

  # FermixOpik.Reporter (the apps/fermix_opik umbrella app) attaches under this
  # handler id. Probing the telemetry handler table by id confirms the reporter is
  # attached without loading FermixOpik or depending on its internals.
  @opik_handler_id "fermix-opik-reporter"
  @truthy ~w(1 true TRUE yes y)

  @type status :: :disabled | :enabled_missing_app | :enabled_not_attached | :enabled_ready

  @type report :: %{
          status: status(),
          enabled_env: boolean(),
          loaded: boolean(),
          attached: boolean(),
          base_url: String.t() | nil,
          project: String.t() | nil
        }

  @doc """
  Build the readiness report. Probes default to the real (dynamic-dispatch)
  implementations; tests inject `:enabled_env?`, `:loaded?`, `:attached?`, and
  `:config` to exercise every state without a bundled exporter.
  """
  @spec report(keyword()) :: report()
  def report(opts \\ []) when is_list(opts) do
    enabled_env? = Keyword.get(opts, :enabled_env?, &default_enabled_env?/0)
    loaded? = Keyword.get(opts, :loaded?, &default_loaded?/0)
    attached? = Keyword.get(opts, :attached?, &default_attached?/0)
    config = Keyword.get(opts, :config, &default_config/0)

    env = enabled_env?.()
    loaded = loaded?.()
    attached = loaded and attached?.()
    {base_url, project} = if loaded, do: config.(), else: {nil, nil}

    %{
      status: status(env, loaded, attached),
      enabled_env: env,
      loaded: loaded,
      attached: attached,
      base_url: base_url,
      project: project
    }
  end

  defp status(false, _loaded, _attached), do: :disabled
  defp status(true, false, _attached), do: :enabled_missing_app
  defp status(true, true, false), do: :enabled_not_attached
  defp status(true, true, true), do: :enabled_ready

  defp default_enabled_env?, do: System.get_env("FERMIX_OPIK_ENABLED") in @truthy

  defp default_loaded?, do: Code.ensure_loaded?(FermixOpik)

  defp default_attached? do
    [:fermix, :provider, :call]
    |> :telemetry.list_handlers()
    |> Enum.any?(fn handler -> handler.id == @opik_handler_id end)
  end

  # Dynamic dispatch: FermixOpik is not a compile-time dependency in default
  # builds. Only invoked when `loaded` is true, so the module is present.
  defp default_config do
    base_url = apply(FermixOpik, :client_config, []) |> Map.get(:base_url)
    {base_url, apply(FermixOpik, :project_name, [])}
  end
end
