defmodule FermixCore.Plugins.Registry do
  @moduledoc """
  Loader and validator for bundled first-party plugin manifests.
  """

  alias FermixCore.Plugins.Plugin
  alias FermixCore.Setup.ConfigStore

  @manifest_fields ~w(
    schema_version
    name
    display_name
    description
    category
    version
    default_enabled
    interface
    auth
    tools
    skills
    health_check
  )

  @auth_fields ~w(type provider profile_key account_mode scopes)
  @name_regex ~r/^[a-z][a-z0-9_]{0,63}$/

  @spec list() :: {:ok, [Plugin.t()]} | {:error, term()}
  def list do
    with {:ok, names} <- catalog_names(),
         {:ok, plugins} <- load_plugins(names),
         :ok <- validate_catalog_collisions(plugins) do
      {:ok, Enum.sort_by(plugins, & &1.name)}
    end
  end

  @spec find(String.t()) :: {:ok, Plugin.t()} | :error | {:error, term()}
  def find(name) when is_binary(name) do
    case list() do
      {:ok, plugins} ->
        case Enum.find(plugins, &(&1.name == name)) do
          nil -> :error
          plugin -> {:ok, plugin}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec enabled_skill_dirs() :: [Path.t()]
  def enabled_skill_dirs do
    enabled = enabled_plugin_names()

    case list() do
      {:ok, plugins} ->
        plugins
        |> Enum.filter(&(&1.name in enabled))
        |> Enum.flat_map(&seeded_plugin_skill_dirs/1)
        |> Enum.uniq()
        |> Enum.sort()

      {:error, _reason} ->
        []
    end
  end

  @spec decode_manifest(map(), Path.t()) :: {:ok, Plugin.t()} | {:error, term()}
  def decode_manifest(%{} = manifest, path) when is_binary(path) do
    with :ok <- reject_unknown_fields(manifest, @manifest_fields),
         {:ok, name} <- required_string(manifest, "name"),
         :ok <- validate_name(name),
         {:ok, auth} <- decode_auth(Map.get(manifest, "auth", %{})),
         plugin <- %Plugin{
           schema_version: Map.get(manifest, "schema_version", 1),
           name: name,
           display_name: required_string!(manifest, "display_name"),
           description: required_string!(manifest, "description"),
           category: required_string!(manifest, "category"),
           version: required_string!(manifest, "version"),
           default_enabled?: Map.get(manifest, "default_enabled", false) == true,
           interface: Map.get(manifest, "interface", %{}),
           auth: auth,
           tools: Map.get(manifest, "tools", []),
           skills: Map.get(manifest, "skills", []),
           health_check: Map.get(manifest, "health_check"),
           path: path
         },
         :ok <- validate_manifest(plugin),
         :ok <- validate_assets(plugin) do
      {:ok, plugin}
    end
  rescue
    error in ArgumentError -> {:error, {:invalid_manifest, path, Exception.message(error)}}
  end

  def decode_manifest(_manifest, path), do: {:error, {:invalid_manifest, path, :not_a_map}}

  @spec priv_plugins_dir() :: Path.t()
  def priv_plugins_dir do
    case :code.priv_dir(:fermix_core) do
      {:error, :bad_name} -> Path.expand("apps/fermix_core/priv/plugins")
      path -> Path.join(to_string(path), "plugins")
    end
  end

  defp catalog_names do
    catalog_path = Path.join(priv_plugins_dir(), "catalog.json")

    with {:ok, raw} <- File.read(catalog_path),
         {:ok, %{"plugins" => names}} when is_list(names) <- Jason.decode(raw) do
      {:ok, names}
    else
      {:ok, _other} -> {:error, {:invalid_catalog, catalog_path}}
      {:error, reason} -> {:error, {:catalog_read_failed, catalog_path, reason}}
    end
  end

  defp load_plugins(names) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, acc} ->
      case load_plugin(name) do
        {:ok, plugin} -> {:cont, {:ok, [plugin | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp load_plugin(name) when is_binary(name) do
    path = Path.join([priv_plugins_dir(), name, "plugin.json"])

    with {:ok, raw} <- File.read(path),
         {:ok, manifest} <- Jason.decode(raw),
         {:ok, plugin} <- decode_manifest(manifest, path),
         :ok <- validate_catalog_name(name, plugin) do
      {:ok, plugin}
    else
      {:error, %Jason.DecodeError{} = error} -> {:error, {:invalid_json, path, error}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_plugin(name), do: {:error, {:invalid_catalog_name, name}}

  defp reject_unknown_fields(manifest, allowed) do
    unknown =
      manifest
      |> Map.keys()
      |> Enum.reject(&(&1 in allowed))
      |> Enum.sort()

    if unknown == [], do: :ok, else: {:error, {:unknown_fields, unknown}}
  end

  defp decode_auth(%{} = auth) do
    with :ok <- reject_unknown_fields(auth, @auth_fields),
         {:ok, type} <- auth_type(Map.get(auth, "type")) do
      {:ok,
       %{
         type: type,
         provider: Map.get(auth, "provider"),
         profile_key: Map.get(auth, "profile_key"),
         account_mode: Map.get(auth, "account_mode"),
         scopes: Map.get(auth, "scopes", [])
       }}
    end
  end

  defp decode_auth(_auth), do: {:error, :invalid_auth}

  defp auth_type("none"), do: {:ok, :none}
  defp auth_type("oauth2"), do: {:ok, :oauth2}
  defp auth_type(other), do: {:error, {:invalid_auth_type, other}}

  defp validate_catalog_name(name, %Plugin{name: name}), do: :ok

  defp validate_catalog_name(name, %Plugin{name: plugin_name}),
    do: {:error, {:catalog_name_mismatch, name, plugin_name}}

  defp validate_manifest(%Plugin{} = plugin) do
    with :ok <- validate_oauth_health(plugin),
         :ok <- validate_scopes(plugin),
         :ok <- validate_tools(plugin),
         :ok <- validate_skills(plugin) do
      :ok
    end
  end

  defp validate_oauth_health(%Plugin{name: name, auth: %{type: :oauth2}, health_check: nil}),
    do: {:error, {:missing_health_check, name}}

  defp validate_oauth_health(_plugin), do: :ok

  defp validate_scopes(%Plugin{auth: %{type: :none}}), do: :ok

  defp validate_scopes(%Plugin{name: name, auth: %{scopes: scopes}}) do
    if is_list(scopes) and scopes != [] and Enum.all?(scopes, &valid_scope?/1) do
      :ok
    else
      {:error, {:invalid_scopes, name}}
    end
  end

  defp valid_scope?(scope), do: is_binary(scope) and scope != ""

  defp validate_tools(%Plugin{} = plugin) do
    case reject_duplicate_names(plugin.tools, "name", :duplicate_tool_name) do
      :ok -> validate_tool_list(plugin, plugin.tools)
      {:error, _reason} = err -> err
    end
  end

  defp validate_tool_list(plugin, tools) do
    Enum.reduce_while(tools, :ok, fn tool, :ok ->
      validate_tool(plugin, tool) |> continue_or_halt()
    end)
  end

  defp validate_tool(%Plugin{name: plugin_name} = plugin, %{"name" => name} = tool)
       when is_binary(name) do
    if String.starts_with?(name, plugin_name <> ".") do
      validate_tool_scopes(plugin, tool)
    else
      {:error, {:tool_name_not_namespaced, name, plugin_name}}
    end
  end

  defp validate_tool(_plugin, tool), do: {:error, {:invalid_tool, tool}}

  defp validate_tool_scopes(%Plugin{auth: %{type: :none}}, _tool), do: :ok

  defp validate_tool_scopes(%Plugin{auth: %{scopes: scopes}}, %{"name" => name} = tool) do
    required = Map.get(tool, "requires_scopes", [])

    cond do
      not (is_list(required) and required != [] and Enum.all?(required, &valid_scope?/1)) ->
        {:error, {:missing_tool_scopes, name}}

      not MapSet.subset?(MapSet.new(required), MapSet.new(scopes)) ->
        {:error, {:unknown_tool_scopes, name}}

      true ->
        :ok
    end
  end

  defp validate_skills(%Plugin{} = plugin) do
    case reject_duplicate_names(plugin.skills, "name", :duplicate_skill_name) do
      :ok -> validate_skill_list(plugin, plugin.skills)
      {:error, _reason} = err -> err
    end
  end

  defp validate_skill_list(plugin, skills) do
    Enum.reduce_while(skills, :ok, fn skill, :ok ->
      validate_skill(plugin, skill) |> continue_or_halt()
    end)
  end

  defp validate_skill(%Plugin{name: name}, %{"name" => name}),
    do: {:error, {:plugin_skill_name_collision, name}}

  defp validate_skill(_plugin, %{"name" => name, "path" => path})
       when is_binary(name) and is_binary(path),
       do: :ok

  defp validate_skill(_plugin, skill), do: {:error, {:invalid_skill, skill}}

  defp validate_assets(%Plugin{} = plugin) do
    plugin_dir = Path.dirname(plugin.path)
    icon = Map.get(plugin.interface, "icon")
    logo = Map.get(plugin.interface, "logo")

    with :ok <- validate_asset(plugin_dir, icon),
         :ok <- validate_asset(plugin_dir, logo) do
      :ok
    end
  end

  defp validate_asset(_plugin_dir, nil), do: :ok

  defp validate_asset(plugin_dir, rel_path) when is_binary(rel_path) do
    path = Path.join(plugin_dir, rel_path)
    if File.regular?(path), do: :ok, else: {:error, {:missing_asset, path}}
  end

  defp validate_name(name) when is_binary(name) do
    if Regex.match?(@name_regex, name), do: :ok, else: {:error, {:invalid_name, name}}
  end

  defp continue_or_halt(:ok), do: {:cont, :ok}
  defp continue_or_halt({:error, reason}), do: {:halt, {:error, reason}}

  defp reject_duplicate_names(items, key, tag) do
    items
    |> Enum.map(&Map.get(&1, key))
    |> Enum.filter(&is_binary/1)
    |> duplicate_name()
    |> case do
      nil -> :ok
      name -> {:error, {tag, name}}
    end
  end

  defp duplicate_name(names) do
    Enum.reduce_while(names, MapSet.new(), fn name, seen ->
      if MapSet.member?(seen, name) do
        {:halt, name}
      else
        {:cont, MapSet.put(seen, name)}
      end
    end)
    |> case do
      %MapSet{} -> nil
      name -> name
    end
  end

  defp validate_catalog_collisions(plugins) do
    with :ok <- reject_catalog_duplicates(plugins, & &1.name, :duplicate_plugin_name),
         :ok <- reject_catalog_duplicates(plugins, &tool_names/1, :duplicate_tool_name),
         :ok <- reject_catalog_duplicates(plugins, &skill_names/1, :duplicate_skill_name) do
      reject_plugin_skill_collisions(plugins)
    end
  end

  defp reject_catalog_duplicates(items, mapper, tag) do
    items
    |> Enum.flat_map(fn item ->
      case mapper.(item) do
        values when is_list(values) -> values
        value -> [value]
      end
    end)
    |> Enum.filter(&is_binary/1)
    |> duplicate_name()
    |> case do
      nil -> :ok
      name -> {:error, {tag, name}}
    end
  end

  defp reject_plugin_skill_collisions(plugins) do
    plugin_names = plugins |> Enum.map(& &1.name) |> MapSet.new()

    plugins
    |> Enum.flat_map(&skill_names/1)
    |> Enum.find(&MapSet.member?(plugin_names, &1))
    |> case do
      nil -> :ok
      name -> {:error, {:plugin_skill_name_collision, name}}
    end
  end

  defp tool_names(%Plugin{tools: tools}), do: tools |> Enum.map(&Map.get(&1, "name"))
  defp skill_names(%Plugin{skills: skills}), do: skills |> Enum.map(&Map.get(&1, "name"))

  defp seeded_plugin_skill_dirs(%Plugin{skills: []}), do: []

  defp seeded_plugin_skill_dirs(%Plugin{} = plugin) do
    seed_plugin_skills(plugin)
    [workspace_plugin_skills_dir(plugin)]
  end

  defp seed_plugin_skills(plugin) do
    source = source_plugin_skills_dir(plugin)
    target = workspace_plugin_skills_dir(plugin)

    cond do
      File.dir?(target) ->
        :ok

      File.exists?(target) ->
        raise ArgumentError, "plugin skill target exists but is not a directory: #{target}"

      true ->
        File.mkdir_p!(Path.dirname(target))
        File.cp_r!(source, target)
        :ok
    end
  end

  defp source_plugin_skills_dir(%Plugin{} = plugin) do
    plugin.path |> Path.dirname() |> Path.join("skills")
  end

  defp workspace_plugin_skills_dir(%Plugin{name: name}) do
    Path.join([ConfigStore.workspace_paths().plugins, name, "skills"])
  end

  defp enabled_plugin_names do
    :fermix_core
    |> Application.get_env(:plugins, [])
    |> Keyword.get(:enabled, [])
    |> Enum.filter(&is_binary/1)
  end

  defp required_string(manifest, key) do
    case Map.get(manifest, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, {:missing_required, key}}
    end
  end

  defp required_string!(manifest, key) do
    case required_string(manifest, key) do
      {:ok, value} -> value
      {:error, reason} -> raise ArgumentError, inspect(reason)
    end
  end
end
