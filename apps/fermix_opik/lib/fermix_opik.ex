defmodule FermixOpik do
  @moduledoc """
  Exports Fermix's telemetry to an Opik instance for trace inspection,
  cost tracking, and evaluation.

  When enabled, `FermixOpik.Application` starts an `Aggregator` + `Sender` and
  attaches `FermixOpik.Reporter` to Fermix's telemetry. Every main agent turn —
  including the subagents it delegates to and the tools they call — and every
  scheduled job run is reassembled into one Opik trace (with auto-computed cost
  from token usage). Prompt/response bodies appear only if Fermix is run with
  content capture on (`FERMIX_TRACE_CONTENT=1`).

  Configuration lives under `:fermix_opik` (see `config/config.exs`); env vars
  (`FERMIX_OPIK_*`) override at runtime.
  """

  # Env vars are read directly (not just via config) because when this app runs
  # inside the Fermix release, the plugin's own runtime.exs does not execute —
  # only Fermix's does. Reading env here keeps it switchable with nothing more
  # than `FERMIX_OPIK_ENABLED=1`, no edit to Fermix's config needed.

  # Opik export is a dev/prod observability surface — it must never run under
  # :test. In the umbrella, `mix test` boots `fermix_opik` as a sibling app, so
  # without this gate a developer with `FERMIX_OPIK_ENABLED=1` exported in their
  # shell (for the dev daemon / eval skill) would attach the global telemetry
  # reporter during the test run and POST every test's telemetry to Opik as
  # empty traces. This is the runtime half of the `only: [:dev, :prod]` dep
  # gating in fermix_core/mix.exs; the flag alone must not switch export on in
  # test. Captured at compile time so it stays release-safe (Mix is unavailable
  # at runtime in a release).
  @compiled_env Mix.env()

  @doc """
  Whether the exporter should run: the dev/prod environment gate AND the flag.

  Always `false` under `:test`, regardless of `FERMIX_OPIK_ENABLED` — use
  `enabled_by_flag?/0` to inspect the flag itself.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: @compiled_env != :test and enabled_by_flag?()

  @doc """
  The env-var-over-config switch (env `FERMIX_OPIK_ENABLED`, else the `:enabled`
  config). Not gated by environment — `enabled?/0` is the real run decision.
  """
  @spec enabled_by_flag?() :: boolean()
  def enabled_by_flag? do
    case System.get_env("FERMIX_OPIK_ENABLED") do
      truthy when truthy in ["1", "true", "TRUE", "yes", "y"] -> true
      falsy when falsy in ["0", "false", "FALSE", "no", "n"] -> false
      _unset -> Application.get_env(:fermix_opik, :enabled, false) == true
    end
  end

  @doc "The resolved Opik client config (base_url + optional cloud auth)."
  @spec client_config() :: map()
  def client_config do
    %{
      base_url:
        env("FERMIX_OPIK_BASE_URL") ||
          Application.get_env(:fermix_opik, :base_url, "http://localhost:5173/api"),
      api_key: env("FERMIX_OPIK_API_KEY") || Application.get_env(:fermix_opik, :api_key),
      workspace: env("FERMIX_OPIK_WORKSPACE") || Application.get_env(:fermix_opik, :workspace)
    }
  end

  @doc "The Opik project traces are written to (env `FERMIX_OPIK_PROJECT`, else config)."
  @spec project_name() :: String.t()
  def project_name do
    env("FERMIX_OPIK_PROJECT") || Application.get_env(:fermix_opik, :project_name, "fermix")
  end

  defp env(name) do
    case System.get_env(name) do
      nil -> nil
      "" -> nil
      value -> value
    end
  end
end
