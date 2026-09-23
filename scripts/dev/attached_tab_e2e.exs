# The attached-tab slice, end to end, against a real Chromium.
#
# Run it through `scripts/dev/attached_tab_e2e.sh`, which owns the throwaway
# directories and the process accounting. This script owns the sequence:
#
#   1. serve one loopback page,
#   2. bind the real `Browser.Bridge.Endpoint` on a throwaway FERMIX_HOME,
#   3. write a native-messaging host manifest INSIDE the throwaway user-data-dir
#      and point it at the real `fermix browser-bridge` pump,
#   4. launch Chrome for Testing with the unpacked extension,
#   5. trigger the extension's action on the loopback tab the way an extension
#      test suite does — `chrome.action.onClicked.dispatch(tab)` inside the
#      extension's own service worker, over CDP. Nothing in the shipping
#      extension is changed or exposed for this,
#   6. drive the granted tab through the real `ExtensionTransport`.
#
# Never part of `mix test`: it launches a browser.

# The script narrates its own steps; a `--no-start` tree logs telemetry warnings
# that say nothing about what is under test.
Logger.configure(level: :error)

alias FermixCore.Browser.Bridge.Grants
alias FermixCore.Browser.CDP.Connection
alias FermixCore.Browser.CDP.ExtensionTransport
alias FermixCore.Browser.Config
alias FermixCore.Browser.ProfileServer

defmodule E2E do
  @moduledoc false

  def fail(message) do
    IO.puts(:stderr, "attached-tab e2e: #{message}")

    case Process.get(:chrome_log) do
      nil -> :ok
      path -> IO.puts(:stderr, "chrome said:\n" <> elem(File.read(path), 1))
    end

    System.halt(1)
  end

  # The port's messages arrive in THIS process (it opened the port), so the drain
  # runs here, between polls: a spawned drainer would never see them, and an
  # unread port buffer eventually stalls the browser.
  def watch(port, path) do
    Process.put(:chrome_port, port)
    Process.put(:chrome_log, path)
  end

  def drain do
    port = Process.get(:chrome_port)
    path = Process.get(:chrome_log)
    if port && path, do: drain_loop(port, path)
    :ok
  end

  defp drain_loop(port, path) do
    receive do
      {^port, {:data, data}} ->
        File.write!(path, data, [:append])
        drain_loop(port, path)

      {^port, {:exit_status, status}} ->
        File.write!(path, "\nchrome exited with #{status}\n", [:append])
    after
      0 -> :ok
    end
  end

  def step(message), do: IO.puts("  · #{message}")

  def ok(message), do: IO.puts("  ✓ #{message}")

  # Every wait in this script is a poll with a stated bound: a browser takes an
  # unknown but finite moment, and a hang with no message is the worst outcome.
  def until(label, timeout_ms, check) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll(label, deadline, check)
  end

  defp poll(label, deadline, check) do
    drain()

    case check.() do
      {:ok, value} ->
        value

      :retry ->
        if System.monotonic_time(:millisecond) >= deadline do
          fail("timed out waiting for #{label}")
        else
          Process.sleep(100)
          poll(label, deadline, check)
        end
    end
  end
end

defmodule E2E.Page do
  @moduledoc false

  @body """
  <!doctype html><html><head><title>Fermix attached tab</title></head>
  <body><h1 id="headline">Attached tab proof</h1>
  <p id="marker">seventeen-oaks</p>
  <script>setTimeout(() => console.log('page said hello'), 50);</script>
  </body></html>
  """

  def start do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, {:active, false}, {:reuseaddr, true}, {:ip, {127, 0, 0, 1}}])
    {:ok, port} = :inet.port(listen)
    spawn_link(fn -> accept(listen) end)
    {listen, port}
  end

  defp accept(listen) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        spawn(fn -> serve(socket) end)
        accept(listen)

      {:error, _closed} ->
        :ok
    end
  end

  defp serve(socket) do
    _request = :gen_tcp.recv(socket, 0, 2_000)

    :gen_tcp.send(socket, [
      "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: ",
      Integer.to_string(byte_size(@body)),
      "\r\nConnection: close\r\n\r\n",
      @body
    ])

    :gen_tcp.close(socket)
  end
