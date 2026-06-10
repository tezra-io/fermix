defmodule FermixCore.Plugins.Catalog do
  @moduledoc """
  The setup page's catalog view (M8 §6/§11): registry plugins (bundled ∪
  installed) unioned with the not-yet-installed remainder of the distribution
  index, each available entry carrying the branding and pre-fetch compat
  verdict the card grid needs before any artifact is downloaded. Read-only —
  installing and enabling stay with `Dist.Installer` / `Plugins.Config`.
  """

  alias FermixCore.Plugins.Dist.Index
  alias FermixCore.Plugins.Dist.Store
  alias FermixCore.Plugins.Plugin
  alias FermixCore.Plugins.Registry
  alias FermixCore.Setup.ConfigStore

  @auth_types %{"none" => :none, "oauth2" => :oauth2, "api_key" => :api_key}

  @type available :: %{
          name: String.t(),
          display_name: String.t(),
          description: String.t() | nil,
          category: String.t() | nil,
          auth_type: :none | :oauth2 | :api_key | nil,
          provider: String.t() | nil,
          rails: [String.t()],
          logo: map() | nil,
          latest: String.t() | nil,
          compat: :ok | {:error, term()}
        }

  @type overview :: %{
          installed: [Plugin.t()],
          available: [available()],
          yanked_installed: %{optional(String.t()) => String.t()},
          index_error: term() | nil
        }

  @doc """
  Build the union view. Opts follow the `:plugins_dist_opts` seam shape:
  `:root` (plugin store root), `:index_opts`, `:core_version`.

  Fails only when the registry itself fails. An unreadable index degrades to
  `available: []` with the reason surfaced in `:index_error` — the page must
  still manage installed plugins offline.
  """
  @spec overview(keyword()) :: {:ok, overview()} | {:error, term()}
  def overview(opts \\ []) when is_list(opts) do
    with {:ok, plugins} <- Registry.list(registry_opts(opts)) do
      index_opts = Keyword.get(opts, :index_opts, [])
      {:ok, build_overview(plugins, Index.load(index_opts), opts)}
    end
  end

  defp build_overview(plugins, {:ok, index}, opts) do
    %{
      installed: plugins,
      available: available_entries(index, plugins, opts),
      yanked_installed: yanked_installed(index, opts),
      index_error: nil
    }
  end

  defp build_overview(plugins, {:error, reason}, _opts) do
    %{
      installed: plugins,
      available: [],
      yanked_installed: %{},
      index_error: reason
    }
  end

  defp registry_opts(opts) do
    case Keyword.get(opts, :root) do
      nil -> []
      root -> [installed_root: root]
    end
  end

  defp available_entries(index, plugins, opts) do
    known = MapSet.new(plugins, & &1.name)

    index.plugins
    |> Enum.reject(&MapSet.member?(known, &1.name))
    |> Enum.map(&available_entry(&1, opts))
  end

  defp available_entry(plugin, opts) do
    %{
      name: plugin.name,
      display_name: plugin.display_name,
      description: plugin.description,
      category: plugin.category,
      auth_type: Map.get(@auth_types, plugin.auth_type),
      provider: plugin.auth_provider,
      rails: plugin.rails,
      logo: plugin.logo,
      latest: plugin.latest,
      compat: compat(plugin, opts)
    }
  end

  # The card verdict for the not-yet-fetched latest version (§13, pre-fetch):
  # a yanked or absent latest is a compat error too — same greyed rendering.
  defp compat(plugin, opts) do
    cond do
      plugin.latest == nil -> {:error, {:version_not_found, plugin.name, nil}}
      plugin.latest in plugin.yanked -> {:error, {:yanked, plugin.name, plugin.latest}}
      true -> latest_compat(plugin, opts)
    end
  end

  defp latest_compat(plugin, opts) do
    core = Keyword.get_lazy(opts, :core_version, &Store.core_version/0)

    case Enum.find(plugin.versions, &(&1.version == plugin.latest)) do
      nil -> {:error, {:version_not_found, plugin.name, plugin.latest}}
      entry -> Store.compatible?(entry, core)
    end
  end

  # Installed versions marked yanked in the index (§6): surfaced loud on the
  # card, never auto-disabled — no remote kill switch over a running daemon.
  defp yanked_installed(index, opts) do
    root = Keyword.get(opts, :root) || ConfigStore.workspace_paths().plugins

    root
    |> Store.installed()
    |> Enum.reduce(%{}, fn {name, entry}, acc ->
      version = Map.get(entry, "version")
      if Index.yanked?(index, name, version), do: Map.put(acc, name, version), else: acc
    end)
  end
end
