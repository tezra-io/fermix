defmodule FermixCore.Browser.ChromeLauncher do
  @moduledoc false

  alias FermixCore.Browser.Config
  alias FermixCore.Browser.Error
  alias FermixCore.Setup.ConfigStore

  @mac_paths [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary"
  ]
  @path_names ~w(google-chrome-stable google-chrome chromium chromium-browser chrome)

  @spec start(Config.t(), map(), String.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def start(%Config{} = config, profile, owner_key, profile_name) do
    with {:ok, executable} <- find_executable(config, profile),
         {:ok, headless} <- headless(profile),
         {:ok, requested_port} <- requested_port(profile),
         {:ok, profile_dir} <- profile_dir(owner_key, profile_name),
         :ok <- File.mkdir_p(profile_dir),
         :ok <- clear_devtools_port(profile_dir),
         {:ok, port_ref, os_pid} <- launch(executable, profile_dir, requested_port, headless) do
      ready_or_cleanup(config, requested_port, profile_dir, port_ref, os_pid, %{
        executable: executable,
        headless: headless,
        port: requested_port,
        port_ref: port_ref,
        os_pid: os_pid,
        profile_dir: profile_dir
      })
    end
  end

  @spec stop(map() | nil, Config.t()) :: :ok
  def stop(nil, %Config{}), do: :ok

  def stop(%{} = runtime, %Config{} = config) do
    kill_process(Map.get(runtime, :os_pid), config)
    safe_port_close(Map.get(runtime, :port_ref))
    :ok
  end

  @doc """
  Re-attach to a managed Chrome already running for this profile's
  `--user-data-dir`, if one exists and its CDP endpoint responds.

  Chrome allows only one instance per user-data-dir: spawning a second one with
  a different `--remote-debugging-port` makes Chrome forward to the existing
  instance ("Opening in existing browser session") and exit, so the new port
  never opens. Detecting the live instance by an EXACT user-data-dir match in
  the process list (capturing its real pid + port) lets us reuse it instead of
  failing — and keeps the pid so `stop` can still terminate it. Returns `:none`
  for non-managed profiles or when nothing is running for the dir.
  """
  @spec attach(Config.t(), map(), String.t(), String.t()) :: {:ok, map()} | :none
  def attach(%Config{} = config, %{mode: :managed}, owner_key, profile_name) do
    {:ok, profile_dir} = profile_dir(owner_key, profile_name)

    with {:ok, pid} <- running_pid_for_dir(profile_dir),
         {:ok, port} <- read_devtools_port(profile_dir),
         {:ok, ws_url} <- fetch_version(port, config) do
      {:ok,
       %{
         ws_url: ws_url,
         port: port,
         os_pid: pid,
         port_ref: nil,
         headless: nil,
         profile_dir: profile_dir,
         reused: true
       }}
    else
      _other -> :none
    end
  end

  def attach(%Config{}, _profile, _owner_key, _profile_name), do: :none

  @spec find_executable(Config.t(), map() | nil) :: {:ok, String.t()} | {:error, Error.t()}
  def find_executable(%Config{}, profile) do
    candidates(profile)
    |> Enum.find(&executable?/1)
    |> case do
      nil -> {:error, Error.new("chrome_missing", "Chrome executable was not found")}
      path -> {:ok, path}
    end
  end

  defp ready_or_cleanup(config, requested_port, profile_dir, port_ref, os_pid, runtime) do
    case wait_until_ready(requested_port, profile_dir, port_ref, config) do
      {:ok, port, ws_url} ->
        {:ok, runtime |> Map.put(:port, port) |> Map.put(:ws_url, ws_url)}

      {:error, output} ->
        kill_process(os_pid, config)
        safe_port_close(port_ref)
        {:error, not_ready_error(runtime, output)}
    end
  end

  # The opaque "did not become ready" is the #1 thing operators hit (e.g. a
  # headless profile that won't start, or a profile dir already in use). Carry
  # the resolved launch mode and Chrome's own stderr tail so the failure is
  # diagnosable instead of a guess.
  defp not_ready_error(runtime, output) do
    Error.new("cdp_not_ready", "Chrome CDP endpoint did not become ready", %{
      "headless" => runtime.headless,
      "port" => runtime.port,
      "chrome_output" => output_tail(output)
    })
  end

  defp output_tail(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.take(-20)
    |> Enum.join("\n")
  end

  defp candidates(profile) do
    [
      profile_path(profile),
      System.get_env("CHROME_PATH")
      | Enum.map(@path_names, &System.find_executable/1) ++ @mac_paths
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp profile_path(%{executable_path: path}) when is_binary(path), do: path
  defp profile_path(_profile), do: nil

  defp executable?(path) when is_binary(path), do: File.regular?(path) and File.exists?(path)

  defp headless(%{headless: value}) when value in [true, false], do: {:ok, value}
  defp headless(%{headless: :auto}), do: {:ok, auto_headless?()}

  defp headless(_profile) do
    {:error, Error.new("invalid_config", "Invalid browser headless profile setting")}
  end

  defp auto_headless? do
    case System.get_env("FERMIX_BROWSER_HEADLESS") do
      value when value in ["1", "true", "TRUE", "yes"] -> true
      value when value in ["0", "false", "FALSE", "no"] -> false
      _other -> linux_without_display?()
    end
  end

  defp linux_without_display? do
    match?({:unix, :linux}, :os.type()) and is_nil(System.get_env("DISPLAY")) and
      is_nil(System.get_env("WAYLAND_DISPLAY"))
  end

  # An explicit port is honored (and pre-checked); `:auto` defers to Chrome via
  # `--remote-debugging-port=0`, which binds an OS-assigned free port atomically
  # and publishes it in `<user-data-dir>/DevToolsActivePort`. Letting Chrome pick
  # removes the check-then-bind race two concurrent launches had when Fermix
  # scanned a shared range (both could see the same port "free" and collide).
  defp requested_port(%{cdp_port: port}) when is_integer(port) do
    if port_free?(port),
      do: {:ok, port},
      else: {:error, Error.new("port_conflict", "Browser CDP port #{port} is already in use")}
  end

  defp requested_port(%{cdp_port: :auto}), do: {:ok, 0}

  # Drop any DevToolsActivePort a prior (now-dead) Chrome left for this dir, so
  # the readiness wait reads the port the NEW Chrome publishes, never a stale one.
  defp clear_devtools_port(profile_dir) do
    _ = profile_dir |> devtools_port_path() |> File.rm()
    :ok
  end

  defp devtools_port_path(profile_dir), do: Path.join(profile_dir, "DevToolsActivePort")

  defp port_free?(port) do
    case :gen_tcp.listen(port, [:binary, active: false, ip: {127, 0, 0, 1}]) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _reason} ->
        false
    end
  end

  defp profile_dir(owner_key, profile_name) do
    dir =
      Path.join([
        Map.fetch!(ConfigStore.workspace_paths(), :browser),
        "profiles",
        owner_key,
        profile_name
      ])

    {:ok, dir}
  end

  # Find a managed Chrome already running for exactly this user-data-dir and
  # return its os pid. Unix-only (release targets are macOS/Linux); on other
  # platforms there is no reuse and we always spawn. The actual CDP port is read
  # from DevToolsActivePort, not parsed from ps — with `--remote-debugging-port=0`
  # the ps args show "0", not the OS-assigned port.
  defp running_pid_for_dir(profile_dir) do
    if unix?(), do: parse_ps_pid(ps_output(), profile_dir), else: :none
  end

  defp ps_output do
    case System.cmd("ps", ["-axww", "-o", "pid=,command="], stderr_to_stdout: true) do
      {output, 0} -> output
      _other -> ""
    end
  rescue
    _error -> ""
  end

  @doc """
  Parse `ps -o pid=,command=` output for a managed Chrome bound to exactly
  `profile_dir`, returning `{:ok, os_pid}` or `:none`. Exposed for tests.
  """
  @spec parse_ps_pid(String.t(), String.t()) :: {:ok, pos_integer()} | :none
  def parse_ps_pid(output, profile_dir) when is_binary(output) and is_binary(profile_dir) do
    output |> String.split("\n") |> Enum.find_value(:none, &parse_chrome_pid(&1, profile_dir))
  end

  # Exact-token match on --user-data-dir avoids a prefix collision between
  # e.g. ".../fermix" and ".../fermix_visible".
  defp parse_chrome_pid(line, profile_dir) do
    tokens = String.split(line)

    with true <- ("--user-data-dir=" <> profile_dir) in tokens,
         pid when is_integer(pid) <- parse_int(List.first(tokens)) do
      {:ok, pid}
    else
      _other -> nil
    end
  end

  defp parse_int(nil), do: nil

  defp parse_int(value) do
    case Integer.parse(value) do
      {int, _rest} -> int
      :error -> nil
    end
  end

  # Profile locking is left to Chrome itself: a stale SingletonLock (owner dead)
  # is cleaned up by Chrome on startup, and a genuinely live lock makes Chrome
  # refuse to start, which surfaces here as a `cdp_not_ready` error after
  # `ready_or_cleanup/5` reaps the failed launch. We deliberately do NOT parse
  # the lock and kill the owning PID — a recycled PID could belong to an
  # unrelated process, and a false "locked" verdict has no safe recovery.
  defp launch(executable, profile_dir, port, headless) do
    args = launch_args(profile_dir, port, headless)

    port_ref =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, args}
      ])

    {:os_pid, os_pid} = Port.info(port_ref, :os_pid)
    {:ok, port_ref, os_pid}
  rescue
    error -> {:error, Error.new("launch_failed", Exception.message(error))}
  end

  defp launch_args(profile_dir, port, headless) do
    [
      "--remote-debugging-port=#{port}",
      "--user-data-dir=#{profile_dir}",
      "--no-first-run",
      "--no-default-browser-check",
      "--disable-background-networking",
      "--disable-background-timer-throttling",
      "--disable-client-side-phishing-detection",
      "--disable-component-update",
      "--disable-default-apps",
      "--disable-features=Translate,MediaRouter",
      "--password-store=basic",
      "about:blank"
    ]
    |> maybe_headless(headless)
    |> maybe_linux_arg()
  end

  defp maybe_headless(args, true), do: ["--headless=new" | args]
  defp maybe_headless(args, false), do: args

  defp maybe_linux_arg(args) do
    if match?({:unix, :linux}, :os.type()), do: ["--disable-dev-shm-usage" | args], else: args
  end

  defp wait_until_ready(requested_port, profile_dir, port_ref, %Config{} = config) do
    deadline = System.monotonic_time(:millisecond) + config.launch_timeout_ms
    do_wait_until_ready(requested_port, profile_dir, port_ref, deadline, config, "")
  end

  # Two-stage readiness sharing one deadline: learn the actual port (Chrome
  # publishes DevToolsActivePort once its CDP server binds), then confirm the
  # endpoint answers `/json/version`.
  defp do_wait_until_ready(requested_port, profile_dir, port_ref, deadline, config, output) do
    output = output <> drain_port(port_ref)

    with {:ok, port} <- resolve_port(requested_port, profile_dir),
         {:ok, ws_url} <- fetch_version(port, config) do
      {:ok, port, ws_url}
    else
      _not_ready ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, output <> drain_port(port_ref)}
        else
          Process.sleep(config.cdp_ready_poll_interval_ms)
          do_wait_until_ready(requested_port, profile_dir, port_ref, deadline, config, output)
        end
    end
  end

  defp resolve_port(0, profile_dir), do: read_devtools_port(profile_dir)
  defp resolve_port(port, _profile_dir) when port > 0, do: {:ok, port}

  @doc """
  Read the CDP port Chrome bound from `<user-data-dir>/DevToolsActivePort`
  (line 1 is the port). Chrome writes it for any `--remote-debugging-port`,
  including `0`, once the endpoint is listening. Exposed for tests.
  """
  @spec read_devtools_port(String.t()) :: {:ok, pos_integer()} | {:error, term()}
  def read_devtools_port(profile_dir) do
    with {:ok, contents} <- File.read(devtools_port_path(profile_dir)),
         [line | _rest] <- String.split(contents, "\n"),
         {port, _rest} <- Integer.parse(String.trim(line)) do
      {:ok, port}
    else
      _other -> {:error, :no_devtools_port}
    end
  end

  # Non-blocking drain of whatever Chrome has written to the (stderr-merged)
  # port so far. Runs in the ProfileServer process that owns the port; only
  # matches port-data frames, leaving other messages in the mailbox.
  defp drain_port(port_ref) do
    receive do
      {^port_ref, {:data, data}} -> data <> drain_port(port_ref)
    after
      0 -> ""
    end
  end

  defp fetch_version(port, %Config{} = config) do
    url = "http://127.0.0.1:#{port}/json/version"

    case Req.get(url, receive_timeout: config.cdp_version_probe_timeout_ms, retry: false) do
      {:ok, %{status: 200, body: %{"webSocketDebuggerUrl" => ws_url}}} -> {:ok, ws_url}
      {:ok, %{status: 200, body: body}} when is_binary(body) -> decode_version(body)
      other -> {:error, other}
    end
  end

  defp decode_version(body) do
    case Jason.decode(body) do
      {:ok, %{"webSocketDebuggerUrl" => ws_url}} -> {:ok, ws_url}
      other -> {:error, other}
    end
  end

  # Guaranteed teardown: SIGTERM, wait the grace, then SIGKILL. Unix-only;
  # release targets are macOS/Linux. Non-unix falls back to closing the port.
  defp kill_process(os_pid, %Config{} = config) when is_integer(os_pid) do
    if unix?() do
      signal(os_pid, "TERM")

      unless wait_exit(os_pid, config.stop_grace_ms) do
        signal(os_pid, "KILL")
        wait_exit(os_pid, config.kill_grace_ms)
      end
    end

    :ok
  end

  defp kill_process(_os_pid, %Config{}), do: :ok

  defp signal(os_pid, name) do
    _ = System.cmd("kill", ["-#{name}", Integer.to_string(os_pid)], stderr_to_stdout: true)
    :ok
  rescue
    _error -> :ok
  end

  defp wait_exit(os_pid, grace_ms) do
    Process.sleep(grace_ms)
    not os_pid_alive?(os_pid)
  end

  defp os_pid_alive?(os_pid) when is_integer(os_pid) do
    unix?() and
      match?(
        {_output, 0},
        System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)
      )
  rescue
    _error -> false
  end

  defp safe_port_close(port_ref) when is_port(port_ref) do
    Port.close(port_ref)
    :ok
  rescue
    _error -> :ok
  end

  defp safe_port_close(_port_ref), do: :ok

  defp unix?, do: match?({:unix, _}, :os.type())
end
