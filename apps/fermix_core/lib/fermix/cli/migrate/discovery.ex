defmodule Fermix.CLI.Migrate.Discovery do
  @moduledoc """
  Preflight for `fermix migrate-to-app` (M34 §4, Homebrew contract).

  Captures everything the transaction is allowed to touch — the bootstrap home,
  the recognized user LaunchAgent and its exact bytes, the live daemon's pid and
  socket, every `which -a fermix` target, and the Homebrew formula install — and
  refuses with the inspected facts whenever the account is in a state the
  migration must not resolve on its own.

  Two distinct outcomes, never blurred: a **refusal** is a state the operator
  can act on (`{:refused, code, facts, remediation}`), while a **probe failure**
  is this command being unable to read a fact at all. Reporting "a brew service
  is running" when the truth is "`brew services list` did not answer" would send
  the operator after a phantom, so those stay apart.

  Every world this module reads is injected: the OS, the account home, the
  Fermix home, the management client, and one command runner for `which`,
  `brew`, and `kill`. `Upgrade.InstallMethod` answers a different question — how
  the *running* binary was installed — and shells out uninjectably, so PATH
  ownership is classified here against the brew prefix this run actually read.
  """

  alias Fermix.CLI.Daemon.Client
  alias FermixCore.BuildInfo
  alias FermixCore.Setup.ConfigStore

  @label "io.tezra.fermix"
  @system_unit_path "/Library/LaunchDaemons/io.tezra.fermix.plist"
  @canonical_app "/Applications/Fermix.app"
  @formula "fermix"

  @type refusal_code ::
          :not_macos
          | :app_managed
          | :duplicate_app
          | :app_already_installed
          | :system_scope
          | :no_formula_install
          | :brew_service_running
          | :foreign_cli_target
          | :foreign_service
          | :unreachable_daemon

  @type facts :: %{
          fermix_home: Path.t(),
          unit_path: Path.t(),
          unit_sha256: String.t(),
          unit_program: Path.t(),
          socket_path: Path.t(),
          daemon_pid: String.t(),
          daemon_version: String.t(),
          cli_targets: [Path.t()],
          formula_versions: [String.t()],
          app_path: Path.t()
        }

  @type error ::
          {:refused, refusal_code(), [String.t()], String.t()}
          | {:probe_failed, String.t()}

  @doc """
  Inspects the account and returns the facts the transaction may act on.

  The checks run cheapest-and-most-structural first, and the brew facts precede
  the unit check because "is this our launch agent" is answered by asking
  whether its program is the Homebrew binary this run just located.
  """
  @spec capture(keyword()) :: {:ok, facts()} | {:error, error()}
  def capture(deps) when is_list(deps) do
    with :ok <- macos_only(deps),
         :ok <- standalone_only(deps),
         :ok <- single_absent_app(deps),
         :ok <- user_scope_only(deps),
         {:ok, prefix} <- brew_prefix(deps),
         {:ok, versions} <- formula_install(deps),
         :ok <- no_brew_service(deps),
         {:ok, targets} <- cli_targets(deps, prefix),
         {:ok, unit} <- recognized_unit(deps, prefix, targets),
         {:ok, daemon} <- live_daemon(deps) do
      {:ok, assemble(deps, unit, daemon, targets, versions)}
    end
  end

  @doc "The account's user LaunchAgent path for the legacy `fermix setup` unit."
  @spec unit_path(keyword()) :: Path.t()
  def unit_path(deps) when is_list(deps) do
    Path.join(home(deps), "Library/LaunchAgents/#{@label}.plist")
  end

  @doc "The canonical installed application path this migration installs into."
  @spec app_path(keyword()) :: Path.t()
  def app_path(deps) when is_list(deps), do: hd(app_paths(deps))

  defp assemble(deps, unit, daemon, targets, versions) do
    %{
      fermix_home: fermix_home(deps),
      unit_path: unit_path(deps),
      unit_sha256: unit.sha256,
      unit_program: unit.program,
      socket_path: socket_path(deps),
      daemon_pid: daemon.pid,
      daemon_version: daemon.version,
      cli_targets: targets,
      formula_versions: versions,
      app_path: app_path(deps)
    }
  end

  # ── refusals ───────────────────────────────────────────────────────────────

  defp macos_only(deps) do
    case os(deps) do
      :darwin ->
        :ok

      other ->
        refuse(
          :not_macos,
          ["host: #{other}"],
          "The bridge migration exists only for macOS. The Linux `fermix` formula continues unchanged."
        )
    end
  end

  defp standalone_only(deps) do
    build_info = Keyword.get(deps, :build_info, BuildInfo)

    case build_info.app_engine?() do
      false ->
        :ok

      true ->
        refuse(
          :app_managed,
          ["engine: macos_app"],
          "This engine is already managed by Fermix.app; there is nothing to migrate."
        )
    end
  end

  defp single_absent_app(deps) do
    case Enum.filter(app_paths(deps), &File.exists?/1) do
      [] ->
        :ok

      [only] ->
        refuse(
          :app_already_installed,
          ["installed app: #{only}"],
          "Fermix.app is already installed. Open it and use its onboarding to adopt this home, " <>
            "or remove that copy first if it is stale."
        )

      copies ->
        refuse(
          :duplicate_app,
          Enum.map(copies, &"app copy: #{&1}"),
          "Keep exactly one Fermix.app and remove the others, then re-run this command."
        )
    end
  end

  defp user_scope_only(deps) do
    path = Keyword.get(deps, :system_unit_path, @system_unit_path)

    if File.exists?(path) do
      refuse(
        :system_scope,
        ["system unit: #{path}"],
        "A system LaunchDaemon needs administrator rights this command does not take. " <>
          "Remove it with `sudo fermix service uninstall --system`, then re-run."
      )
    else
      :ok
    end
  end

  defp formula_install(deps) do
    case run(deps, "brew", ["list", "--formula", "--versions", @formula]) do
      {output, 0} ->
        {:ok, output |> String.split("\n", trim: true) |> Enum.map(&String.trim/1)}

      {output, code} ->
        refuse(
          :no_formula_install,
          ["brew list --formula --versions #{@formula}: exit #{code} #{trim(output)}"],
          "This installation is not a Homebrew formula install, so there is no formula to " <>
            "retire. Install the app directly with `brew install --cask tezra-io/tap/fermix`."
        )
    end
  end

  defp no_brew_service(deps) do
    case run(deps, "brew", ["services", "list"]) do
      {output, 0} ->
        brew_service_rows(output)

      {output, code} ->
        {:error, {:probe_failed, "brew services list: exit #{code} #{trim(output)}"}}
    end
  end

  defp brew_service_rows(output) do
    case Enum.filter(String.split(output, "\n", trim: true), &fermix_service_row?/1) do
      [] ->
        :ok

      rows ->
        refuse(
          :brew_service_running,
          Enum.map(rows, &"brew services: #{String.trim(&1)}"),
          "Stop it with `brew services stop #{@formula}` so one owner drains the daemon, " <>
            "then re-run."
        )
    end
  end

  # A `brew services list` row is `<name> <status> …`; only a row naming this
  # formula with a status other than `none` is a service brew is holding.
  defp fermix_service_row?(row) do
    case String.split(row, ~r/\s+/, trim: true) do
      [@formula, status | _rest] -> status != "none"
      _other -> false
    end
  end

  defp cli_targets(deps, prefix) do
    with {:ok, targets} <- which(deps), do: classify_targets(deps, prefix, targets)
  end

  # `which` exits 1 for "nothing on PATH", which is an answer. Any other exit —
  # a missing `which`, a permission failure — is this command being unable to
  # read PATH at all, and reporting that as "no foreign target" would let the
  # cask's launcher install underneath a binary nobody looked for.
  defp which(deps) do
    case run(deps, "which", ["-a", @formula]) do
      {output, 0} ->
        {:ok, String.split(output, "\n", trim: true)}

      {_output, 1} ->
        {:ok, []}

      {output, code} ->
        {:error, {:probe_failed, "which -a #{@formula}: exit #{code} #{trim(output)}"}}
    end
  end

  defp classify_targets(deps, prefix, targets) do
    case Enum.reject(targets, &recognized_target?(&1, prefix, app_paths(deps))) do
      [] ->
        {:ok, targets}

      foreign ->
        refuse(
          :foreign_cli_target,
          Enum.map(foreign, &"foreign `fermix` on PATH: #{&1}"),
          "After the cask installs its own launcher, that file would keep shadowing it. " <>
            "Remove or rename it, then re-run."
        )
    end
  end

  defp recognized_target?(path, prefix, app_paths) do
    String.contains?(path, "/Cellar/") or under?(path, prefix) or
      Enum.any?(app_paths, &under?(path, &1))
  end

  defp under?(_path, nil), do: false
  defp under?(_path, ""), do: false
  defp under?(path, root), do: String.starts_with?(path, root <> "/")

  # The unit is recognized only when it carries this label AND runs one of the
  # brew-owned binaries this account actually has. Anything else under our
  # label is somebody else's job, and the migration never boots out or deletes
  # a job it cannot account for.
  defp recognized_unit(deps, prefix, targets) do
    path = unit_path(deps)

    case File.read(path) do
      {:ok, body} -> verify_unit(path, body, prefix, targets ++ app_paths(deps))
      {:error, :enoent} -> {:ok, %{sha256: nil, program: nil}}
      {:error, reason} -> {:error, {:probe_failed, "read #{path}: #{inspect(reason)}"}}
    end
  end

  defp verify_unit(path, body, prefix, known) do
    program = unit_program(body)

    cond do
      not String.contains?(body, "<key>Label</key><string>#{@label}</string>") ->
        foreign_service(path, "label is not #{@label}")

      is_nil(program) ->
        foreign_service(path, "no `<program> run` ProgramArguments pair")

      not recognized_target?(program, prefix, known) ->
        foreign_service(path, "program #{program} is owned by neither Homebrew nor Fermix.app")

      true ->
        {:ok, %{sha256: sha256(body), program: program}}
    end
  end

  defp unit_program(body) do
    case Regex.run(
           ~r{<key>ProgramArguments</key>\s*<array>\s*<string>([^<]+)</string>\s*<string>run</string>},
           body
         ) do
      [_full, program] -> program
      _no_match -> nil
    end
  end

  defp foreign_service(path, why) do
    refuse(
      :foreign_service,
      ["unit: #{path}", "reason: #{why}"],
      "This migration only retires the launch agent `fermix setup` wrote. " <>
        "Remove or relocate that unit yourself, then re-run."
    )
  end

  # A recognized unit whose daemon cannot answer is refused rather than
  # guessed at: the transaction has to drain it, prove its pid exited, and
  # know which process owns the home, and KeepAlive can relaunch it at any
  # moment. Absent unit plus absent daemon is the formula-binary-only case and
  # is migrated normally.
  defp live_daemon(deps) do
    client = Keyword.get(deps, :client, &Client.request_v1/3)

    case client.("hello", %{}, socket_path: socket_path(deps)) do
      {:ok, %{"engine" => %{"pid" => pid, "product_version" => version}}} ->
        {:ok, %{pid: to_string(pid), version: to_string(version)}}

      {:ok, _other} ->
        unreachable(deps, "hello answered without an engine identity")

      {:error, reason} ->
        absent_daemon(deps, reason)
    end
  end

  defp absent_daemon(deps, reason) do
    if File.exists?(unit_path(deps)) do
      unreachable(deps, "hello failed: #{inspect(reason)}")
    else
      {:ok, %{pid: nil, version: nil}}
    end
  end

  defp unreachable(deps, why) do
    refuse(
      :unreachable_daemon,
      ["unit: #{unit_path(deps)}", "socket: #{socket_path(deps)}", "reason: #{why}"],
      "The launch agent is installed but its daemon does not answer management v1. " <>
        "Start it with `fermix start` and re-run, or remove the unit with " <>
        "`fermix service uninstall`."
    )
  end

  # ── probes ─────────────────────────────────────────────────────────────────

  defp brew_prefix(deps) do
    case run(deps, "brew", ["--prefix"]) do
      {output, 0} -> {:ok, trim(output)}
      {output, code} -> {:error, {:probe_failed, "brew --prefix: exit #{code} #{trim(output)}"}}
    end
  end

  @doc "SHA-256 of the exact unit bytes, used to prove nothing changed before removal."
  @spec sha256(binary()) :: String.t()
  def sha256(body) when is_binary(body) do
    :sha256 |> :crypto.hash(body) |> Base.encode16(case: :lower)
  end

  @doc "Runs one host command through the injected runner."
  @spec run(keyword(), String.t(), [String.t()]) :: {String.t(), integer()}
  def run(deps, command, args) when is_list(deps) and is_binary(command) and is_list(args) do
    runner = Keyword.get(deps, :command_runner, &default_command/2)
    runner.(command, args)
  end

  defp default_command(command, args) do
    case System.find_executable(command) do
      nil -> {"#{command}: not found on PATH", 127}
      path -> System.cmd(path, args, stderr_to_stdout: true)
    end
  end

  # ── inputs ─────────────────────────────────────────────────────────────────

  @doc "The daemon socket this migration drains."
  @spec socket_path(keyword()) :: Path.t()
  def socket_path(deps) when is_list(deps), do: Path.join(fermix_home(deps), "daemon.sock")

  defp fermix_home(deps) do
    Keyword.get_lazy(deps, :fermix_home, &ConfigStore.fermix_home/0)
  end

  defp home(deps), do: Keyword.get_lazy(deps, :home, &System.user_home!/0)

  defp app_paths(deps) do
    Keyword.get_lazy(deps, :app_paths, fn ->
      [@canonical_app, Path.join(home(deps), "Applications/Fermix.app")]
    end)
  end

  defp os(deps) do
    Keyword.get_lazy(deps, :os, fn ->
      case :os.type() do
        {:unix, :darwin} -> :darwin
        {:unix, other} -> other
        {other, _flavour} -> other
      end
    end)
  end

  defp refuse(code, facts, remediation), do: {:error, {:refused, code, facts, remediation}}

  defp trim(output), do: output |> to_string() |> String.trim()
end
