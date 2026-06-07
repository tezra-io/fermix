defmodule FermixCore.Providers.PrimaryConfig do
  @moduledoc """
  The single lower-level read for "which provider is primary".

  Owns the migration rules from docs/design/MULTI_PROVIDER_FAILOVER.md §2:

    1. Exactly one provider block with `primary = true` wins.
    2. No primary flags -> legacy `[fermix_core.agent].provider` if present.
    3. Neither -> `:openai`.
    4. More than one `primary = true` -> `{:error, :multiple_primary}`.
       Never silently pick one.

  Both `RouteResolver.configured_provider/0` and `Selection.primary_provider/1`
  consume this helper, so dependencies stay one-directional
  (`Selection` -> `RouteResolver` -> here) and straggler call sites that still
  call bare `RouteResolver.resolve!()` read the same primary.
  """

  alias FermixCore.Providers.ModelCatalog

  @spec primary() :: {:ok, ModelCatalog.provider()} | {:error, :multiple_primary}
  def primary do
    primary_in(
      Application.get_env(:fermix_core, :providers, []),
      Application.get_env(:fermix_core, :agent, [])
    )
  end

  @doc """
  Pure variant over explicit provider/agent config keywords — the wizard
  uses it against setup snapshots so runtime routing and setup agree.
  Defaults to `:openai` when nothing was ever chosen.
  """
  @spec primary_in(keyword(), keyword()) ::
          {:ok, ModelCatalog.provider()} | {:error, :multiple_primary}
  def primary_in(providers, agent) do
    case chosen_in(providers, agent) do
      {:ok, nil} -> {:ok, :openai}
      other -> other
    end
  end

  @doc """
  The explicitly chosen provider (primary flag, else legacy
  `agent.provider`) or `nil` when nothing was ever chosen — `nil` is what
  tells setup to still ask the provider question.
  """
  @spec chosen_in(keyword(), keyword()) ::
          {:ok, ModelCatalog.provider() | nil} | {:error, :multiple_primary}
  def chosen_in(providers, agent) do
    case flagged_primaries(providers) do
      [provider] -> {:ok, provider}
      [] -> {:ok, Keyword.get(agent, :provider)}
      [_ | _] -> {:error, :multiple_primary}
    end
  end

  defp flagged_primaries(providers) do
    Enum.filter(ModelCatalog.providers(), fn provider ->
      providers |> Keyword.get(provider, []) |> Keyword.get(:primary, false) == true
    end)
  end
end
