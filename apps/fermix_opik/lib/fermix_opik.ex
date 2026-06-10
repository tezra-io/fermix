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

  @doc "Whether the exporter is enabled (env `FERMIX_OPIK_ENABLED`, else config)."
  @spec enabled?() :: boolean()
  def enabled? do
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