end

# ── arguments ───────────────────────────────────────────────────────────────

[root, chrome, extension] = System.argv()
home = Path.join(root, "fermix-home")
user_data_dir = Path.join(root, "udd")
File.mkdir_p!(Path.join(home, "bin"))
File.mkdir_p!(user_data_dir)
System.put_env("FERMIX_HOME", home)

# ── 1. the loopback page ────────────────────────────────────────────────────

{_listen, http_port} = E2E.Page.start()
page_url = "http://127.0.0.1:#{http_port}/"
E2E.step("serving #{page_url}")

# ── 2. the real bridge endpoint ─────────────────────────────────────────────

# The default path under this throwaway home, because that is the path the pump
# resolves for itself: a bespoke one here would prove the wrong thing.
socket_path = Path.join(home, "browser_bridge.sock")
{:ok, _bridge} = FermixCore.Browser.Bridge.Supervisor.start_link(socket_path: socket_path)
E2E.step("bridge listening on #{socket_path}")

# ── 3. the host manifest, inside the throwaway user-data-dir ────────────────

# Chrome reads NativeMessagingHosts from the profile directory as well as the
# user-level directory, so a throwaway user-data-dir keeps this entirely out of
# the operator's own Chrome.
hosts_dir = Path.join([user_data_dir, "NativeMessagingHosts"])
File.mkdir_p!(hosts_dir)
manifest_path = Path.join(hosts_dir, "ai.fermix.bridge.json")
wrapper = Path.join([home, "bin", "fermix-browser-bridge"])
ebin_glob = Path.join([File.cwd!(), "_build", Mix.env() |> to_string(), "lib", "*", "ebin"])

File.write!(wrapper, """
#!/bin/sh
# The pump, run from this checkout's build. In an install this is the `fermix`
# launcher; here it is the same module reached the same way. The code paths are
# expanded by the shell — `-pa` takes one directory, never a glob.
PA=""
for dir in #{ebin_glob}; do PA="$PA -pa $dir"; done
# No `-noinput`: stdin IS the wire here, and the tty driver must leave it alone.
exec elixir $PA \\
  -e 'System.halt(Fermix.CLI.BrowserBridgeCommand.run(System.argv()))' \\
  -- --manifest '#{manifest_path}' "$@"
""")

File.chmod!(wrapper, 0o700)

# The extension id Chrome derives for an unpacked directory is a function of its
# absolute path, so it is read back after launch rather than guessed. The
# manifest is written twice: once permissively to let the first connection
# through, and again with the real id once it is known.
write_manifest = fn origins ->
  File.write!(
    manifest_path,
    Jason.encode!(%{
      name: "ai.fermix.bridge",
      description: "Fermix browser bridge (e2e)",
      path: wrapper,
      type: "stdio",
      allowed_origins: origins
    })
  )
end

write_manifest.([])

# ── 4. Chrome ───────────────────────────────────────────────────────────────

args = [
  "--headless=new",
  "--remote-debugging-port=0",
  "--user-data-dir=#{user_data_dir}",
  "--load-extension=#{extension}",
  "--disable-extensions-except=#{extension}",
  "--no-first-run",
  "--no-default-browser-check",
  "--disable-gpu",
  page_url
]

chrome_port =
  Port.open({:spawn_executable, chrome}, [
    :binary,
    :exit_status,
    :stderr_to_stdout,
    args: args
  ])

{:os_pid, chrome_pid} = Port.info(chrome_port, :os_pid)
File.write!(Path.join(root, "chrome.pid"), Integer.to_string(chrome_pid))
E2E.step("chrome pid #{chrome_pid}")

# Chrome's own output is the only explanation when it refuses to start, so it is
# drained (an unread port buffer would stall it) into a file the failure prints.
chrome_log = Path.join(root, "chrome.log")
File.write!(chrome_log, "")
E2E.watch(chrome_port, chrome_log)

