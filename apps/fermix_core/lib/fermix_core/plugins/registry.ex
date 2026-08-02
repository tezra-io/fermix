defmodule FermixCore.Plugins.Registry do
  @moduledoc """
  Loader and validator for plugin manifests: the bundled first-party set under
  `priv/plugins`, unioned with distribution-installed plugins under
  `$FERMIX_HOME/plugins/installed/<name>/current`, unioned with plugin-author
  checkouts under the `[fermix_core.plugins] dev_local` directory. A name may
  never exist in more than one set.
  """

  alias FermixCore.Capabilities.MCP.Remote.AuthRef
  alias FermixCore.Capabilities.MCP.Remote.Endpoint
  alias FermixCore.Plugins.CanonicalJson
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

  @auth_fields ~w(type provider profile_key account_mode scopes key_name header scheme prompt help_url validation)
  @auth_schemes ~w(Bearer Bot)
  @config_entry_fields ~w(key prompt required)
  @config_key_regex ~r/^[A-Z][A-Z0-9_]*$/
  @runtime_kinds ~w(node python binary escript)
  @name_regex ~r/^[a-z][a-z0-9_]{0,63}$/
  @tool_name_regex ~r/^[A-Za-z0-9_-]{1,64}$/
  @max_tool_description_bytes 100

  # --- plugin-api 3 (M27 §7.1): a version-conditional additive extension. An
  # api-2 manifest carrying any of the grammar below is REFUSED, never parsed
  # under old semantics, so the meaning of a shipped manifest cannot drift.
  @api3 3
  @api3_manifest_fields ~w(tool_profiles setup_tools resource_scope budgets result_contract)
  @all_manifest_fields @manifest_fields ++ @api3_manifest_fields
  # `policy_class`, `read_only`, `rail`, and `parameters` are NOT listed: shipped
  # api-2 manifests already declare them, so they carry api-2 meaning too.
  @api3_tool_fields ~w(
    replay_safe required_credential_scope collection_policy
    argument_guards output_schema upstream_annotations descriptor_sha256
  )

  @auth_validation_fields ~w(prefix min_bytes max_bytes charset forbid_whitespace)
  @auth_validation_charset "visible_ascii"

  @remote_runtime_kind "remote_mcp"
  @remote_runtime_fields ~w(kind transport protocol_version base_url mcp_path tool_name_mode)
  @local_runtime_fields ~w(command args env pass_env cwd vendored min_version)
  @remote_transport "streamable_http"
  @remote_protocol_version "2025-06-18"
  @tool_name_modes ~w(prefix preserve)

  @tool_profile_fields ~w(name display_name default required_credential_scope scope_visibility tools)
  @profile_name_regex ~r/^[a-z][a-z0-9_]*$/
  @credential_scopes ~w(read write)
  @scope_visibilities ~w(none all_scoped_tools_omitted)

  @resource_scope_fields ~w(kind discovery_tool id_field label_field argument)
  @resource_scope_kinds ~w(single_workspace)
  @budget_fields ~w(agent_turn_calls agent_turn_paginated_calls)
  @max_budget_calls 100
  @result_contract_fields ~w(kind success_field status_field message_field)
  @result_contract_kinds ~w(json_boolean)

  @remote_tool_fields ~w(
    name description policy_class read_only replay_safe required_credential_scope rail
    parameters output_schema upstream_annotations descriptor_sha256 collection_policy argument_guards
  )
  @policy_classes ~w(external_api)
  @descriptor_sha256_regex ~r/^[0-9a-f]{64}$/
  @collection_policy_fields ~w(
    paginated request_limit_pointer default_limit result_items_pointer max_returned_items
  )
  @max_collection_items 100
  @limit_schema_types ~w(integer number)
  @argument_guard_fields ~w(pointer kind max_items)
  @argument_guard_kinds ~w(public_http_url_array bounded_visible_ascii_array)
  @max_guard_items 100
  @max_pointer_segments 8

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
    with :ok <- reject_unknown_fields(manifest, @all_manifest_fields),
         {:ok, schema_version} <- decode_schema_version(Map.get(manifest, "schema_version", 1)),
         {:ok, plugin_api} <- decode_plugin_api(Map.get(manifest, "plugin_api")),
         :ok <- reject_api3_manifest_fields(manifest, plugin_api),
         {:ok, name} <- required_string(manifest, "name"),
         :ok <- validate_name(name),
         {:ok, auth} <- decode_auth(Map.get(manifest, "auth", %{}), plugin_api),
         {:ok, config} <- decode_config(Map.get(manifest, "config")),
         plugin <- %Plugin{
           schema_version: schema_version,
           name: name,
           display_name: required_string!(manifest, "display_name"),
           description: required_string!(manifest, "description"),
           category: required_string!(manifest, "category"),
           version: required_string!(manifest, "version"),
           min_core_version: Map.get(manifest, "min_core_version"),
           plugin_api: plugin_api,
           runtime: Map.get(manifest, "runtime"),
           default_enabled?: Map.get(manifest, "default_enabled", false) == true,
           interface: Map.get(manifest, "interface", %{}),
           auth: auth,
           config: config,
           tools: Map.get(manifest, "tools", []),
           skills: Map.get(manifest, "skills", []),
           tool_profiles: Map.get(manifest, "tool_profiles", []),
           setup_tools: Map.get(manifest, "setup_tools", []),
           resource_scope: Map.get(manifest, "resource_scope"),
           budgets: Map.get(manifest, "budgets"),
           result_contract: Map.get(manifest, "result_contract"),
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

  defp decode_auth(%{} = auth, plugin_api) do
    with :ok <- reject_unknown_fields(auth, @auth_fields),
         {:ok, type} <- auth_type(Map.get(auth, "type")),
         {:ok, scheme} <- auth_scheme(Map.get(auth, "scheme")),
         {:ok, validation} <- decode_auth_validation(Map.get(auth, "validation"), plugin_api) do
      {:ok,
       %{
         type: type,
         provider: Map.get(auth, "provider"),
         profile_key: Map.get(auth, "profile_key"),
         account_mode: Map.get(auth, "account_mode"),
         scopes: Map.get(auth, "scopes", []),
         key_name: Map.get(auth, "key_name"),
         header: Map.get(auth, "header"),
         scheme: scheme,
         prompt: Map.get(auth, "prompt"),
         help_url: Map.get(auth, "help_url"),
         validation: validation
       }}
    end
  end

  defp decode_auth(_auth, _plugin_api), do: {:error, :invalid_auth}

  defp auth_type("none"), do: {:ok, :none}
  defp auth_type("oauth2"), do: {:ok, :oauth2}
  defp auth_type("api_key"), do: {:ok, :api_key}
  defp auth_type(other), do: {:error, {:invalid_auth_type, other}}

  # The `Authorization` scheme prefix (e.g. `Bot <token>` for Discord). Absent
  # defaults to `Bearer` at injection time; an unknown scheme is rejected at
  # decode so no manifest can inject an arbitrary header prefix.
  defp auth_scheme(nil), do: {:ok, nil}
  defp auth_scheme(scheme) when scheme in @auth_schemes, do: {:ok, scheme}
  defp auth_scheme(other), do: {:error, {:invalid_auth_scheme, other}}

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
    # The version gate runs before the runtime block so an api-2 manifest that
    # declares a `remote_mcp` runtime hears "needs plugin_api 3" rather than the
    # stdio validator's generic `:invalid_runtime`.
    with :ok <- validate_oauth_health(plugin),
         :ok <- validate_scopes(plugin),
         :ok <- validate_api3(plugin),
         :ok <- validate_runtime(plugin),
         :ok <- validate_tools(plugin),
         :ok <- validate_skills(plugin) do
      :ok
    end
  end

  # A `remote_mcp` runtime has no local process: the stdio block rules below do
  # not apply to it and `validate_api3/1` owns its grammar (§7.2 rule 1).
  defp validate_runtime(%Plugin{plugin_api: @api3, runtime: %{"kind" => @remote_runtime_kind}}),
    do: :ok

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

  # --- plugin-api 3 grammar (M27 §7.1, §7.2, §7.5, §7.6, §7.7, §8.1) --------

  # M8 §5.2: refuse an unknown MAJOR rather than treating it as the newest one
  # we know. Every `schema_version` branch below is written as `v < 2`, so a
  # future `3` would have silently inherited v2 semantics — a manifest built
  # against a grammar this core has never seen, validated by the wrong rules.
  # The refusal lands at decode so an already-INSTALLED manifest is refused too,
  # not just a fresh install.
  defp decode_schema_version(version) when version in [1, 2], do: {:ok, version}
  defp decode_schema_version(version), do: {:error, {:unsupported_schema_version, version}}

  defp decode_plugin_api(nil), do: {:ok, nil}
  defp decode_plugin_api(api) when is_integer(api) and api > 0, do: {:ok, api}
  defp decode_plugin_api(other), do: {:error, {:invalid_plugin_api, other}}

  # The root api-3 blocks are in the manifest allowlist so an api-2 manifest
  # that carries one gets THIS answer ("needs api 3") rather than a generic
  # unknown-field error that reads like a typo.
  defp reject_api3_manifest_fields(_manifest, @api3), do: :ok

  defp reject_api3_manifest_fields(manifest, _plugin_api) do
    @api3_manifest_fields
    |> Enum.filter(&Map.has_key?(manifest, &1))
    |> requires_api3()
  end

  defp requires_api3([]), do: :ok
  defp requires_api3(fields), do: {:error, {:requires_plugin_api_3, Enum.sort(fields)}}

  defp decode_auth_validation(nil, _plugin_api), do: {:ok, nil}

  defp decode_auth_validation(_block, plugin_api) when plugin_api != @api3,
    do: requires_api3(["auth.validation"])

  # Bounded and declarative only: a literal prefix, byte bounds, one fixed
  # charset, and a whitespace prohibition. No regex, no executable validator
  # (§7.5) — a manifest may not ship credential-checking logic.
  defp decode_auth_validation(%{} = block, @api3) do
    tag = :invalid_auth_validation

    with :ok <- reject_unknown_fields(block, @auth_validation_fields),
         {:ok, prefix} <- nonempty_string(block, "prefix", tag),
         {:ok, min_bytes} <- positive_integer(block, "min_bytes", tag),
         {:ok, max_bytes} <- positive_integer(block, "max_bytes", tag),
         :ok <- check(min_bytes <= max_bytes, {tag, "min_bytes", min_bytes}),
         {:ok, charset} <- enum_field(block, "charset", [@auth_validation_charset], tag),
         {:ok, forbid} <- boolean_field(block, "forbid_whitespace", tag) do
      {:ok,
       %{
         prefix: prefix,
         min_bytes: min_bytes,
         max_bytes: max_bytes,
         charset: charset,
         forbid_whitespace: forbid
       }}
    end
  end

  defp decode_auth_validation(other, @api3),
    do: {:error, {:invalid_auth_validation, "auth", other}}

  defp validate_api3(%Plugin{plugin_api: @api3, schema_version: 2} = plugin),
    do: validate_api3_grammar(plugin)

  defp validate_api3(%Plugin{plugin_api: @api3, schema_version: version}),
    do: {:error, {:invalid_plugin_api_3_schema_version, version}}

  defp validate_api3(%Plugin{runtime: runtime, tools: tools}) do
    with :ok <- reject_api3_runtime(runtime) do
      tools |> api3_tool_fields() |> requires_api3()
    end
  end

  defp validate_api3_grammar(%Plugin{runtime: %{"kind" => @remote_runtime_kind}} = plugin),
    do: validate_remote_contract(plugin)

  defp validate_api3_grammar(%Plugin{} = plugin) do
    with :ok <- reject_remote_only_fields(plugin) do
      validate_local_tool_name_mode(plugin.runtime)
    end
  end

  defp reject_api3_runtime(%{} = runtime) do
    cond do
      Map.get(runtime, "kind") == @remote_runtime_kind ->
        requires_api3(["runtime.kind=#{@remote_runtime_kind}"])

      Map.has_key?(runtime, "tool_name_mode") ->
        requires_api3(["runtime.tool_name_mode"])

      true ->
        :ok
    end
  end

  defp reject_api3_runtime(_runtime), do: :ok

  defp api3_tool_fields(tools) when is_list(tools) do
    tools
    |> Enum.filter(&is_map/1)
    |> Enum.flat_map(fn tool -> Enum.filter(@api3_tool_fields, &Map.has_key?(tool, &1)) end)
    |> Enum.uniq()
  end

  defp api3_tool_fields(_tools), do: []

  # The signed-allowlist blocks describe a hosted MCP service. A local api-3
  # runtime has no remote contract to sign, so carrying them is a manifest bug,
  # not an unused option.
  defp reject_remote_only_fields(%Plugin{} = plugin) do
    present =
      [
        {"tool_profiles", plugin.tool_profiles != []},
        {"setup_tools", plugin.setup_tools != []},
        {"resource_scope", plugin.resource_scope != nil},
        {"budgets", plugin.budgets != nil},
        {"result_contract", plugin.result_contract != nil}
      ]
      |> Enum.filter(fn {_field, present?} -> present? end)
      |> Enum.map(fn {field, _present?} -> field end)
      |> Enum.concat(api3_tool_fields(plugin.tools))

    if present == [], do: :ok, else: {:error, {:remote_only_fields, Enum.sort(present)}}
  end

  defp validate_local_tool_name_mode(%{} = runtime) do
    case Map.get(runtime, "tool_name_mode") do
      nil -> :ok
      "prefix" -> :ok
      other -> {:error, {:invalid_tool_name_mode, other}}
    end
  end

  defp validate_local_tool_name_mode(_runtime), do: :ok

  defp validate_remote_contract(%Plugin{} = plugin) do
    with :ok <- validate_remote_runtime(plugin),
         {:ok, _auth_ref} <- AuthRef.from_auth(plugin.auth, plugin.name),
         {:ok, profiles} <- decode_tool_profiles(plugin.tool_profiles),
         {:ok, setup_tools} <- decode_setup_tools(plugin.setup_tools),
         :ok <- validate_budgets(plugin.budgets),
         :ok <- validate_result_contract(plugin.result_contract),
         :ok <- validate_remote_tools(plugin.tools),
         :ok <- validate_profile_membership(plugin.tools, profiles, setup_tools) do
      validate_resource_scope(plugin, profiles, setup_tools)
    end
  end

  # `kind: remote_mcp` is mutually exclusive with every local-process field
  # (§7.2 rule 1): a half-local/half-remote spec has no single meaning, so it is
  # refused rather than resolved in favour of one half.
  defp validate_remote_runtime(%Plugin{name: name, runtime: runtime, tools: tools}) do
    tag = :invalid_remote_runtime

    with :ok <- reject_local_runtime_fields(runtime),
         :ok <- reject_unknown_fields(runtime, @remote_runtime_fields),
         {:ok, _transport} <- enum_field(runtime, "transport", [@remote_transport], tag),
         {:ok, _version} <-
           enum_field(runtime, "protocol_version", [@remote_protocol_version], tag),
         {:ok, mode} <- enum_field(runtime, "tool_name_mode", @tool_name_modes, tag),
         {:ok, _endpoint} <-
           Endpoint.new(Map.get(runtime, "base_url"), Map.get(runtime, "mcp_path")) do
      validate_preserved_names(mode, name, tools)
    end
  end

  defp reject_local_runtime_fields(runtime) do
    case Enum.filter(@local_runtime_fields, &Map.has_key?(runtime, &1)) do
      [] -> :ok
      present -> {:error, {:remote_runtime_conflict, Enum.sort(present)}}
    end
  end

  # In preserve mode the upstream name IS the final capability name, so the
  # `<plugin>_` namespace has to already be there — Fermix does not hash-rename
  # or omit a colliding declared remote tool (§7.7).
  defp validate_preserved_names("prefix", _plugin_name, _tools), do: :ok

  defp validate_preserved_names("preserve", plugin_name, tools) when is_list(tools) do
    prefix = plugin_name <> "_"

    case Enum.find(tools, &(not preserved_name?(&1, prefix))) do
      nil -> :ok
      tool -> {:error, {:unpreservable_tool_name, Map.get(tool, "name")}}
    end
  end

  defp validate_preserved_names(_mode, _plugin_name, tools),
    do: {:error, {:invalid_remote_tools, tools}}

  defp preserved_name?(tool, prefix) when is_map(tool) do
    name = Map.get(tool, "name")
    is_binary(name) and String.starts_with?(name, prefix)
  end

  defp preserved_name?(_tool, _prefix), do: false

  defp decode_tool_profiles(profiles) when is_list(profiles) and profiles != [] do
    with :ok <- reject_duplicate_names(profiles, "name", :duplicate_tool_profile),
         :ok <- validate_all(profiles, &validate_tool_profile/1),
         :ok <- validate_default_profile(profiles) do
      {:ok, profiles}
    end
  end

  defp decode_tool_profiles(other), do: {:error, {:invalid_tool_profiles, other}}

  defp validate_tool_profile(%{} = profile) do
    with {:ok, name} <- tool_profile_name(profile) do
      profile |> tool_profile_body() |> tag_error({:invalid_tool_profile, name})
    end
  end

  defp validate_tool_profile(other), do: {:error, {:invalid_tool_profiles, other}}

  defp tool_profile_name(profile) do
    case Map.get(profile, "name") do
      name when is_binary(name) ->
        if Regex.match?(@profile_name_regex, name),
          do: {:ok, name},
          else: {:error, {:invalid_tool_profile_name, name}}

      other ->
        {:error, {:invalid_tool_profile_name, other}}
    end
  end

  defp tool_profile_body(profile) do
    tag = :invalid_field

    with :ok <- reject_unknown_fields(profile, @tool_profile_fields),
         {:ok, _display} <- nonempty_string(profile, "display_name", tag),
         {:ok, _default} <- boolean_field(profile, "default", tag),
         {:ok, _scope} <-
           enum_field(profile, "required_credential_scope", @credential_scopes, tag),
         {:ok, _visibility} <- enum_field(profile, "scope_visibility", @scope_visibilities, tag) do
      name_list(profile, "tools", tag)
    end
  end

  # Exactly one signed default: zero leaves setup with no safe starting point,
  # two makes "the default" ambiguous at connect time (§8.1).
  defp validate_default_profile(profiles) do
    case Enum.count(profiles, &(Map.get(&1, "default") == true)) do
      1 -> :ok
      count -> {:error, {:invalid_default_profile, count}}
    end
  end

  defp decode_setup_tools(names) when is_list(names) do
    unique? = length(Enum.uniq(names)) == length(names)

    if unique? and Enum.all?(names, &(is_binary(&1) and &1 != "")),
      do: {:ok, names},
      else: {:error, {:invalid_setup_tools, names}}
  end

  defp decode_setup_tools(other), do: {:error, {:invalid_setup_tools, other}}

  defp validate_budgets(%{} = budgets) do
    tag = :invalid_budgets

    with :ok <- reject_unknown_fields(budgets, @budget_fields),
         {:ok, calls} <- bounded_integer(budgets, "agent_turn_calls", @max_budget_calls, tag),
         {:ok, paged} <-
           bounded_integer(budgets, "agent_turn_paginated_calls", @max_budget_calls, tag) do
      check(paged <= calls, {tag, "agent_turn_paginated_calls", paged})
    end
  end

  defp validate_budgets(other), do: {:error, {:invalid_budgets, "budgets", other}}

  defp validate_result_contract(%{} = contract) do
    tag = :invalid_result_contract

    with :ok <- reject_unknown_fields(contract, @result_contract_fields),
         {:ok, _kind} <- enum_field(contract, "kind", @result_contract_kinds, tag),
         {:ok, _success} <- nonempty_string(contract, "success_field", tag),
         {:ok, _status} <- nonempty_string(contract, "status_field", tag),
         {:ok, _message} <- nonempty_string(contract, "message_field", tag) do
      :ok
    end
  end

  defp validate_result_contract(other),
    do: {:error, {:invalid_result_contract, "contract", other}}

  # A profile is an enforcement boundary, so its names must resolve to signed
  # descriptors, and a setup-only tool must never reach the agent (§7.6, §8.1).
  defp validate_profile_membership(tools, profiles, setup_tools) do
    declared = tools |> Enum.filter(&is_map/1) |> Enum.map(&Map.get(&1, "name")) |> MapSet.new()
    setup = MapSet.new(setup_tools)

    with :ok <- all_declared(setup_tools, declared, :undeclared_setup_tool) do
      validate_all(profiles, &validate_profile_tools(&1, declared, setup))
    end
  end

  defp validate_profile_tools(profile, declared, setup) do
    name = Map.get(profile, "name")
    tools = Map.get(profile, "tools")

    with :ok <- all_declared(tools, declared, :undeclared_profile_tool) do
      case Enum.find(tools, &MapSet.member?(setup, &1)) do
        nil -> :ok
        tool -> {:error, {:setup_tool_in_profile, name, tool}}
      end
    end
  end

  defp all_declared(names, declared, tag) do
    case Enum.find(names, &(not MapSet.member?(declared, &1))) do
      nil -> :ok
      name -> {:error, {tag, name}}
    end
  end

  defp validate_resource_scope(%Plugin{resource_scope: %{} = scope} = plugin, profiles, setup) do
    tag = :invalid_resource_scope

    with :ok <- reject_unknown_fields(scope, @resource_scope_fields),
         {:ok, _kind} <- enum_field(scope, "kind", @resource_scope_kinds, tag),
         {:ok, discovery} <- nonempty_string(scope, "discovery_tool", tag),
         {:ok, _id} <- nonempty_string(scope, "id_field", tag),
         {:ok, _label} <- nonempty_string(scope, "label_field", tag),
         {:ok, argument} <- nonempty_string(scope, "argument", tag),
         :ok <- check(discovery in setup, {tag, "discovery_tool", discovery}) do
      validate_scope_argument(plugin.tools, profiles, argument)
    end
  end

  defp validate_resource_scope(%Plugin{resource_scope: other}, _profiles, _setup),
    do: {:error, {:invalid_resource_scope, "resource_scope", other}}

  # The call proxy injects the operator-selected workspace into this argument
  # before network I/O, so every agent-facing tool must actually declare it
  # (§8.1 step 4) — a tool without it would silently escape the scope.
  defp validate_scope_argument(tools, profiles, argument) do
    by_name = Map.new(Enum.filter(tools, &is_map/1), &{Map.get(&1, "name"), &1})
    names = profiles |> Enum.flat_map(&Map.get(&1, "tools", [])) |> Enum.uniq()

    case Enum.find(names, &missing_scope_argument?(Map.get(by_name, &1), argument)) do
      nil -> :ok
      name -> {:error, {:missing_scope_argument, name, argument}}
    end
  end

  defp missing_scope_argument?(tool, argument) when is_map(tool) do
    case get_in(tool, ["parameters", "properties"]) do
      properties when is_map(properties) -> not Map.has_key?(properties, argument)
      _other -> true
    end
  end

  defp missing_scope_argument?(_tool, _argument), do: true

  defp validate_remote_tools(tools) when is_list(tools) and tools != [],
    do: validate_all(tools, &validate_remote_tool/1)

  defp validate_remote_tools(tools), do: {:error, {:invalid_remote_tools, tools}}

  defp validate_remote_tool(%{"name" => name} = tool) when is_binary(name),
    do: tool |> remote_tool_contract() |> tag_error({:invalid_remote_tool, name})

  defp validate_remote_tool(tool), do: {:error, {:invalid_tool, tool}}

  defp remote_tool_contract(tool) do
    tag = :invalid_field

    with :ok <- require_keys(tool, @remote_tool_fields),
         :ok <- reject_unknown_fields(tool, @remote_tool_fields),
         {:ok, _class} <- enum_field(tool, "policy_class", @policy_classes, tag),
         {:ok, _rail} <- enum_field(tool, "rail", ["mcp"], tag),
         {:ok, _read_only} <- boolean_field(tool, "read_only", tag),
         {:ok, _replay_safe} <- boolean_field(tool, "replay_safe", tag),
         {:ok, _scope} <- enum_field(tool, "required_credential_scope", @credential_scopes, tag),
         :ok <- object_schema(tool, "parameters"),
         :ok <- nullable_object_schema(tool, "output_schema"),
         :ok <- nullable_object(tool, "upstream_annotations"),
         :ok <- validate_descriptor_digest(tool),
         :ok <- validate_collection_policy(Map.get(tool, "collection_policy"), tool) do
      validate_argument_guards(Map.get(tool, "argument_guards"), tool)
    end
  end

  # §7.6 rule 6: the manifest's own `parameters`/`output_schema`/annotations must
  # canonicalize to the hash it declares. A manifest whose declared hash does not
  # match its own schemas is invalid here, long before any upstream comparison.
  defp validate_descriptor_digest(tool) do
    declared = Map.get(tool, "descriptor_sha256")

    with :ok <- check(hex_digest?(declared), {:invalid_field, "descriptor_sha256", declared}),
         {:ok, computed} <- descriptor_digest(tool) do
      check(computed == declared, {:descriptor_sha256_mismatch, declared, computed})
    end
  end

  defp hex_digest?(value),
    do: is_binary(value) and Regex.match?(@descriptor_sha256_regex, value)

  defp descriptor_digest(tool) do
    case CanonicalJson.descriptor_digest(
           Map.fetch!(tool, "name"),
           Map.fetch!(tool, "parameters"),
           Map.get(tool, "output_schema"),
           Map.get(tool, "upstream_annotations")
         ) do
      {:ok, digest} -> {:ok, digest}
      {:error, reason} -> {:error, {:uncanonicalizable_descriptor, reason}}
    end
  end

  defp validate_collection_policy(nil, _tool), do: :ok

  defp validate_collection_policy(%{} = policy, tool) do
    tag = :invalid_collection_policy
    paginated = Map.get(policy, "paginated")

    with :ok <- reject_unknown_fields(policy, @collection_policy_fields),
         :ok <- check(paginated == true, {tag, "paginated", paginated}),
         {:ok, _default} <- bounded_integer(policy, "default_limit", @max_collection_items, tag),
         {:ok, _max} <-
           bounded_integer(policy, "max_returned_items", @max_collection_items, tag),
         :ok <-
           pointer_type(policy, "request_limit_pointer", Map.get(tool, "parameters"), tag,
             types: @limit_schema_types
           ) do
      validate_items_pointer(policy, Map.get(tool, "output_schema"), tag)
    end
  end

  defp validate_collection_policy(other, _tool),
    do: {:error, {:invalid_collection_policy, "collection_policy", other}}

  # `result_items_pointer` says where the returned collection lives in the tool
  # RESULT, and the proxy caps that collection at call time either way. The
  # signed output schema is a cross-check, not the enforcement — and Stage 0
  # against Eden found it is usually absent: all 78 of its tools publish
  # `outputSchema: null`, which is common for MCP servers. Demanding one would
  # make `collection_policy` unusable against real servers, so the schema check
  # applies when a schema is published and the pointer is syntax-checked when it
  # is not. One rule, one stated condition — the runtime cap is unconditional.
  defp validate_items_pointer(policy, nil, tag) do
    with {:ok, _segments} <-
           parse_pointer(Map.get(policy, "result_items_pointer"), "result_items_pointer", tag) do
      :ok
    end
  end

  defp validate_items_pointer(policy, output_schema, tag) do
    pointer_type(policy, "result_items_pointer", output_schema, tag, types: ["array"])
  end

  # The guard KINDS are fixed core code (§7.6): the manifest picks which field is
  # guarded and how many items are allowed, and can weaken neither.
  defp validate_argument_guards(guards, tool) when is_list(guards),
    do: validate_all(guards, &validate_argument_guard(&1, tool))

  defp validate_argument_guards(other, _tool),
    do: {:error, {:invalid_argument_guard, "argument_guards", other}}

  defp validate_argument_guard(%{} = guard, tool) do
    tag = :invalid_argument_guard

    with :ok <- reject_unknown_fields(guard, @argument_guard_fields),
         {:ok, _kind} <- enum_field(guard, "kind", @argument_guard_kinds, tag),
         {:ok, _max} <- bounded_integer(guard, "max_items", @max_guard_items, tag) do
      pointer_type(guard, "pointer", Map.get(tool, "parameters"), tag, types: ["array"])
    end
  end

  defp validate_argument_guard(other, _tool),
    do: {:error, {:invalid_argument_guard, "guard", other}}

  # A policy pointer must resolve to a compatible location in the SIGNED schema
  # (§7.6): an unresolvable or type-incompatible pointer would leave the limit
  # or guard silently unenforced at call time.
  defp pointer_type(block, key, schema, tag, opts) do
    types = Keyword.fetch!(opts, :types)

    with {:ok, segments} <- parse_pointer(Map.get(block, key), key, tag),
         {:ok, node} <- resolve_schema(schema, segments, key, tag) do
      type = Map.get(node, "type")
      check(type in types, {tag, key, {:incompatible_type, type}})
    end
  end

  defp parse_pointer(pointer, key, tag) when is_binary(pointer) do
    cond do
      String.contains?(pointer, "*") -> {:error, {tag, key, {:wildcard_pointer, pointer}}}
      not String.starts_with?(pointer, "/") -> {:error, {tag, key, {:invalid_pointer, pointer}}}
      true -> pointer_segments(pointer, key, tag)
    end
  end

  defp parse_pointer(pointer, key, tag), do: {:error, {tag, key, {:invalid_pointer, pointer}}}

  defp pointer_segments(pointer, key, tag) do
    segments = pointer |> String.split("/") |> tl()

    cond do
      length(segments) > @max_pointer_segments ->
        {:error, {tag, key, {:pointer_too_deep, pointer}}}

      Enum.any?(segments, &(&1 == "" or invalid_escape?(&1))) ->
        {:error, {tag, key, {:invalid_pointer, pointer}}}

      true ->
        {:ok, Enum.map(segments, &unescape_segment/1)}
    end
  end

  # RFC 6901 defines exactly two escapes; a bare `~` is malformed.
  defp invalid_escape?(segment) do
    segment |> String.replace("~0", "") |> String.replace("~1", "") |> String.contains?("~")
  end

  defp unescape_segment(segment),
    do: segment |> String.replace("~1", "/") |> String.replace("~0", "~")

  # A pointer names a request/result FIELD path, so it walks the JSON Schema
  # through `properties`. The walk is bounded by @max_pointer_segments.
  defp resolve_schema(schema, segments, key, tag) do
    Enum.reduce_while(segments, {:ok, schema}, fn segment, {:ok, node} ->
      case schema_property(node, segment) do
        {:ok, child} -> {:cont, {:ok, child}}
        :error -> {:halt, {:error, {tag, key, {:pointer_unresolved, segment}}}}
      end
    end)
  end

  defp schema_property(%{"properties" => properties}, segment) when is_map(properties) do
    case Map.get(properties, segment) do
      child when is_map(child) -> {:ok, child}
      _other -> :error
    end
  end

  defp schema_property(_node, _segment), do: :error

  # --- small typed-field helpers -------------------------------------------

  defp require_keys(map, keys) do
    case Enum.reject(keys, &Map.has_key?(map, &1)) do
      [] -> :ok
      missing -> {:error, {:missing_fields, Enum.sort(missing)}}
    end
  end

  defp nonempty_string(map, key, tag) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      other -> {:error, {tag, key, other}}
    end
  end

  defp boolean_field(map, key, tag) do
    case Map.get(map, key) do
      value when is_boolean(value) -> {:ok, value}
      other -> {:error, {tag, key, other}}
    end
  end

  defp enum_field(map, key, allowed, tag) do
    case Map.get(map, key) do
      value when is_binary(value) ->
        if value in allowed, do: {:ok, value}, else: {:error, {tag, key, value}}

      other ->
        {:error, {tag, key, other}}
    end
  end

  defp positive_integer(map, key, tag) do
    case Map.get(map, key) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      other -> {:error, {tag, key, other}}
    end
  end

  defp bounded_integer(map, key, max, tag) do
    case Map.get(map, key) do
      value when is_integer(value) and value >= 1 and value <= max -> {:ok, value}
      other -> {:error, {tag, key, other}}
    end
  end

  defp name_list(map, key, tag) do
    case Map.get(map, key) do
      value when is_list(value) and value != [] ->
        if Enum.all?(value, &(is_binary(&1) and &1 != "")),
          do: :ok,
          else: {:error, {tag, key, value}}

      other ->
        {:error, {tag, key, other}}
    end
  end

  defp object_schema(map, key) do
    case Map.get(map, key) do
      %{"type" => "object"} = schema -> schema_properties(schema, key)
      other -> {:error, {:invalid_field, key, other}}
    end
  end

  defp nullable_object_schema(map, key) do
    case Map.get(map, key) do
      nil -> :ok
      %{"type" => "object"} = schema -> schema_properties(schema, key)
      other -> {:error, {:invalid_field, key, other}}
    end
  end

  defp schema_properties(schema, key) do
    case Map.get(schema, "properties", %{}) do
      properties when is_map(properties) -> :ok
      _other -> {:error, {:invalid_field, key, schema}}
    end
  end

  defp nullable_object(map, key) do
    case Map.get(map, key) do
      nil -> :ok
      value when is_map(value) -> :ok
      other -> {:error, {:invalid_field, key, other}}
    end
  end

  defp validate_all(items, fun) do
    Enum.reduce_while(items, :ok, fn item, :ok -> item |> fun.() |> continue_or_halt() end)
  end

  defp tag_error(:ok, _context), do: :ok
  defp tag_error({:error, reason}, {tag, name}), do: {:error, {tag, name, reason}}

  defp check(true, _reason), do: :ok
  defp check(false, reason), do: {:error, reason}

  # --- end plugin-api 3 grammar --------------------------------------------

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
