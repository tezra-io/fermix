defmodule FermixCore.Plugins.Registry do
  @moduledoc """
  Loader and validator for plugin manifests: the bundled first-party set under
  `priv/plugins`, unioned with distribution-installed plugins under
  `$FERMIX_HOME/plugins/installed/<name>/current`, unioned with plugin-author
  checkouts under the `[fermix_core.plugins] dev_local` directory. A name may
  never exist in more than one set.
  """

  alias FermixCore.Plugins.Dist.Store, as: DistStore
  alias FermixCore.Plugins.Http.Template
  alias FermixCore.Plugins.Plugin
  alias FermixCore.Setup.ConfigStore

  @manifest_fields ~w(
    schema_version
    name
    display_name
    description
    category
    version
    min_core_version
    plugin_api
    runtime
    default_enabled
    interface
    auth
    config
    tools
    skills
    health_check
  )

  @auth_fields ~w(type provider profile_key account_mode scopes key_name header prompt help_url)
  @config_entry_fields ~w(key prompt required)
  @config_key_regex ~r/^[A-Z][A-Z0-9_]*$/
  @runtime_kinds ~w(node python binary escript)
  @name_regex ~r/^[a-z][a-z0-9_]{0,63}$/
  @tool_name_regex ~r/^[A-Za-z0-9_-]{1,64}$/
  @max_tool_description_bytes 100

  @spec list() :: {:ok, [Plugin.t()]} | {:error, term()}
  def list, do: list([])

  @doc """
  Bundled ∪ installed ∪ dev_local plugins. `opts`:

    * `:installed_root` — plugin store root (default: the workspace plugins
      dir). Injectable so tests run against a tmp store.
    * `:dev_local` — directory whose immediate subdirectories are plugin dirs
      (default: the `[fermix_core.plugins] dev_local` config key). Injectable
      so tests run against a tmp checkout.
  """
  @spec list(keyword()) :: {:ok, [Plugin.t()]} | {:error, term()}
  def list(opts) when is_list(opts) do
    with {:ok, names} <- catalog_names(),
         {:ok, bundled} <- load_plugins(names),
         {:ok, installed} <- load_installed_plugins(installed_root(opts)),
         {:ok, dev_local} <- load_dev_local_plugins(dev_local_root(opts)),
         plugins = bundled ++ installed ++ dev_local,
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
  def enabled_skill_dirs, do: enabled_skill_dirs([])

  @spec enabled_skill_dirs(keyword()) :: [Path.t()]
  def enabled_skill_dirs(opts) when is_list(opts) do
    enabled = enabled_plugin_names()

    case list(opts) do
      {:ok, plugins} ->
        plugins
        |> Enum.filter(&(&1.name in enabled))
        |> Enum.flat_map(&plugin_skill_dirs/1)
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
         {:ok, config} <- decode_config(Map.get(manifest, "config")),
         plugin <- %Plugin{
           schema_version: Map.get(manifest, "schema_version", 1),
           name: name,
           display_name: required_string!(manifest, "display_name"),
           description: required_string!(manifest, "description"),
           category: required_string!(manifest, "category"),
           version: required_string!(manifest, "version"),
           min_core_version: Map.get(manifest, "min_core_version"),
           plugin_api: Map.get(manifest, "plugin_api"),
           runtime: Map.get(manifest, "runtime"),
           default_enabled?: Map.get(manifest, "default_enabled", false) == true,
           interface: Map.get(manifest, "interface", %{}),
           auth: auth,
           config: config,
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

  @doc "Names of the plugins bundled with this Fermix build (the priv catalog)."
  @spec bundled_names() :: {:ok, [String.t()]} | {:error, term()}
  def bundled_names, do: catalog_names()

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

  defp installed_root(opts) do
    Keyword.get(opts, :installed_root) || ConfigStore.workspace_paths().plugins
  end

  # Installed plugins read through `installed/<name>/current/plugin.json`.
  # Incompatible entries (plugin_api window / min_core_version, §13) are
  # excluded, not fatal — an upgrade that moved the support window must not
  # take the whole registry down. A `:ready` entry whose manifest is missing
  # or invalid IS fatal: the store is corrupt, fail loud.
  defp load_installed_plugins(root) do
    root
    |> DistStore.list()
    |> Enum.filter(&(&1.status == :ready))
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case load_installed_plugin(root, entry.name) do
        {:ok, plugin} -> {:cont, {:ok, [plugin | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp load_installed_plugin(root, name) do
    path = Path.join(DistStore.current_link(root, name), "plugin.json")

    with {:ok, raw} <- read_installed_manifest(path),
         {:ok, manifest} <- Jason.decode(raw),
         {:ok, plugin} <- decode_manifest(manifest, path),
         :ok <- validate_installed_name(name, plugin) do
      {:ok, plugin}
    else
      {:error, %Jason.DecodeError{} = error} -> {:error, {:invalid_json, path, error}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_installed_manifest(path) do
    case File.read(path) do
      {:ok, raw} -> {:ok, raw}
      {:error, reason} -> {:error, {:installed_manifest_unreadable, path, reason}}
    end
  end

  defp validate_installed_name(name, %Plugin{name: name}), do: :ok

  defp validate_installed_name(name, %Plugin{name: plugin_name}),
    do: {:error, {:installed_name_mismatch, name, plugin_name}}

  defp dev_local_root(opts) do
    Keyword.get(opts, :dev_local) || configured_dev_local()
  end

  defp configured_dev_local do
    :fermix_core
    |> Application.get_env(:plugins, [])
    |> Keyword.get(:dev_local)
  end

  # `dev_local` is the plugin-author loop: a configured directory whose
  # immediate subdirectories are plugin dirs (for a fermix-plugins checkout,
  # its `plugins/` directory). Plugins load through the same manifest
  # authority as installed ones; an unreadable root or a bad manifest fails
  # loud — the author wants the error, not a silent skip. No configured path
  # is the only soft case: no dev_local plugins.
  defp load_dev_local_plugins(nil), do: {:ok, []}

  defp load_dev_local_plugins(root) when is_binary(root) do
    case File.ls(root) do
      {:ok, entries} -> load_dev_local_dirs(root, Enum.sort(entries))
      {:error, reason} -> {:error, {:dev_local_unreadable, root, reason}}
    end
  end

  defp load_dev_local_dirs(root, entries) do
    entries
    |> Enum.map(&Path.join(root, &1))
    |> Enum.filter(&File.regular?(Path.join(&1, "plugin.json")))
    |> Enum.reduce_while({:ok, []}, fn dir, {:ok, acc} ->
      case load_dev_local_plugin(dir) do
        {:ok, plugin} -> {:cont, {:ok, [plugin | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp load_dev_local_plugin(dir) do
    path = Path.join(dir, "plugin.json")

    with {:ok, raw} <- File.read(path),
         {:ok, manifest} <- Jason.decode(raw) do
      decode_manifest(manifest, path)
    else
      {:error, %Jason.DecodeError{} = error} -> {:error, {:invalid_json, path, error}}
      {:error, reason} -> {:error, {:dev_local_manifest_unreadable, path, reason}}
    end
  end

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
         scopes: Map.get(auth, "scopes", []),
         key_name: Map.get(auth, "key_name"),
         header: Map.get(auth, "header"),
         prompt: Map.get(auth, "prompt"),
         help_url: Map.get(auth, "help_url")
       }}
    end
  end

  defp decode_auth(_auth), do: {:error, :invalid_auth}

  defp auth_type("none"), do: {:ok, :none}
  defp auth_type("oauth2"), do: {:ok, :oauth2}
  defp auth_type("api_key"), do: {:ok, :api_key}
  defp auth_type(other), do: {:error, {:invalid_auth_type, other}}

  # Optional per-plugin config declarations (M8.1 §4.4): flat key/prompt/
  # required entries, nothing more. Values are collected on Connect and live
  # as plain config under `[fermix_core.plugins.<name>]`, never SecretWriter.
  defp decode_config(nil), do: {:ok, []}

  defp decode_config(entries) when is_list(entries) do
    with {:ok, decoded} <- decode_config_entries(entries) do
      case duplicate_name(Enum.map(decoded, & &1.key)) do
        nil -> {:ok, decoded}
        key -> {:error, {:duplicate_config_key, key}}
      end
    end
  end

  defp decode_config(other), do: {:error, {:invalid_config, other}}

  defp decode_config_entries(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case decode_config_entry(entry) do
        {:ok, decoded} -> {:cont, {:ok, acc ++ [decoded]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp decode_config_entry(%{"key" => key, "prompt" => prompt} = entry)
       when is_binary(key) and is_binary(prompt) and prompt != "" do
    with :ok <- reject_unknown_fields(entry, @config_entry_fields),
         :ok <- validate_config_key(key),
         {:ok, required} <- config_required(Map.get(entry, "required", false)) do
      {:ok, %{key: key, prompt: prompt, required: required}}
    end
  end

  defp decode_config_entry(entry), do: {:error, {:invalid_config_entry, entry}}

  defp validate_config_key(key) do
    if Regex.match?(@config_key_regex, key),
      do: :ok,
      else: {:error, {:invalid_config_key, key}}
  end

  defp config_required(required) when is_boolean(required), do: {:ok, required}
  defp config_required(other), do: {:error, {:invalid_config_required, other}}

  defp validate_catalog_name(name, %Plugin{name: name}), do: :ok

  defp validate_catalog_name(name, %Plugin{name: plugin_name}),
    do: {:error, {:catalog_name_mismatch, name, plugin_name}}

  defp validate_manifest(%Plugin{} = plugin) do
    with :ok <- validate_oauth_health(plugin),
         :ok <- validate_scopes(plugin),
         :ok <- validate_runtime(plugin),
         :ok <- validate_tools(plugin),
         :ok <- validate_skills(plugin) do
      :ok
    end
  end

  # A v2 manifest with any `mcp`-rail tool must declare a runtime block.
  defp validate_runtime(%Plugin{schema_version: v}) when v < 2, do: :ok

  defp validate_runtime(%Plugin{tools: tools, runtime: runtime}) do
    if Enum.any?(tools, &(Map.get(&1, "rail") == "mcp")),
      do: validate_runtime_block(runtime),
      else: :ok
  end

  # `command` is one executable name and `args` a list of strings — never a
  # space-joined string (the stdio transport resolves `command` whole).
  defp validate_runtime_block(%{"kind" => kind, "command" => command} = runtime)
       when kind in @runtime_kinds and is_binary(command) and command != "" do
    args = Map.get(runtime, "args", [])
    vendored = Map.get(runtime, "vendored", false)

    if bare_command?(command) and is_boolean(vendored) and
         is_list(args) and Enum.all?(args, &is_binary/1),
       do: :ok,
       else: {:error, {:invalid_runtime, runtime}}
  end

  defp validate_runtime_block(runtime), do: {:error, {:invalid_runtime, runtime}}

  # `command` is one bare executable name: no whitespace (the stdio transport
  # resolves it whole), and no `/` or `..` so a `vendored: true` command stays
  # inside the artifact's `bin/<target>/` dir instead of escaping via `Path.join`
  # to a host executable like `/bin/sh`.
  defp bare_command?(command) do
    not String.contains?(command, " ") and not String.contains?(command, "/") and
      command not in ["..", "."]
  end

  defp validate_oauth_health(%Plugin{name: name, auth: %{type: :oauth2}, health_check: nil}),
    do: {:error, {:missing_health_check, name}}

  defp validate_oauth_health(_plugin), do: :ok

  defp validate_scopes(%Plugin{auth: %{type: type}}) when type in [:none, :api_key], do: :ok

  # Empty scopes are valid: some providers (Notion) have no scope model.
  defp validate_scopes(%Plugin{name: name, auth: %{scopes: scopes}}) do
    if is_list(scopes) and Enum.all?(scopes, &valid_scope?/1) do
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
    with :ok <- validate_tool_name(name),
         :ok <- validate_tool_namespace(name, plugin_name),
         :ok <- validate_tool_description(tool, name),
         :ok <- validate_tool_rail(plugin, tool) do
      validate_tool_scopes(plugin, tool)
    end
  end

  defp validate_tool(_plugin, tool), do: {:error, {:invalid_tool, tool}}

  # Rail/request validation only applies to schema_version 2 manifests; v1
  # tools have no `rail`/`request` and run through hardcoded dispatch.
  defp validate_tool_rail(%Plugin{schema_version: v}, _tool) when v < 2, do: :ok

  defp validate_tool_rail(_plugin, %{"name" => name} = tool) do
    case Map.get(tool, "rail", "http") do
      "http" -> validate_http_tool(tool, name)
      "mcp" -> :ok
      other -> {:error, {:invalid_tool_rail, name, other}}
    end
  end

  # A declarative tool carries a `request` template (validated here). A tool
  # with no `request` is a composite/hardcoded tool that still runs through
  # `ToolExecutor`'s dispatch during the migration (e.g. the Google MIME/RSVP
  # tools) — allowed, no template to check.
  defp validate_http_tool(tool, name) do
    case Map.get(tool, "request") do
      nil ->
        :ok

      request when is_map(request) ->
        if is_map(Map.get(tool, "parameters")),
          do:
            request
            |> Template.static_validate(declared_param_names(tool))
            |> tag_template_error(name),
          else: {:error, {:missing_tool_parameters, name}}

      _other ->
        {:error, {:invalid_tool_request, name}}
    end
  end

  defp declared_param_names(tool) do
    case get_in(tool, ["parameters", "properties"]) do
      properties when is_map(properties) -> Map.keys(properties)
      _ -> []
    end
  end

  defp tag_template_error(:ok, _name), do: :ok

  defp tag_template_error({:error, reason}, name),
    do: {:error, {:invalid_tool_template, name, reason}}

  defp validate_tool_name(name) do
    if Regex.match?(@tool_name_regex, name),
      do: :ok,
      else: {:error, {:invalid_tool_name, name}}
  end

  defp validate_tool_namespace(name, plugin_name) do
    if String.starts_with?(name, plugin_name <> "_"),
      do: :ok,
      else: {:error, {:tool_name_not_namespaced, name, plugin_name}}
  end

  defp validate_tool_description(%{"description" => description}, name)
       when is_binary(description) do
    description = String.trim(description)

    if description != "" and byte_size(description) <= @max_tool_description_bytes,
      do: :ok,
      else: {:error, {:invalid_tool_description, name}}
  end

  defp validate_tool_description(_tool, name), do: {:error, {:invalid_tool_description, name}}

  # Scope declarations are an OAuth granted-scope concept; `none`/`api_key`
  # plugins declare no scopes.
  defp validate_tool_scopes(%Plugin{auth: %{type: type}}, _tool) when type in [:none, :api_key],
    do: :ok

  # A plugin whose provider has no scope model (scopes: []) must not declare
  # tool scope requirements — there is nothing to grant.
  defp validate_tool_scopes(%Plugin{auth: %{scopes: []}}, %{"name" => name} = tool) do
    case Map.get(tool, "requires_scopes", []) do
      [] -> :ok
      _scopes -> {:error, {:unknown_tool_scopes, name}}
    end
  end

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

  # The asset path comes from the (untrusted) manifest and is later read and
  # inlined into the setup page. Bound it to the plugin dir so `../` can't escape
  # to an arbitrary host file before the read.
  defp validate_asset(plugin_dir, rel_path) when is_binary(rel_path) do
    case Path.safe_relative(rel_path, plugin_dir) do
      {:ok, safe} ->
        path = Path.join(plugin_dir, safe)
        if File.regular?(path), do: :ok, else: {:error, {:missing_asset, path}}

      :error ->
        {:error, {:asset_escapes_plugin_dir, rel_path}}
    end
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

  # Bundled plugins copy-seed their skills into the workspace (the workspace
  # copy is the user-editable one). Installed plugins load skills in place from
  # `installed/<name>/current/skills` — that tree is already user-space and
  # versioned; copying would fork it (§8.4).
  defp plugin_skill_dirs(%Plugin{skills: []}), do: []

  defp plugin_skill_dirs(%Plugin{} = plugin) do
    if bundled?(plugin),
      do: seeded_plugin_skill_dirs(plugin),
      else: [plugin.path |> Path.dirname() |> Path.join("skills")]
  end

  defp bundled?(%Plugin{path: path}), do: String.starts_with?(path, priv_plugins_dir())

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