devtools_port =
  E2E.until("chrome's debugging port", 30_000, fn ->
    case File.read(Path.join(user_data_dir, "DevToolsActivePort")) do
      {:ok, contents} ->
        case String.split(contents, "\n") do
          [port | _rest] when port != "" -> {:ok, String.to_integer(String.trim(port))}
          _other -> :retry
        end

      {:error, _reason} ->
        :retry
    end
  end)

targets = fn ->
  case :httpc.request(:get, {~c"http://127.0.0.1:#{devtools_port}/json/list", []}, [], []) do
    {:ok, {{_v, 200, _r}, _headers, body}} -> Jason.decode!(to_string(body))
    _other -> []
  end
end

:inets.start()
:ssl.start()

browser_ws =
  E2E.until("chrome's browser endpoint", 30_000, fn ->
    case :httpc.request(:get, {~c"http://127.0.0.1:#{devtools_port}/json/version", []}, [], []) do
      {:ok, {{_v, 200, _r}, _headers, body}} ->
        {:ok, Map.fetch!(Jason.decode!(to_string(body)), "webSocketDebuggerUrl")}

      _other ->
        :retry
    end
  end)

{:ok, config} = Config.current()
{:ok, browser} = Connection.start_link(browser_ws, owner: self(), keepalive_ms: 30_000)
cdp = fn method, params -> Connection.command(browser, method, params, nil, 15_000, 250) end

# ── 5. the click, inside the extension's own service worker ─────────────────

worker =
  E2E.until("the Fermix extension's service worker", 30_000, fn ->
    workers = Enum.filter(targets.(), &(&1["type"] == "service_worker"))

    Enum.find_value(workers, :retry, fn target ->
      {:ok, %{"sessionId" => session}} =
        cdp.("Target.attachToTarget", %{targetId: target["id"], flatten: true})

      case Connection.command(
             browser,
             "Runtime.evaluate",
             %{expression: "chrome.runtime.getManifest().name", returnByValue: true},
             session,
             10_000,
             250
           ) do
        {:ok, %{"result" => %{"value" => "Fermix"}}} ->
          {:ok, %{session: session, id: target["id"], url: target["url"]}}

        _other ->
          nil
      end
    end)
  end)

extension_id = worker.url |> URI.parse() |> Map.fetch!(:host)
E2E.step("extension id #{extension_id}")
write_manifest.(["chrome-extension://#{extension_id}/"])

in_worker = fn expression ->
  Connection.command(
    browser,
    "Runtime.evaluate",
    %{expression: expression, awaitPromise: true, returnByValue: true},
    worker.session,
    20_000,
    250
  )
end

# `dispatch` is how an extension's own context fires one of its events, which is
# how extension test suites drive a toolbar click. It needs no change to the
# shipping extension and no injected test hook.
click = """
(async () => {
  const tabs = await chrome.tabs.query({url: '#{page_url}*'});
  if (!tabs.length) return 'no-tab';
  chrome.action.onClicked.dispatch(tabs[0]);
  return String(tabs[0].id);
})()
"""

clicked_tab =
  E2E.until("the loopback tab", 30_000, fn ->
    case in_worker.(click) do
      {:ok, %{"result" => %{"value" => "no-tab"}}} -> :retry
      {:ok, %{"result" => %{"value" => id}}} when is_binary(id) -> {:ok, String.to_integer(id)}
      _other -> :retry
    end
  end)

E2E.ok("dispatched the extension's action on tab #{clicked_tab}")

attached? = fn tab_id ->
  case in_worker.("""
       (async () => {
         const targets = await chrome.debugger.getTargets();
         const mine = targets.find((t) => t.tabId === #{tab_id});
         return Boolean(mine && mine.attached);
       })()
       """) do
    {:ok, %{"result" => %{"value" => attached}}} -> {:ok, attached}
    other -> other
  end
end

grant =
  E2E.until("the grant to reach the daemon", 30_000, fn ->
    case Grants.claim("e2e-owner") do
      {:ok, grant} -> {:ok, grant}
      {:error, :no_grant} -> :retry
    end
  end)

