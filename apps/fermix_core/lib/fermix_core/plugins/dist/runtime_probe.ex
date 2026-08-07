defmodule FermixCore.Plugins.Dist.RuntimeProbe.Host do
  @moduledoc """
  Seam for the host-runtime lookups `RuntimeProbe` performs: resolving an
  executable on `PATH` and fetching its `--version` output. Production uses
  `RuntimeProbe.Host.System`; tests configure a deny-by-default stub via
  `config :fermix_core, :runtime_probe_host` (never delete that test
  default — it is what keeps `mix test` from spawning real OS processes).
  """

  @callback find_executable(command :: String.t()) :: Path.t() | nil
  @callback version_output(command :: Path.t(), opts :: keyword()) ::
              {:ok, String.t()} | {:error, term()}
end

defmodule FermixCore.Plugins.Dist.RuntimeProbe.Host.System do
  @moduledoc "Production host lookups: real `PATH` resolution + a bounded `--version` run."

  @behaviour FermixCore.Plugins.Dist.RuntimeProbe.Host

  alias FermixCore.CommandRunner

  # A `--version` probe is near-instant, but it runs on the setup render path, so
  # a wedged host runtime must not hang the page. CommandRunner bounds the wait
  # and kills the whole process group on timeout, so no child orphans. Overridable
  # via `:runtime_probe_version_timeout_ms` (mirrors the `:runtime_probe_host`
  # seam) for tests; production keeps the default.
  @default_version_timeout_ms 5_000

  @impl true
  def find_executable(command) when is_binary(command), do: System.find_executable(command)

  # `supervised` rides in on `opts` from the caller that knows its world: the
  # tree-less `fermix plugins install/doctor/status` verbs thread `supervised:
  # false` (no CommandHost.Supervisor on cli_dispatch's fall-through); daemon
  # callers omit it and CommandRunner defaults to the supervised host.
  @impl true
  def version_output(command, opts \\ []) when is_binary(command) and is_list(opts) do
    run_opts = [timeout_ms: version_timeout_ms()] ++ Keyword.take(opts, [:supervised])

    case CommandRunner.run(command, ["--version"], run_opts) do
      {:ok, %{exit: 0, stdout: output}} -> {:ok, output}
      {:ok, %{exit: status, stdout: output}} -> {:error, {:version_probe_failed, status, output}}
      {:error, reason} -> {:error, {:version_probe_failed, reason}}
    end
  end

  defp version_timeout_ms do
    Application.get_env(
      :fermix_core,
      :runtime_probe_version_timeout_ms,
      @default_version_timeout_ms
    )
  end
end

