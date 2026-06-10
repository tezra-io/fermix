defmodule Fermix.CLI.PluginsCommand do
  @moduledoc """
  `fermix plugins` — manage local Fermix plugins.
  """

  alias Fermix.CLI.Daemon.Client, as: DaemonClient
  alias FermixCore.Auth.Redaction
  alias FermixCore.Auth.Store
  alias FermixCore.Plugins.Auth
  alias FermixCore.Plugins.Config
  alias FermixCore.Plugins.Dist.Installer, as: DistInstaller
  alias FermixCore.Plugins.Dist.Store, as: DistStore
  alias FermixCore.Plugins.Health
  alias FermixCore.Plugins.Registry
  alias FermixCore.Plugins.Runtime
  alias FermixCore.Plugins.Status
  alias FermixCore.Setup.ConfigStore

  @json_switches [json: :boolean]
  @login_switches [
    account: :string,
    no_browser: :boolean,
    port: :integer,
    timeout: :integer,
    json: :boolean
  ]

  @spec run([String.t()]) :: non_neg_integer()
  def run(argv) when is_list(argv) do
    case argv do
      [] -> list([])
      [command | rest] -> dispatch(command, rest)
    end
  end

  defp dispatch("list", rest), do: list(rest)
  defp dispatch("catalog", rest), do: catalog(rest)
  defp dispatch("enable", [name | rest]), do: enable(name, rest)
  defp dispatch("disable", [name | rest]), do: disable(name, rest)
  defp dispatch("doctor", rest), do: doctor(rest)
  defp dispatch("reload", rest), do: reload(rest)
  defp dispatch("install", [spec | rest]), do: install(spec, rest)
  defp dispatch("installed", rest), do: installed(rest)
  defp dispatch("uninstall", [name | rest]), do: uninstall(name, rest)
  defp dispatch("upgrade", [name | rest]), do: upgrade(name, rest)
  defp dispatch("pin", [spec | rest]), do: pin(spec, rest)
  defp dispatch("gc", rest), do: gc(rest)
  defp dispatch("auth", rest), do: auth(rest)
  defp dispatch("config", rest), do: config(rest)
  defp dispatch(_command, _rest), do: usage()

  defp list(argv) do
    with {:ok, json?} <- parse_json(argv),
         {:ok, plugins} <- Registry.list() do
      rows = Enum.map(plugins, &plugin_row/1)
      print(%{plugins: rows}, json?, &print_plugin_rows/1)
    else
      :error -> invalid_options("list")
      {:error, reason} -> error(reason)
    end
  end

  defp catalog(argv) do
    with {:ok, json?} <- parse_json(argv),
         {:ok, plugins} <- Registry.list() do
      rows = Enum.map(plugins, &catalog_row/1)
      print(%{plugins: rows}, json?, &print_catalog_rows/1)
    else
      :error -> invalid_options("catalog")
      {:error, reason} -> error(reason)
    end
  end

  defp enable(name, argv) do
    with {:ok, opts} <- parse_opts(argv, @json_switches),
         :ok <- ensure_available(name),
         {:ok, _snapshot} <- Config.enable(name) do
      print(%{enabled: name}, Keyword.get(opts, :json, false), fn _ ->
        IO.puts("enabled #{name}")
      end)

      apply_to_daemon()
    else
      :error -> invalid_options("enable")
      {:error, reason} -> error(reason)
    end
  end

  defp disable(name, argv) do
    with {:ok, opts} <- parse_opts(argv, @json_switches),
         {:ok, _snapshot} <- Config.disable(name) do
      print(%{disabled: name}, Keyword.get(opts, :json, false), fn _ ->
        IO.puts("disabled #{name}")
      end)

      apply_to_daemon()
    else
      :error -> invalid_options("disable")
      {:error, reason} -> error(reason)
    end
  end

  # --- distribution verbs (§9: catalog index + signed install pipeline) ---

  defp install(spec, argv) do
    {name, version} = parse_spec(spec)

    with {:ok, json?} <- parse_json(argv),
         {:ok, status} <- DistInstaller.run_install(name, dist_opts(version_opts(version))) do
      print(%{installed: name, status: status}, json?, fn _ ->
        IO.puts(install_message(name, status))
      end)

      maybe_apply_to_daemon(name)
    else
      :error -> invalid_options("install")
      {:error, reason} -> error(reason)
    end
  end

  defp installed(argv) do
    with {:ok, json?} <- parse_json(argv) do
      rows = dist_root() |> DistStore.list() |> Enum.map(&installed_row/1)
      print(%{installed: rows}, json?, &print_installed_rows/1)
    else
      :error -> invalid_options("installed")
    end
  end

  defp uninstall(name, argv) do
    with {:ok, json?} <- parse_json(argv),
         :ok <- refuse_bundled_uninstall(name),
         :ok <- maybe_disable(name),
         :ok <- DistInstaller.run_uninstall(name, dist_opts()) do
      print(%{uninstalled: name}, json?, fn _ -> IO.puts("uninstalled #{name}") end)
      apply_to_daemon()
    else
      :error -> invalid_options("uninstall")
      {:error, reason} -> error(reason)
    end
  end

  defp upgrade(name, argv) do
    with {:ok, json?} <- parse_json(argv),
         {:ok, status} <- DistInstaller.run_install(name, dist_opts()) do
      print(%{upgraded: name, status: status}, json?, fn _ ->
        IO.puts(upgrade_message(name, status))
      end)

      maybe_apply_to_daemon(name)
    else
      :error -> invalid_options("upgrade")
      {:error, reason} -> error(reason)
    end
  end

  defp pin(spec, argv) do
    with {:ok, json?} <- parse_json(argv),
         {:ok, {name, version}} <- pin_spec(spec),
         {:ok, _status} <- DistInstaller.run_install(name, dist_opts(version: version)) do
      print(%{pinned: name, version: version}, json?, fn _ ->
        IO.puts("pinned #{name} at #{version}")
      end)

      maybe_apply_to_daemon(name)
    else
      :error -> invalid_options("pin")
      {:error, reason} -> error(reason)
    end
  end

  defp gc(argv) do
    with {:ok, json?} <- parse_json(argv),
         :ok <- DistInstaller.run_gc(dist_opts()) do
      print(%{gc: :ok}, json?, fn _ -> IO.puts("gc complete") end)
    else
      :error -> invalid_options("gc")
      {:error, reason} -> error(reason)
    end
  end

  defp doctor(argv) do
    {name, rest} = name_arg(argv)

    with {:ok, opts} <- parse_opts(rest, json: :boolean, full: :boolean),
         {:ok, plugins} <- selected_plugins(name),
         rows <- Enum.map(plugins, &doctor_row(&1, Keyword.get(opts, :full, false))) do
      print(%{plugins: rows}, Keyword.get(opts, :json, false), &print_doctor_rows/1)
    else
      :error -> invalid_options("doctor")
      {:error, reason} -> error(reason)
    end
  end

  defp reload(argv) do
    with {:ok, json?} <- parse_json(argv),
         {:ok, summary} <- Runtime.reload() do
      print(%{reloaded: true, summary: reload_json(summary)}, json?, fn _ ->
        IO.puts("plugins reloaded")
      end)
    else
      :error -> invalid_options("reload")
      {:error, reason} -> error(reason)
    end
  end

  defp auth(["login", name | rest]), do: auth_login(name, rest)
  defp auth(["reauthorize", name | rest]), do: auth_login(name, rest)
  defp auth(["refresh", name | rest]), do: auth_refresh(name, rest)
  defp auth(["logout", name | rest]), do: auth_logout(name, rest)
  defp auth(["status" | rest]), do: auth_status(rest)
  defp auth(_argv), do: usage()

  defp auth_login(name, argv) do
    with {:ok, opts} <- parse_opts(argv, @login_switches),
         {:ok, entry} <- Auth.login(name, login_opts(opts)) do
      json? = Keyword.get(opts, :json, false)

      print(%{plugin: name, account: account_json(entry), status: entry.status}, json?, fn _ ->
        IO.puts("connected #{name}")
      end)
    else
      :error -> invalid_options("auth login")
      {:error, reason} -> error(reason)
    end
  end

  defp auth_refresh(name, argv) do
    with {:ok, opts} <- parse_opts(argv, @json_switches),
         {:ok, _token} <- Auth.refresh(name) do
      print(%{plugin: name, refreshed: true}, Keyword.get(opts, :json, false), fn _ ->
        IO.puts("refreshed #{name}")
      end)
    else
      :error -> invalid_options("auth refresh")
      {:error, reason} -> error(reason)
    end
  end

  defp auth_logout(name, argv) do
    with {:ok, opts} <- parse_opts(argv, @json_switches),
         :ok <- Auth.logout(name) do
      print(%{plugin: name, logged_out: true}, Keyword.get(opts, :json, false), fn _ ->
        IO.puts("logged out #{name}")
      end)
    else
      :error -> invalid_options("auth logout")
      {:error, reason} -> error(reason)
    end
  end

  defp auth_status(argv) do
    {name, rest} = name_arg(argv)

    with {:ok, opts} <- parse_opts(rest, @json_switches),
         {:ok, plugins} <- selected_plugins(name) do
      rows = Enum.map(plugins, &auth_row/1)
      print(%{plugins: rows}, Keyword.get(opts, :json, false), &print_auth_rows/1)
    else
      :error -> invalid_options("auth status")
      {:error, reason} -> error(reason)
    end
  end

  # --- plugin config (M8.1 §4.4: manifest-declared, non-secret values) ---

  defp config(["set", name, key, value | rest]), do: config_set(name, key, value, rest)
  defp config(["set" | _rest]), do: usage()
  defp config([name | rest]), do: config_show(name, rest)
  defp config(_argv), do: usage()

  defp config_set(name, key, value, argv) do
    with {:ok, json?} <- parse_json(argv),
         {:ok, _snapshot} <- Config.set_plugin_setting(name, key, value) do
      print(%{plugin: name, key: key, value: value}, json?, fn _ ->
        IO.puts("set #{name} #{key}")
      end)

      apply_to_daemon()
    else
      :error -> invalid_options("config set")
      {:error, reason} -> error(reason)
    end
  end

  defp config_show(name, argv) do
    with {:ok, json?} <- parse_json(argv),
         {:ok, [plugin]} <- selected_plugins(name) do
      settings = Config.plugin_settings(name)
      rows = Enum.map(plugin.config, &config_row(&1, settings))
      print(%{plugin: name, config: rows}, json?, &print_config_rows/1)
    else
      :error -> invalid_options("config")
      {:error, reason} -> error(reason)
    end
  end

  defp config_row(entry, settings) do
    %{
      key: entry.key,
      prompt: entry.prompt,
      required: entry.required,
      value: Map.get(settings, entry.key)
    }
  end

  defp print_config_rows(%{config: []}), do: IO.puts("no config keys declared")

  defp print_config_rows(%{config: rows}) do
    Enum.each(rows, fn row ->
      requirement = if row.required, do: "required", else: "optional"
      IO.puts("#{row.key}\t#{row.value || "(unset)"}\t#{requirement}\t#{row.prompt}")
    end)
  end

  # --- distribution helpers ---

  # Test seam: `:plugins_dist_opts` injects fetcher/verifier/index/lock opts so
  # CLI tests never touch the network or real cosign. Empty (the real
  # pipeline) outside tests.
  defp dist_opts(extra \\ []) do
    :fermix_core
    |> Application.get_env(:plugins_dist_opts, [])
    |> Keyword.merge(extra)
  end

  defp dist_root do
    Keyword.get(dist_opts(), :root) || ConfigStore.workspace_paths().plugins
  end

  defp parse_spec(spec) do
    case String.split(spec, "@", parts: 2) do
      [name] -> {name, :latest}
      [name, version] -> {name, version}
    end
  end

  defp version_opts(:latest), do: []
  defp version_opts(version), do: [version: version]

  defp pin_spec(spec) do
    case parse_spec(spec) do
      {_name, :latest} -> {:error, :pin_requires_version}
      {name, version} -> {:ok, {name, version}}
    end
  end

  defp install_message(name, :installed), do: "installed #{name}"
  defp install_message(name, :already_installed), do: "#{name} already installed"

  defp upgrade_message(name, :installed), do: "upgraded #{name}"
  defp upgrade_message(name, :already_installed), do: "#{name} already up to date"

  # `enable` on a not-yet-present name auto-installs it from the catalog index;
  # bundled and already-installed names are found by the registry and skip this.
  defp ensure_available(name) do
    case Registry.find(name) do
      {:ok, _plugin} -> :ok
      :error -> install_missing(name)
      {:error, reason} -> {:error, reason}
    end
  end

  defp install_missing(name) do
    IO.puts("#{name} is not installed — installing from the catalog")
    with {:ok, _status} <- DistInstaller.run_install(name, dist_opts()), do: :ok
  end

  defp refuse_bundled_uninstall(name) do
    with {:ok, names} <- Registry.bundled_names() do
      if name in names, do: {:error, {:bundled_plugin, name}}, else: :ok
    end
  end

  defp maybe_disable(name) do
    if name in Config.enabled_plugins() do
      with {:ok, _snapshot} <- Config.disable(name), do: :ok
    else
      :ok
    end
  end

  defp maybe_apply_to_daemon(name) do
    if name in Config.enabled_plugins(), do: apply_to_daemon(), else: 0
  end

  # Ask the running daemon to re-apply persisted config (§11: the CLI and the
  # daemon are separate VMs). Loud when no daemon is up — the operator must
  # know the change only lands on next start. Messages go to stderr so
  # `--json` stdout stays parseable.
  defp apply_to_daemon do
    case DaemonClient.request("plugins_apply", []) do
      {:ok, %{"status" => "ok"}} ->
        IO.puts(:stderr, "daemon reloaded")
        0

      {:ok, %{"status" => "error", "reason" => reason}} ->
        IO.puts(:stderr, "fermix plugins: daemon reload failed: #{reason}")
        1

      {:error, :not_running} ->
        IO.puts(:stderr, "daemon not running — changes apply on next start")
        0

      {:error, reason} ->
        IO.puts(:stderr, "fermix plugins: daemon reload failed: #{inspect(reason)}")
        1
    end
  end

  defp installed_row(entry) do
    %{name: entry.name, version: entry.version, status: entry.status, reason: entry.reason}
  end

  defp plugin_row(plugin) do
    %{
      name: plugin.name,
      display_name: plugin.display_name,
      enabled: plugin.name in Config.enabled_plugins(),
      status: Status.status(plugin),
      account: Status.account_label(plugin)
    }
  end

  defp catalog_row(plugin) do
    %{
      name: plugin.name,
      display_name: plugin.display_name,
      auth: plugin.auth.type,
      category: plugin.category
    }
  end

  defp reload_json(summary) when is_map(summary) do
    %{
      capabilities: Map.get(summary, :capabilities),
      skills: Map.get(summary, :skills),
      main_agent: Map.get(summary, :main_agent),
      realtime: Map.get(summary, :realtime)
    }
  end

  defp doctor_row(plugin, full?) do
    case Health.check(plugin.name, full?: full?) do
      {:ok, result} ->
        Map.merge(plugin_row(plugin), %{doctor: :ok, detail: result})

      {:error, reason} ->
        Map.merge(plugin_row(plugin), %{doctor: :error, error: Redaction.format(reason)})
    end
  end

  defp auth_row(plugin) do
    profile = Config.auth_profile(plugin)

    case Store.read(profile) do
      {:ok, entry} ->
        %{
          plugin: plugin.name,
          auth_profile: profile,
          status: entry.status,
          account: account_json(entry)
        }

      {:error, reason} ->
        %{
          plugin: plugin.name,
          auth_profile: profile,
          status: "missing",
          error: Redaction.format(reason)
        }
    end
  end

  defp selected_plugins(nil), do: Registry.list()

  defp selected_plugins(name) do
    case Registry.find(name) do
      {:ok, plugin} -> {:ok, [plugin]}
      :error -> {:error, {:unknown_plugin, name}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp login_opts(opts) do
    []
    |> maybe_put(:port, Keyword.get(opts, :port))
    |> maybe_put(:timeout_ms, timeout_ms(Keyword.get(opts, :timeout)))
    |> maybe_put_no_browser(Keyword.get(opts, :no_browser, false))
  end

  defp timeout_ms(nil), do: nil
  defp timeout_ms(seconds) when is_integer(seconds) and seconds > 0, do: seconds * 1_000

  defp account_json(%{account: account}) when is_map(account), do: account
  defp account_json(_entry), do: nil

  defp name_arg([]), do: {nil, []}
  defp name_arg(["--" <> _flag | _] = argv), do: {nil, argv}
  defp name_arg([name | rest]), do: {name, rest}

  defp print(data, true, _pretty) do
    IO.puts(Jason.encode!(data))
    0
  end

  defp print(data, false, pretty) do
    pretty.(data)
    0
  end

  defp print_plugin_rows(%{plugins: rows}) do
    Enum.each(rows, fn row ->
      IO.puts("#{row.name}\t#{row.status}\t#{row.account || "-"}")
    end)
  end

  defp print_catalog_rows(%{plugins: rows}) do
    Enum.each(rows, &IO.puts("#{&1.name}\t#{&1.auth}\t#{&1.category}"))
  end

  defp print_doctor_rows(%{plugins: rows}) do
    Enum.each(rows, &IO.puts("#{&1.name}\t#{&1.doctor}\t#{Map.get(&1, :error, "-")}"))
  end

  defp print_installed_rows(%{installed: rows}) do
    Enum.each(rows, &IO.puts("#{&1.name}\t#{&1.version || "-"}\t#{&1.status}"))
  end

  defp print_auth_rows(%{plugins: rows}) do
    Enum.each(
      rows,
      &IO.puts("#{&1.plugin}\t#{&1.status}\t#{Redaction.format(Map.get(&1, :account))}")
    )
  end

  defp parse_json(argv) do
    case parse_opts(argv, @json_switches) do
      {:ok, opts} -> {:ok, Keyword.get(opts, :json, false)}
      :error -> :error
    end
  end

  defp parse_opts(argv, switches) do
    case OptionParser.parse(argv, strict: switches) do
      {opts, [], []} -> {:ok, opts}
      {_opts, _args, _invalid} -> :error
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
  defp maybe_put_no_browser(opts, true), do: Keyword.put(opts, :no_browser, true)
  defp maybe_put_no_browser(opts, false), do: opts

  defp invalid_options(subcommand) do
    IO.puts(:stderr, "fermix plugins #{subcommand}: invalid options")
    2
  end

  defp error({:bundled_plugin, name}) do
    IO.puts(
      :stderr,
      "fermix plugins: #{name} is bundled with Fermix — use `fermix plugins disable #{name}` instead"
    )

    1
  end

  defp error(:pin_requires_version) do
    IO.puts(:stderr, "fermix plugins: pin requires NAME@VERSION")
    1
  end

  defp error({:unknown_config_key, key}) do
    IO.puts(:stderr, "fermix plugins: the plugin does not declare a #{key} config key")
    1
  end

  defp error({:blank_config_value, key}) do
    IO.puts(:stderr, "fermix plugins: #{key} requires a non-empty value")
    1
  end

  defp error(reason) do
    IO.puts(:stderr, "fermix plugins: #{Redaction.format(reason)}")
    1
  end

  defp usage do
    IO.puts(:stderr, """
    usage: fermix plugins [list|catalog|installed|enable NAME|disable NAME|doctor [NAME]|reload|gc] [--json]
           fermix plugins [install NAME[@VERSION]|upgrade NAME|pin NAME@VERSION|uninstall NAME] [--json]
           fermix plugins config NAME [--json]
           fermix plugins config set NAME KEY VALUE [--json]
           fermix plugins auth [login|reauthorize|refresh|logout] NAME [--json]
           fermix plugins auth status [NAME] [--json]
    """)

    2
  end
end