E2E.ok("granted tab #{grant.tab_id} (#{grant.url})")

# ── 6. drive it through the real transport ──────────────────────────────────

{:ok, server} =
  ProfileServer.start_link(
    owner_key: "e2e-owner",
    profile_name: "selected_tab",
    profile: %{mode: :attached_tab, headless: false, cdp_port: :auto},
    config: config,
    connection: ExtensionTransport
  )

request = fn action, args ->
  ProfileServer.request(server, %{action: action, args: args, context: %{agent_name: "e2e"}})
end

case request.("act", %{"kind" => "get", "field" => "text"}) do
  {:ok, %{"value" => text}} ->
    if String.contains?(text, "seventeen-oaks") do
      E2E.ok("read the live page through the granted tab")
    else
      E2E.fail("the page text did not come back: #{inspect(text)}")
    end

  other ->
    E2E.fail("reading the granted tab failed: #{inspect(other)}")
end

case request.("tabs", %{}) do
  {:ok, %{"tabs" => [%{"url" => url}]}} ->
    if String.starts_with?(url, page_url),
      do: E2E.ok("tabs reported the live url #{url}"),
      else: E2E.fail("tabs reported #{url}, not the live page")

  other ->
    E2E.fail("tabs failed: #{inspect(other)}")
end

case request.("snapshot", %{}) do
  {:ok, %{"snapshot" => snapshot}} ->
    if String.contains?(snapshot, "Attached tab proof"),
      do: E2E.ok("snapshotted the granted tab"),
      else: E2E.fail("the snapshot did not carry the page: #{String.slice(snapshot, 0, 200)}")

  other ->
    E2E.fail("snapshot failed: #{inspect(other)}")
end

# An event arriving: the page logs after 50 ms, and a console entry can only
# have come through `chrome.debugger.onEvent` and the bridge.
case request.("console", %{}) do
  {:ok, %{"entries" => entries}} ->
    if Enum.any?(entries, &(&1["type"] == "log")),
      do: E2E.ok("a page event arrived through the bridge"),
      else: E2E.fail("no console event arrived: #{inspect(entries)}")

  other ->
    E2E.fail("console failed: #{inspect(other)}")
end

# A release detaches on the EXTENSION side: stopping the profile is what a
# finished conversation does, and the debugger must let go of the person's tab.
:ok = ProfileServer.stop(server, 5_000)

E2E.until("the extension to detach on release", 20_000, fn ->
  case attached?.(clicked_tab) do
    {:ok, false} -> {:ok, :detached}
    _other -> :retry
  end
end)

E2E.ok("stopping the profile detached the debugger on the extension side")

# And the tab can be granted again — the same tab, still open, a second click —
# after which closing it revokes and the conversation is told.
E2E.until("the second grant", 30_000, fn ->
  {:ok, _} = in_worker.(click)

  case Grants.claim("e2e-owner-two") do
    {:ok, grant} -> {:ok, grant}
    {:error, :no_grant} -> :retry
  end
end)

E2E.ok("the same tab can be granted again after a release")

{:ok, second} =
  ProfileServer.start_link(
    owner_key: "e2e-owner-two",
    profile_name: "selected_tab",
    profile: %{mode: :attached_tab, headless: false, cdp_port: :auto},
    config: config,
    connection: ExtensionTransport
  )

second_request = fn action ->
  ProfileServer.request(second, %{action: action, args: %{}, context: %{agent_name: "e2e"}})
end

{:ok, _} = second_request.("start")
{:ok, _} = in_worker.("chrome.tabs.remove(#{clicked_tab})")

E2E.until("the detach to reach the conversation", 20_000, fn ->
  case second_request.("snapshot") do
    {:error, %{code: "attached_tab_detached"}} -> {:ok, :detached}
    _other -> :retry
  end
end)

E2E.ok("closing the tab detached the conversation")

IO.puts("attached-tab e2e: PASS")
Connection.close(browser)
System.halt(0)