defmodule FermixCore.Plugins.Dist.RuntimeProbe do
  @moduledoc """
  Host-runtime probe for `mcp`-rail plugins (M8 §8).

  A manifest `runtime` block declares where the server's runtime executable
  lives: `vendored: false` means a host-`PATH` runtime (`node`, `python`, a
  standalone binary) that Fermix never installs — it is probed at install
  time and again at server-spec build; `vendored: true` means the executable
  ships inside the plugin artifact under `bin/<target>/<command>`.

  A failed probe is always `{:error, {:missing_host_runtime, kind,
  min_version}}` — the installer refuses with it, and `Status` maps it to
  `:missing_host_runtime` so the plugin is loud in doctor/setup/the prompt
  catalog instead of crash-looping a child that can never start.

  Seams (`opts`): `:find_executable` and `:version_fetch` funs override the
  configured `Host` module; `:target` overrides the host target used for
  vendored lookups. Tests must always stub — the production version fetch
  spawns the real runtime.
  """

  import Bitwise, only: [&&&: 2]

  alias Fermix.CLI.Upgrade.Manifest

  @version_exempt_kinds ~w(binary)

  @type runtime :: %{required(String.t()) => term()}
  @type probe_error :: {:error, {:missing_host_runtime, String.t(), String.t() | nil}}

  @doc """
  Probe the runtime declared by a plugin manifest. `plugin_dir` is the
  plugin tree root (`installed/<name>/current`, a dev_local checkout, or the
  staged install tree) — only consulted for `vendored: true`.
  """
  @spec probe(runtime(), Path.t(), keyword()) :: :ok | probe_error()
  def probe(runtime, plugin_dir, opts \\ [])

  # A `remote_mcp` runtime is an HTTPS endpoint, not a process: there is no host
  # executable to find and no `--version` to compare (M27 §7.3). Its readiness
  # is the live connection's answer, not a probe's. `Registry` has already
  # validated the block, so nothing is left to check here.
  def probe(%{"kind" => "remote_mcp"}, plugin_dir, opts)
      when is_binary(plugin_dir) and is_list(opts),
      do: :ok

  def probe(%{"kind" => kind, "command" => command} = runtime, plugin_dir, opts)
      when is_binary(kind) and is_binary(command) and is_binary(plugin_dir) and is_list(opts) do
    if vendored?(runtime),
      do: probe_vendored(runtime, plugin_dir, opts),
      else: probe_host(runtime, opts)
  end

  @doc """
  Absolute path of a `vendored: true` runtime command under the plugin tree
  (`<plugin_dir>/bin/<target>/<command>`). Pure path resolution — existence
  is `probe/3`'s job.
  """
  @spec vendored_command_path(runtime(), Path.t(), keyword()) ::
          {:ok, Path.t()} | {:error, term()}
  def vendored_command_path(%{"command" => command}, plugin_dir, opts)
      when is_binary(command) and is_binary(plugin_dir) and is_list(opts) do
    with {:ok, target} <- resolve_target(opts) do
      {:ok, Path.join([plugin_dir, "bin", target, command])}
    end
  end

  defp vendored?(runtime), do: Map.get(runtime, "vendored", false) == true

  defp probe_vendored(runtime, plugin_dir, opts) do
    case vendored_command_path(runtime, plugin_dir, opts) do
      {:ok, path} -> if executable?(path), do: :ok, else: refusal(runtime)
      {:error, _reason} -> refusal(runtime)
    end
  end

  defp probe_host(%{"command" => command} = runtime, opts) do
    case find_fun(opts).(command) do
      nil -> refusal(runtime)
      path -> check_version(runtime, path, opts)
    end
  end

  defp check_version(%{"kind" => kind} = runtime, path, opts) do
    case Map.get(runtime, "min_version") do
      min when is_binary(min) and kind not in @version_exempt_kinds ->
        compare_version(runtime, version_fetch(opts).(path), min)

      _none_or_exempt ->
        :ok
    end
  end

  defp compare_version(runtime, {:ok, output}, min) when is_binary(output) do
    case {parse_version(output), parse_version(min)} do
      {{:ok, found}, {:ok, floor}} ->
        if Version.compare(found, floor) == :lt, do: refusal(runtime), else: :ok

      _unparseable ->
        refusal(runtime)
    end
  end

  defp compare_version(runtime, {:error, _reason}, _min), do: refusal(runtime)

  # First dotted-number token in the output ("v20.11.1", "Python 3.12.1"),
  # padded to a full semver triple so `Version.compare/2` accepts it.
  defp parse_version(text) do
    case Regex.run(~r/(\d+)(?:\.(\d+))?(?:\.(\d+))?/, text) do
      [_, major | rest] -> build_version(major, rest)
      nil -> :error
    end
  end

  defp build_version(major, rest) do
    [minor, patch] = rest |> Enum.concat(["0", "0"]) |> Enum.take(2)

    case Version.parse("#{major}.#{minor}.#{patch}") do
      {:ok, version} -> {:ok, version}
      :error -> :error
    end
  end

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> (mode &&& 0o111) != 0
      _missing_or_other -> false
    end
  end

  defp refusal(%{"kind" => kind} = runtime),
    do: {:error, {:missing_host_runtime, kind, Map.get(runtime, "min_version")}}

  defp resolve_target(opts) do
    case Keyword.get(opts, :target) do
      target when is_binary(target) ->
        {:ok, target}

      nil ->
        with {:ok, {os, arch}} <- Manifest.target_for_host(), do: {:ok, "#{os}-#{arch}"}
    end
  end

  defp find_fun(opts) do
    Keyword.get_lazy(opts, :find_executable, fn ->
      host = host_module()
      &host.find_executable/1
    end)
  end

  defp version_fetch(opts) do
    Keyword.get_lazy(opts, :version_fetch, fn ->
      host = host_module()
      command_opts = Keyword.take(opts, [:supervised])
      &host.version_output(&1, command_opts)
    end)
  end

  defp host_module do
    Application.get_env(:fermix_core, :runtime_probe_host, __MODULE__.Host.System)
  end
end
