defmodule Fermix.CLI.PluginsCommand do
  @moduledoc """
  `fermix plugins` — manage local Fermix plugins.
  """

  alias FermixCore.Auth.Redaction
  alias FermixCore.Auth.Store
  alias FermixCore.Plugins.Auth
  alias FermixCore.Plugins.Config
  alias FermixCore.Plugins.Health
  alias FermixCore.Plugins.Registry
  alias FermixCore.Plugins.Runtime
  alias FermixCore.Plugins.Status

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
  defp dispatch("auth", rest), do: auth(rest)
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
         {:ok, _snapshot} <- Config.enable(name) do
      print(%{enabled: name}, Keyword.get(opts, :json, false), fn _ ->
        IO.puts("enabled #{name}")
      end)
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
    else
      :error -> invalid_options("disable")
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

  defp error(reason) do
    IO.puts(:stderr, "fermix plugins: #{Redaction.format(reason)}")
    1
  end

  defp usage do
    IO.puts(:stderr, """
    usage: fermix plugins [list|catalog|enable NAME|disable NAME|doctor [NAME]|reload] [--json]
           fermix plugins auth [login|reauthorize|refresh|logout] NAME [--json]
           fermix plugins auth status [NAME] [--json]
    """)

    2
  end
end
