defmodule FermixCore.Plugins.Dist.McpSource do
  @moduledoc """
  Materializes enabled `mcp`-rail plugins into the same internal server-spec
  shape `[mcp.servers.*]` TOML produces — consumed by
  `Capabilities.MCP.Supervisor` alongside the operator-configured specs,
  never written to user TOML (M8 §8.2).

  Every spec carries the source-qualified identity `{:plugin, name}` (M27
  §7.3). Operator TOML servers are `{:operator, name}`, so an operator server
  that happens to be called `eden` can never be stopped, restarted, or
  status-reported as the Eden plugin client.

  ## Two mutually exclusive shapes

  A plugin materializes **either** a local stdio spec or a remote spec, never a
  blend of the two:

    * **stdio** — `command`/`args`/`env`/`pass_env`/`cwd`. `name` is the plugin
      name, `prefix` namespaces its discovered tools as `<plugin>_<tool>`
      (operator servers keep `mcp_<server>_`), `command` is the bare host-PATH
      executable (`vendored: false`) or the absolute path under the plugin's
      `bin/<target>/` (`vendored: true`), relative `args` that exist under the
      plugin root are made absolute against it, `env` carries the plugin's
      UPPER_SNAKE config values (`Plugins.Config.plugin_settings/1`), and `cwd`
      is the plugin root.

    * **remote** (`runtime.kind: "remote_mcp"`) — `transport`,
      `protocol_version`, `base_url`, `mcp_path`, `auth_ref`, `name_mode`,
      `selected_profile`, `resource_scope`, and `allowed_tools`. There is no
      host executable, no `env`, and no `pass_env`: a remote spec that carried
      either would be a process-shaped spec for a thing that is not a process.

  The credential is **never** here. The spec carries the opaque `auth_ref`; the
  session process resolves it inside its own initialization, so no supervisor
  child spec and no crash report can print a bearer token.

  ## Startable is not callable (§7.8)

  A spec is materialized when the plugin is **startable**: installed, enabled,
  compatible, statically valid, and holding its required secret and config.
  Whether it is **callable** — the live client initialized and the whole signed
  tool contract matched — is `Capabilities.MCP.RuntimeStatus`'s answer, arrived
  at by connecting. Using live `:ready` as the materialization predicate would
  deadlock: discovery could never run, so `:ready` could never happen.

  Local stdio plugins keep their existing rule (`Status` `:ready`): a failed
  host-runtime probe is `:missing_host_runtime`, a missing required config key
  `:needs_config` — loud in doctor/setup/prompt catalog, never a crash-looping
  child.
  """

  require Logger

  alias FermixCore.Capabilities.MCP.Remote.AuthRef
  alias FermixCore.Capabilities.MCP.Remote.Endpoint
  alias FermixCore.Capabilities.MCP.Remote.Session
  alias FermixCore.Plugins.Config
  alias FermixCore.Plugins.Dist.RuntimeProbe
  alias FermixCore.Plugins.Plugin
  alias FermixCore.Plugins.Registry
  alias FermixCore.Plugins.Status
  alias FermixCore.Setup.SecretWriter

  @remote_kind "remote_mcp"

  # Fields that only make sense for a local process. Their presence in a
  # `remote_mcp` runtime block is a half-local/half-remote manifest, refused
  # outright rather than half-honoured (§7.2 rule 1).
  @local_only_runtime_fields ~w(command args env pass_env cwd vendored min_version)

  @sentinel SecretWriter.sentinel()

  # Core's non-secret plugin config keys for the operator's Connect selection
  # (§7.5). The *values* are not hard-coded anywhere: the profile must name a
  # profile the signed manifest declares, and the scope's argument comes from
  # the signed `resource_scope` block. Only the two config key names live here.
  @profile_key "access_profile"
  @workspace_key "workspace_id"
  @max_workspace_id_bytes 256

  @doc """
  Build the plugin-owned server specs. Opts (seams, all optional):

    * `:registry` — keyword passed to `Registry.list/1`
      (`:installed_root` / `:dev_local`)
    * `:probe` — keyword passed to `RuntimeProbe.probe/3` via `Status`
      (`:find_executable` / `:version_fetch` / `:target`)
  """
  @spec server_specs(keyword()) :: {:ok, [map()]} | {:error, term()}
  def server_specs(opts \\ []) when is_list(opts) do
    case Config.enabled_plugins() do
      [] -> {:ok, []}
      enabled -> build_specs(enabled, opts)
    end
  end

  @doc """
  True when the plugin declares the `remote_mcp` runtime.
  """
  @spec remote?(Plugin.t()) :: boolean()
  def remote?(%Plugin{runtime: %{"kind" => @remote_kind}}), do: true
  def remote?(%Plugin{}), do: false

  @doc """
  Build the remote server spec for one plugin, or say why it cannot start.

  This is the **startable** predicate: it validates the complete signed remote
  shape and the operator's non-secret selection, and confirms the credential
  exists — it never resolves the credential's value and never opens a socket.
  """
  @spec remote_spec(Plugin.t()) :: {:ok, map()} | {:error, term()}
  def remote_spec(%Plugin{runtime: runtime} = plugin) when is_map(runtime) do
    with :ok <- validate_remote_runtime(runtime),
         {:ok, auth_ref} <- remote_auth_ref(plugin),
         :ok <- validate_endpoint(runtime),
         {:ok, name_mode} <- name_mode(runtime),
         :ok <- require_secret(plugin),
         {:ok, profile} <- selected_profile(plugin),
         {:ok, scope} <- resource_scope(plugin) do
      {:ok, remote_map(plugin, runtime, auth_ref, name_mode, profile, scope)}
    end
  end

  def remote_spec(%Plugin{name: name}),
    do: {:error, {:invalid_remote_config, {:no_runtime, name}}}

  defp build_specs(enabled, opts) do
    with {:ok, plugins} <- Registry.list(Keyword.get(opts, :registry, [])) do
      specs =
        plugins
        |> Enum.filter(&(&1.name in enabled and is_map(&1.runtime)))
        |> Enum.flat_map(&materialize(&1, opts))

      {:ok, specs}
    end
  end

  defp materialize(%Plugin{} = plugin, opts) do
    if remote?(plugin),
      do: materialize_remote(plugin),
      else: materialize_local(plugin, opts)
  end

  defp materialize_local(plugin, opts) do
    if Status.status(plugin, status_opts(opts)) == :ready,
      do: [spec(plugin, opts)],
      else: []
  end

  # A refusal is loud but not fatal: the plugin stays visible in
  # doctor/setup with its own status rather than crash-looping a child that
  # cannot connect.
  defp materialize_remote(plugin) do
    case remote_spec(plugin) do
      {:ok, spec} ->
        [spec]

      {:error, reason} ->
        Logger.warning("remote MCP plugin #{plugin.name} is not startable: #{inspect(reason)}")
        []
    end
  end

  defp status_opts(opts), do: Keyword.take(opts, [:probe])

  defp spec(%Plugin{runtime: runtime} = plugin, opts) do
    root = plugin.path |> Path.dirname()

    %{
      source_id: {:plugin, plugin.name},
      name: plugin.name,
      prefix: plugin.name <> "_",
      command: command(runtime, root, opts),
      args: runtime |> Map.get("args", []) |> Enum.map(&resolve_arg(&1, root)),
      env: Config.plugin_settings(plugin.name),
      pass_env: Map.get(runtime, "pass_env", []),
      tools_overrides: %{},
      cwd: root,
      capability_metadata: %{
        plugin_owned?: true,
        plugin: plugin.name,
        auth_profile: Config.auth_profile(plugin),
        category: :plugin
      }
    }
  end

  # vendored: true — the runtime executable ships inside the artifact under
  # `bin/<target>/`; the Status :ready gate already probed its existence, so
  # a failed path resolution here is a hard invariant violation.
  defp command(%{"vendored" => true} = runtime, root, opts) do
    {:ok, path} = RuntimeProbe.vendored_command_path(runtime, root, probe_opts(opts))
    path
  end

  # vendored: false — a host-PATH runtime; the stdio transport resolves the
  # bare executable name at spawn.
  defp command(%{"command" => command}, _root, _opts), do: command

  defp probe_opts(opts), do: Keyword.get(opts, :probe, [])

  # Manifest args are install-relative (`src/index.js`); anything that exists
  # under the immutable plugin root becomes absolute so the child can be
  # spawned from any cwd. Flags and absolute paths pass through untouched.
  defp resolve_arg(arg, root) do
    resolved = Path.join(root, arg)

    if Path.type(arg) == :relative and File.exists?(resolved),
      do: resolved,
      else: arg
  end

  # --- remote ------------------------------------------------------------

  defp remote_map(plugin, runtime, auth_ref, name_mode, profile, scope) do
    %{
      source_id: {:plugin, plugin.name},
      name: plugin.name,
      transport: :streamable_http,
      protocol_version: Map.fetch!(runtime, "protocol_version"),
      base_url: Map.fetch!(runtime, "base_url"),
      mcp_path: Map.fetch!(runtime, "mcp_path"),
      auth_ref: auth_ref,
      name_mode: name_mode,
      selected_profile: profile,
      resource_scope: scope,
      allowed_tools: allowed_tools(plugin, profile),
      # The signed interaction policy travels WITH the spec: `Remote.Contract`
      # compiles it at server start and refuses a spec without it, so a remote
      # client can never run unbudgeted or with an unclassified result contract.
      budgets: plugin.budgets,
      result_contract: plugin.result_contract,
      tools_overrides: %{},
      capability_metadata: %{
        plugin_owned?: true,
        plugin: plugin.name,
        category: :plugin
      }
    }
  end

  defp validate_remote_runtime(runtime) do
    with :ok <- refuse_local_fields(runtime),
         :ok <- check(Map.get(runtime, "transport") == "streamable_http", :transport),
         :ok <-
           check(
             Map.get(runtime, "protocol_version") == Session.protocol_version(),
             :protocol_version
           ) do
      check(
        is_binary(Map.get(runtime, "base_url")) and is_binary(Map.get(runtime, "mcp_path")),
        :endpoint
      )
    end
  end

  defp refuse_local_fields(runtime) do
    case Enum.filter(@local_only_runtime_fields, &Map.has_key?(runtime, &1)) do
      [] -> :ok
      [field | _rest] -> {:error, {:invalid_remote_config, {:local_field, field}}}
    end
  end

  defp validate_endpoint(runtime) do
    case Endpoint.new(Map.fetch!(runtime, "base_url"), Map.fetch!(runtime, "mcp_path")) do
      {:ok, _endpoint} -> :ok
      {:error, reason} -> {:error, {:invalid_remote_config, reason}}
    end
  end

  defp remote_auth_ref(%Plugin{auth: auth, name: name}) do
    case AuthRef.from_auth(auth, name) do
      {:ok, auth_ref} -> {:ok, auth_ref}
      {:error, reason} -> {:error, {:invalid_remote_config, reason}}
    end
  end

  # `Registry` already proved every preserved name carries the `<plugin>_`
  # namespace (§7.2 rule 9); this only turns the signed string into the atom the
  # runtime branches on.
  defp name_mode(%{"tool_name_mode" => "preserve"}), do: {:ok, :preserve}
  defp name_mode(%{"tool_name_mode" => "prefix"}), do: {:ok, :prefix}

  defp name_mode(runtime),
    do: {:error, {:invalid_remote_config, {:tool_name_mode, Map.get(runtime, "tool_name_mode")}}}

  # Startability needs the credential to *exist*, never its value. The sentinel
  # is the config reference to a keychain item; a plugin whose keychain read
  # returned nothing is `:needs_secret`, not a client that starts and 401s.
  defp require_secret(%Plugin{name: name}) do
    case Config.plugin_secret(name) do
      @sentinel -> {:error, {:needs_secret, name}}
      secret when is_binary(secret) and secret != "" -> :ok
      _missing -> {:error, {:needs_secret, name}}
    end
  end

  # The operator's selection must name a profile the signed manifest declares;
  # absence resolves to the signed default. Neither name is known here — a
  # plugin that renames its profiles must not need a core change.
  defp selected_profile(%Plugin{} = plugin) do
    case plugin_entry_value(plugin.name, @profile_key) do
      nil -> signed_default_profile(plugin)
      name -> declared_profile(plugin, name)
    end
  end

  defp signed_default_profile(%Plugin{tool_profiles: profiles, name: name}) do
    case Enum.find(profiles, &(Map.get(&1, "default") == true)) do
      %{"name" => profile} when is_binary(profile) -> {:ok, profile}
      _none -> {:error, {:invalid_remote_config, {:no_default_profile, name}}}
    end
  end

  defp declared_profile(%Plugin{tool_profiles: profiles}, name) do
    if Enum.any?(profiles, &(Map.get(&1, "name") == name)),
      do: {:ok, name},
      else: {:error, {:invalid_remote_config, {:access_profile, name}}}
  end

  # One workspace, chosen by the operator during Connect and stored as
  # non-secret plugin config. Absent, there is nothing to scope calls to, and
  # the model must never be able to enumerate the account's other workspaces.
  defp resource_scope(%Plugin{resource_scope: %{} = scope, name: name}) do
    with {:ok, kind} <- scope_kind(Map.get(scope, "kind")),
         {:ok, argument} <- scope_argument(scope),
         {:ok, id} <- workspace_id(name) do
      {:ok, %{kind: kind, argument: argument, id: id}}
    end
  end

  defp resource_scope(%Plugin{name: name}),
    do: {:error, {:invalid_remote_config, {:resource_scope_missing, name}}}

  defp scope_kind("single_workspace"), do: {:ok, :single_workspace}
  defp scope_kind(other), do: {:error, {:invalid_remote_config, {:resource_scope_kind, other}}}

  defp scope_argument(%{"argument" => argument}) when is_binary(argument) and argument != "",
    do: {:ok, argument}

  defp scope_argument(_scope), do: {:error, {:invalid_remote_config, :resource_scope_argument}}

  defp workspace_id(name) do
    case plugin_entry_value(name, @workspace_key) do
      nil -> {:error, {:needs_workspace, name}}
      id -> validate_workspace_id(name, id)
    end
  end

  defp validate_workspace_id(name, id) do
    if valid_workspace_id?(id),
      do: {:ok, id},
      else: {:error, {:invalid_remote_config, {:workspace_id, name}}}
  end

  defp valid_workspace_id?(id) when is_binary(id) do
    byte_size(id) in 1..@max_workspace_id_bytes and visible_ascii?(id)
  end

  defp valid_workspace_id?(_id), do: false

  defp visible_ascii?(value) do
    value |> :binary.bin_to_list() |> Enum.all?(&(&1 >= 0x21 and &1 <= 0x7E))
  end

  # The selected profile's signed allowlist, carried verbatim as the contract
  # enforcer's input: exactly these names, with the descriptor facts the
  # manifest signed for each. Values stay as the manifest declared them —
  # nothing here atomizes or coerces untrusted manifest text. A setup-only tool
  # is in no profile, so it never reaches the agent surface (§8.1).
  defp allowed_tools(%Plugin{tools: tools} = plugin, profile) do
    by_name = Map.new(Enum.filter(tools, &is_map/1), &{Map.get(&1, "name"), &1})

    plugin
    |> profile_tool_names(profile)
    |> Map.new(fn name -> {name, tool_facts(Map.fetch!(by_name, name))} end)
  end

  defp profile_tool_names(%Plugin{tool_profiles: profiles}, profile) do
    profiles
    |> Enum.find(%{}, &(Map.get(&1, "name") == profile))
    |> Map.get("tools", [])
  end

  defp tool_facts(tool) do
    %{
      read_only: Map.get(tool, "read_only"),
      replay_safe: Map.get(tool, "replay_safe"),
      required_credential_scope: Map.get(tool, "required_credential_scope"),
      descriptor_sha256: Map.get(tool, "descriptor_sha256")
    }
  end

  # Non-secret plugin config (`[fermix_core.plugins.<name>] access_profile`).
  # `Config.plugin_settings/1` deliberately exposes only UPPER_SNAKE env keys;
  # these lowercase entries are plumbing, not child-process environment.
  defp plugin_entry_value(name, key) do
    :fermix_core
    |> Application.get_env(:plugins, [])
    |> Keyword.get(:entries, %{})
    |> Map.get(name, [])
    |> entry_value(key)
  end

  defp entry_value(entry, key) when is_list(entry) do
    Enum.find_value(entry, fn
      {entry_key, value} -> if to_string(entry_key) == key, do: to_string(value)
      _other -> nil
    end)
  end

  defp entry_value(_entry, _key), do: nil

  defp check(true, _field), do: :ok
  defp check(false, field), do: {:error, {:invalid_remote_config, field}}
end
