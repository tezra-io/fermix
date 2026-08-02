defmodule FermixCore.Plugins.Dist.Index do
  @moduledoc """
  The plugin catalog index: what the setup page lists before any plugin code is
  fetched. Core ships a **bundled seed** (`priv/plugins/index.json`, inside the
  cosign-verified binary) — the only catalog source. New plugins arrive with
  Fermix releases via `fermix upgrade`; there is no remote refresh.
  """

  @schema_version 1

  # M27 §12 Stage 2: additive per-entry runtime disclosure. `local_stdio` runs
  # the plugin's own process on this machine; `remote_mcp` calls a hosted MCP
  # service. Every entry published before the field exists omits it (`nil`) and
  # keeps the neutral pre-install copy. Unknown values are refused rather than
  # collapsed to neutral: the index ships inside the cosign-verified binary, so
  # a value this core does not understand is a catalog bug, not version skew.
  @runtime_kinds ~w(local_stdio remote_mcp)

  @type artifact :: %{
          target: String.t(),
          url: String.t(),
          sha256: String.t(),
          sig_url: String.t(),
          cert_url: String.t()
        }
  @type version_entry :: %{
          version: String.t(),
          published_at: String.t(),
          min_core_version: String.t() | nil,
          plugin_api: integer() | nil,
          artifacts: [artifact()]
        }
  @type plugin :: %{
          name: String.t(),
          display_name: String.t(),
          category: String.t() | nil,
          description: String.t() | nil,
          logo: map() | nil,
          auth_type: String.t() | nil,
          auth_provider: String.t() | nil,
          runtime_kind: String.t() | nil,
          rails: [String.t()],
          latest: String.t() | nil,
          yanked: [String.t()],
          versions: [version_entry()]
        }
  @type t :: %{schema_version: pos_integer(), generated_at: String.t(), plugins: [plugin()]}

  @doc """
  Load the bundled seed index. Returns `{:error, _}` when the seed is
  unreadable or invalid. The `:seed_path` opt overrides the location (tests).
  """
  @spec load(keyword()) :: {:ok, t()} | {:error, term()}
  def load(opts \\ []) do
    opts
    |> Keyword.get(:seed_path, seed_path())
    |> read_file_index()
  end

  @doc "Find a plugin by name in a loaded index."
  @spec find(t(), String.t()) :: plugin() | nil
  def find(%{plugins: plugins}, name) when is_binary(name),
    do: Enum.find(plugins, &(&1.name == name))

  @doc "Whether `version` of `name` is marked yanked in a loaded index."
  @spec yanked?(t(), String.t(), String.t()) :: boolean()
  def yanked?(index, name, version) when is_binary(name) and is_binary(version) do
    case find(index, name) do
      %{yanked: yanked} -> version in yanked
      _ -> false
    end
  end

  # --- parsing ---

  @doc "Strict-parse a decoded index map. Mirrors `Manifest` discipline: no silent degrade."
  @spec parse(map()) :: {:ok, t()} | {:error, term()}
  def parse(%{"schema_version" => @schema_version, "generated_at" => at, "plugins" => plugins})
      when is_binary(at) and is_list(plugins) do
    {:ok,
     %{schema_version: @schema_version, generated_at: at, plugins: Enum.map(plugins, &plugin/1)}}
  catch
    {tag, _} = reason
    when tag in [:invalid_plugin_entry, :invalid_version_entry, :invalid_artifact_entry] ->
      {:error, reason}
  end

  def parse(%{"schema_version" => other}) when other != @schema_version,
    do: {:error, {:unsupported_index_schema, other}}

  def parse(_other), do: {:error, :index_schema_mismatch}

  defp plugin(%{"name" => name} = p) when is_binary(name) do
    %{
      name: name,
      display_name: Map.get(p, "display_name", name),
      category: Map.get(p, "category"),
      description: Map.get(p, "description"),
      short_description: Map.get(p, "short_description"),
      developer_name: Map.get(p, "developer_name"),
      brand_color: Map.get(p, "brand_color"),
      logo: Map.get(p, "logo"),
      auth_type: Map.get(p, "auth_type"),
      auth_provider: Map.get(p, "auth_provider"),
      runtime_kind: runtime_kind(p),
      rails: Map.get(p, "rails", []),
      latest: Map.get(p, "latest"),
      yanked: Map.get(p, "yanked", []),
      versions: p |> Map.get("versions", []) |> Enum.map(&version_entry/1)
    }
  end

  defp plugin(other), do: throw({:invalid_plugin_entry, other})

  defp runtime_kind(%{"runtime_kind" => kind}) when kind in @runtime_kinds, do: kind
  defp runtime_kind(%{"runtime_kind" => other}), do: throw({:invalid_plugin_entry, other})
  defp runtime_kind(_entry), do: nil

  defp version_entry(%{"version" => version} = v) when is_binary(version) do
    %{
      version: version,
      published_at: Map.get(v, "published_at", ""),
      min_core_version: Map.get(v, "min_core_version"),
      plugin_api: Map.get(v, "plugin_api"),
      artifacts: v |> Map.get("artifacts", []) |> Enum.map(&artifact/1)
    }
  end

  defp version_entry(other), do: throw({:invalid_version_entry, other})

  defp artifact(%{
         "target" => t,
         "url" => u,
         "sha256" => s,
         "sig_url" => sig,
         "cert_url" => cert
       }),
       do: %{target: t, url: u, sha256: s, sig_url: sig, cert_url: cert}

  defp artifact(other), do: throw({:invalid_artifact_entry, other})

  defp read_file_index(path) do
    with {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body) do
      parse(decoded)
    else
      {:error, %Jason.DecodeError{} = err} -> {:error, {:index_invalid_json, err}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp seed_path do
    case :code.priv_dir(:fermix_core) do
      {:error, _} -> Path.expand("apps/fermix_core/priv/plugins/index.json")
      dir -> Path.join([dir, "plugins", "index.json"])
    end
  end
end
