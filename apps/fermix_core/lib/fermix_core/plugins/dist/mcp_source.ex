defmodule FermixCore.Plugins.Dist.McpSource do
  @moduledoc """
  Materializes enabled `mcp`-rail plugins into the same internal server-spec
  shape `[mcp.servers.*]` TOML produces — consumed by
  `Capabilities.MCP.Supervisor` alongside the operator-configured specs,
  never written to user TOML (M8 §8.2).

  Per ready plugin: `name` is the plugin name, `prefix` namespaces its
  discovered tools as `<plugin>_<tool>` (operator servers keep
  `mcp_<server>_`), `command` is the bare host-PATH executable
  (`vendored: false`) or the absolute path under the plugin's
  `bin/<target>/` (`vendored: true`), relative `args` that exist under the
  plugin root are made absolute against it, `env` carries the plugin's
  UPPER_SNAKE config values (`Plugins.Config.plugin_settings/1`), `cwd` is
  the plugin root, and `capability_metadata` marks every discovered tool
  plugin-owned for the prompt catalog.

  Only `Status` `:ready` plugins yield a spec: a failed host-runtime probe
  is `:missing_host_runtime`, a missing required config key `:needs_config`
  — loud in doctor/setup/prompt catalog, never a crash-looping child.
  """

  alias FermixCore.Plugins.Config
  alias FermixCore.Plugins.Dist.RuntimeProbe
  alias FermixCore.Plugins.Plugin
  alias FermixCore.Plugins.Registry
  alias FermixCore.Plugins.Status

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

  defp build_specs(enabled, opts) do
    with {:ok, plugins} <- Registry.list(Keyword.get(opts, :registry, [])) do
      specs =
        plugins
        |> Enum.filter(&(&1.name in enabled and is_map(&1.runtime)))
        |> Enum.filter(&(Status.status(&1, status_opts(opts)) == :ready))
        |> Enum.map(&spec(&1, opts))

      {:ok, specs}
    end
  end

  defp status_opts(opts), do: Keyword.take(opts, [:probe])

  defp spec(%Plugin{runtime: runtime} = plugin, opts) do
    root = plugin.path |> Path.dirname()

    %{
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
end
