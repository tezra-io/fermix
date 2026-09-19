defmodule Fermix.CLI.BrowserCommand do
  @moduledoc """
  `fermix browser bridge install|uninstall|status` — the browser-bridge plumbing.

  `install` writes two files and prints both: a wrapper script under
  `<FERMIX_HOME>/bin/` (Chrome starts a native-messaging host with no shell
  environment and cannot pass it a verb, so the home, the launcher and the
  manifest are baked in) and the host manifest in the browser's own
  `NativeMessagingHosts` directory. `uninstall` removes the pair. `status` says
  what is installed for each browser, whether the launcher it names still
  exists, and whether an extension is connected to the running daemon.

  Tree-less, like every other `fermix` verb outside `run`: it writes files and
  probes one socket. Exit 0 when the verb succeeded, 1 when it refused, 2 on a
  usage error.
  """

  alias FermixCore.Browser.Bridge.Endpoint
  alias FermixCore.Browser.Bridge.HostManifest

  @install_switches [browser: :string, extension_id: :string]
  @uninstall_switches [browser: :string]
  @status_switches [browser: :string]
  @probe_timeout_ms 1_000

  @spec run([String.t()], keyword()) :: 0 | 1 | 2
  def run(argv, opts \\ []) when is_list(argv) and is_list(opts) do
    case argv do
      ["bridge" | rest] -> bridge(rest, opts)
      _other -> usage(2)
    end
  end

  defp bridge(["install" | argv], opts), do: install(argv, opts)
  defp bridge(["uninstall" | argv], opts), do: uninstall(argv, opts)
  defp bridge(["status" | argv], opts), do: status(argv, opts)
  defp bridge(_argv, _opts), do: usage(2)

  defp install(argv, opts) do
    with {:ok, parsed} <- parse(argv, @install_switches),
         {:ok, browser} <- require_browser(parsed),
         {:ok, id} <- require_extension_id(parsed) do
      report_install(browser, HostManifest.install(browser, id, opts))
    else
      {:error, :usage} -> usage(2)
      {:error, message} -> fail(message)
    end
  end

  defp report_install(browser, {:ok, %{manifest: manifest, wrapper: wrapper}}) do
    IO.puts("Installed the Fermix browser bridge for #{browser}.")
    IO.puts("  Host manifest: #{manifest}")
    IO.puts("  Launcher: #{wrapper}")
    IO.puts("Load the extension in #{browser}, then click it on the tab you want Fermix to use.")
    0
  end

  defp report_install(_browser, {:error, reason}), do: fail(refusal(reason))

  defp uninstall(argv, opts) do
    with {:ok, parsed} <- parse(argv, @uninstall_switches),
         {:ok, browser} <- require_browser(parsed) do
      report_uninstall(browser, HostManifest.uninstall(browser, opts))
    else
      {:error, :usage} -> usage(2)
      {:error, message} -> fail(message)
    end
  end

  defp report_uninstall(browser, {:ok, %{removed: false}}) do
    IO.puts("The Fermix browser bridge was not installed for #{browser}. Nothing to remove.")
    0
  end

  defp report_uninstall(browser, {:ok, %{manifest: manifest, wrapper: wrapper}}) do
    IO.puts("Removed the Fermix browser bridge for #{browser}.")
    IO.puts("  Host manifest: #{manifest}")
    IO.puts("  Launcher: #{wrapper}")
    0
  end

  defp report_uninstall(_browser, {:error, reason}), do: fail(refusal(reason))

  defp status(argv, opts) do
    case parse(argv, @status_switches) do
      {:ok, parsed} -> report_status(browsers(parsed), opts)
      {:error, :usage} -> usage(2)
      {:error, message} -> fail(message)
    end
  end

  defp report_status(browsers, opts) do
    Enum.each(browsers, &print_browser(&1, opts))
    print_daemon(opts)
    0
  end

  defp print_browser(browser, opts) do
    case HostManifest.status(browser, opts) do
      {:ok, row} -> print_row(row)
      {:error, reason} -> IO.puts("#{browser}: #{refusal(reason)}")
    end
  end

  defp print_row(%{installed: false, browser: browser, manifest: manifest}) do
    IO.puts("#{browser}: not installed (no manifest at #{manifest})")
  end

  defp print_row(row) do
    IO.puts("#{row.browser}: installed")
    IO.puts("  Host manifest: #{row.manifest}")
    IO.puts("  Launcher: #{row.wrapper} #{note(row.wrapper_exists)}")

    IO.puts(
      "  Fermix: #{row.launcher || "not named by the launcher"} #{note(row.launcher_exists)}"
    )

    IO.puts("  Extension: #{Enum.join(row.origins, ", ")}")
  end

  defp note(true), do: "(present)"

  defp note(false), do: "(MISSING — run `fermix browser bridge install` again for this browser)"

  # The daemon is the only thing that knows whether an extension is connected,
  # so this asks it over the same socket the pump uses, in the same framing.
  defp print_daemon(opts) do
    path = Keyword.get(opts, :socket_path, Endpoint.socket_path())

    case probe(path) do
      {:ok, %{"extensions" => extensions, "granted_tabs" => tabs}} ->
        IO.puts("Daemon: #{extensions} extension(s) connected, #{tabs} granted tab(s).")

      {:ok, _other} ->
        IO.puts("Daemon: listening on #{path}, but it answered something unexpected.")

      {:error, reason} ->
        IO.puts(
          "Daemon: not reachable on #{path} (#{inspect(reason)}). Start it with `fermix run`."
        )
    end
  end

  defp probe(path) do
    opts = [:binary, {:active, false}, {:packet, 4}, {:packet_size, 65_536}]

    with {:ok, socket} <-
           :gen_tcp.connect({:local, to_charlist(path)}, 0, opts, @probe_timeout_ms) do
      ask(socket)
    end
  catch
    :exit, :badarg -> {:error, :badarg}
  end

  defp ask(socket) do
    with :ok <- :gen_tcp.send(socket, Jason.encode!(%{type: "status"})),
         {:ok, frame} <- :gen_tcp.recv(socket, 0, @probe_timeout_ms) do
      Jason.decode(frame)
    end
  after
    :gen_tcp.close(socket)
  end

  defp browsers(parsed) do
    case Keyword.get(parsed, :browser) do
      nil -> HostManifest.browsers()
      browser -> [browser]
    end
  end

  defp parse(argv, switches) do
    case OptionParser.parse(argv, strict: switches) do
      {parsed, [], []} -> {:ok, parsed}
      _other -> {:error, :usage}
    end
  end

  defp require_browser(parsed) do
    case Keyword.get(parsed, :browser) do
      browser when browser in ["chrome", "chromium", "brave", "edge"] ->
        {:ok, browser}

      _missing_or_unknown ->
        {:error, "--browser must be one of #{Enum.join(HostManifest.browsers(), ", ")}."}
    end
  end

  defp require_extension_id(parsed) do
    case Keyword.get(parsed, :extension_id) do
      id when is_binary(id) and id != "" ->
        {:ok, id}

      _missing ->
        {:error,
         "--extension-id is required. It is the id the browser shows for the loaded Fermix " <>
           "extension on its extensions page."}
    end
  end

  defp refusal({:unsupported_browser, browser}) do
    "#{browser} is not a browser this bridge installs into. Choose one of " <>
      "#{Enum.join(HostManifest.browsers(), ", ")}."
  end

  defp refusal({:unsupported_os, os}) do
    "the browser bridge has no install location for #{inspect(os)}. It supports macOS and Linux."
  end

  defp refusal({:invalid_extension_id, id}) do
    "#{id} is not an extension id. The browser shows a 32-letter id for the loaded extension " <>
      "on its extensions page; pass that."
  end

  defp refusal({:unquotable_path, path}) do
    "#{path} contains a single quote, which the launcher script cannot carry. Move it, or " <>
      "set FERMIX_HOME to a path without one."
  end

  defp refusal({:write_failed, path, reason}) do
    "could not write #{path} (#{inspect(reason)})."
  end

  defp refusal({:unreadable_manifest, path, reason}) do
    "could not read #{path} (#{inspect(reason)})."
  end

  defp fail(message) do
    IO.puts(:stderr, "fermix browser bridge: " <> message)
    1
  end

  defp usage(status) do
    IO.puts(:stderr, """
    usage: fermix browser bridge install --browser <chrome|chromium|brave|edge> --extension-id <id>
           fermix browser bridge uninstall --browser <chrome|chromium|brave|edge>
           fermix browser bridge status [--browser <chrome|chromium|brave|edge>]\
    """)

    status
  end
end
