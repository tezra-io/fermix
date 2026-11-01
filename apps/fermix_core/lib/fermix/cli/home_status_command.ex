defmodule Fermix.CLI.HomeStatusCommand do
  @moduledoc """
  `fermix home status` and `fermix home snapshots` (M75 §14): the home's role,
  epoch, moved marker and snapshots, and the recovery passphrase.

      fermix home status [--json]
      fermix home snapshots status [--json]
      fermix home snapshots passphrase --passphrase-file PATH [--json]

  `status` asks the engine that owns the home (`home.status` over
  `daemon.sock`) when it runs, and reads the home's own files when it does
  not: the role its settings configure (`Home.Role.configured/1`), the epoch,
  the marker, `[fermix_core.snapshots]` and `snapshots/status.json`, through
  the same projection the engine answers with (`Management.Home`). It prints
  the summary first (M75 lean v1 §7): its sentence, and its one action with
  where to take it: `fermix always-on`, or the Fermix app on a home the app
  manages (`HomeOwner.app_managed?/1`; Always On setup §8.2). `passphrase` needs
  the engine: the recovery key is saved through the running settings path.
  With the engine stopped it refuses with `engine_stopped`.

  The passphrase never enters argv: `--passphrase-file` (one line, a trailing
  newline dropped) or, with a terminal and no file, asked twice without echo.

  `--json` prints the CLI envelope (`priv/cli/CONTRACT.md`, "The home
  result"); without it the result is a few lines on stdout and a refusal one
  sentence on stderr. Exit status: `0` done, `1` refused, `2` usage error.
  """

  alias Fermix.CLI.Daemon.Client
  alias Fermix.CLI.HomeCommand
  alias Fermix.CLI.HomeOwner
  alias Fermix.CLI.MachineOutput
  alias Fermix.CLI.SecretInput
  alias FermixCore.Home.Role
  alias FermixCore.Management.Home
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.EngineOwner

  @json [json: :boolean]
  @passphrase_switches [passphrase_file: :string, json: :boolean]
  @call_timeout_ms 30_000
  @usage """
  Usage:
    fermix home status [--json]
    fermix home snapshots status [--json]
    fermix home snapshots passphrase --passphrase-file PATH [--json]
  """

  @doc """
  Runs `fermix home status ARGS`. `deps`: `:home`, `:client` (a 3-arity
  management call, as `Client.request_v1/3`), `:terminal`, `:app_managed?`
  (a 0-arity check, asked only when the human output names where the next
  step is taken).
  """
  @spec status([String.t()], keyword()) :: non_neg_integer()
  def status(argv, deps \\ []) when is_list(argv) and is_list(deps) do
    with_json(argv, fn json? -> read(json?, deps, "home.status", &status_lines(&1, deps)) end)
  end

  @doc "Runs `fermix home snapshots ARGS`, with the dependencies `status/2` takes."
  @spec snapshots([String.t()], keyword()) :: non_neg_integer()
  def snapshots(argv, deps \\ []) when is_list(argv) and is_list(deps) do
    case argv do
      ["status" | rest] ->
        with_json(rest, fn json? ->
          read(json?, deps, "home.snapshots.status", &snapshot_lines/1)
        end)

      ["passphrase" | rest] ->
        passphrase(rest, deps)

      _other ->
        usage()
    end
  end

  @doc "The result `fermix home status` prints, built from the home's files when no engine runs."
  @spec offline(Path.t()) :: {:ok, map()} | {:error, term()}
  def offline(home) when is_binary(home) do
    with {:ok, role} <- Role.configured(home),
         {:ok, config} <- ConfigStore.snapshots_config(home) do
      Home.status(
        home: home,
        engine_role: role,
        config: config,
        scheduler: nil,
        supervised: false,
        unreadable_files: nil
      )
    end
  end

  defp read(json?, deps, method, lines) do
    home = home(deps)

    case client(deps).(method, %{}, call_opts(home)) do
      {:ok, result} ->
        report(json?, result, lines)

      {:error, :not_running} ->
        offline_report(home, json?, method, lines)

      {:error, reason} ->
        refuse(json?, :home_status_unavailable, output: Client.describe_error(reason))
    end
  end

  defp offline_report(home, json?, method, lines) do
    case offline(home) do
      {:ok, status} -> report(json?, project(method, status), lines)
      {:error, reason} -> refuse(json?, :home_status_unavailable, output: offline_error(reason))
    end
  end

  defp offline_error({:config, path, reason}) when is_binary(reason), do: "#{path}: #{reason}"
  defp offline_error(reason), do: Role.refusal_sentence(reason)

  defp project("home.status", status), do: status
  defp project("home.snapshots.status", status), do: status["snapshots"]

  defp act(json?, deps, method, params, lines) do
    home = home(deps)

    case client(deps).(method, params, call_opts(home)) do
      {:ok, result} -> report(json?, result, lines)
      {:error, :not_running} -> refuse(json?, :engine_stopped, [])
      {:error, {:management_error, _code, message, details}} -> refused(json?, message, details)
      {:error, reason} -> refuse(json?, :snapshots_refused, output: Client.describe_error(reason))
    end
  end

  # The daemon's own sentence, when it gave one, is what the owner reads.
  defp refused(json?, message, details) do
    said =
      case details do
        %{"sentence" => sentence} when is_binary(sentence) -> sentence
        _none -> message
      end

    refuse(json?, :snapshots_refused, output: said)
  end

  defp passphrase(argv, deps) do
    case OptionParser.parse(argv, strict: @passphrase_switches) do
      {opts, [], []} -> send_passphrase(opts, deps)
      _invalid -> usage()
    end
  end

  defp send_passphrase(opts, deps) do
    json? = Keyword.get(opts, :json, false)

    case recovery_passphrase(opts, deps) do
      {:ok, passphrase} ->
        params = %{"recovery_passphrase" => passphrase}
        act(json?, deps, "home.snapshots.passphrase", params, &passphrase_lines/1)

      {:error, reason} ->
        refuse(json?, :snapshots_refused, output: HomeCommand.passphrase_sentence(reason))
    end
  end

  defp recovery_passphrase(opts, deps) do
    case Keyword.fetch(opts, :passphrase_file) do
      {:ok, path} -> HomeCommand.read_passphrase_file(Path.expand(path))
      :error -> ask_twice(deps)
    end
  end

  defp ask_twice(deps) do
    with {:ok, first} <- ask("Recovery passphrase", deps),
         {:ok, second} <- ask("Repeat the passphrase", deps) do
      if first == second, do: {:ok, first}, else: {:error, :passphrases_differ}
    end
  end

  defp ask(label, deps) do
    case SecretInput.read_masked(label, Keyword.take(deps, [:terminal])) do
      {:ok, value} -> {:ok, value}
      {:error, :not_a_terminal} -> {:error, :no_passphrase_source}
      {:error, reason} -> {:error, {:passphrase_prompt, reason}}
    end
  end

  defp report(true, result, _lines) do
    IO.puts(MachineOutput.ok(result))
    0
  end

  defp report(false, result, lines) do
    Enum.each(lines.(result), &IO.puts/1)
    0
  end

  defp refuse(true, code, details) do
    IO.puts(MachineOutput.error(code, details))
    1
  end

  defp refuse(false, code, details) do
    IO.puts(:stderr, "fermix home: " <> MachineOutput.sentence(code, details))
    1
  end

  defp status_lines(status, deps) do
    summary_lines(status["summary"], deps) ++
      [
        "Role: #{status["role"]}",
        "Primary epoch: #{status["epoch"] || "none yet"}"
      ] ++
      moved_line(status["moved"]) ++
      move_lines(status) ++
      secrets_lines(status["secrets_missing"] || []) ++ snapshot_lines(status["snapshots"])
  end

  # Where Always On stands, first; an engine from before the summary has none.
  defp summary_lines(%{"sentence" => sentence, "action" => %{"label" => label}}, deps),
    do: [sentence, "Next: #{label} (#{where(deps)})"]

  defp summary_lines(%{"sentence" => sentence}, _deps), do: [sentence]
  defp summary_lines(nil, _deps), do: []

  # A home the Fermix app manages takes its Always On steps in the app; any
  # other takes them with `fermix always-on`.
  defp where(deps) do
    check = Keyword.get_lazy(deps, :app_managed?, fn -> app_managed_check(home(deps)) end)
    if check.(), do: "in the Fermix app", else: "fermix always-on"
  end

  defp app_managed_check(home) do
    marker = Path.join(home, Path.basename(EngineOwner.path()))
    fn -> HomeOwner.app_managed?(socket_path: Path.join(home, "daemon.sock"), path: marker) end
  end

  # The secret references this primary could not resolve, by the id
  # `fermix setup` and `secret.set` take: each must be entered again here.
  defp secrets_lines([]), do: []

  defp secrets_lines(ids),
    do: ["Secrets to enter again on this host: #{Enum.join(ids, ", ")}"]

  # Enrollment and the move (M75 §7): the move's own sentence, the window and
  # how many candidates are held, when there are any.
  defp move_lines(status) do
    move = if status["move"], do: ["Move: #{status["move"]["sentence"]}"], else: []

    enrollment =
      case status["enrollment"] do
        %{"state" => state, "expires_at" => at} -> ["Enrollment code: #{state} (until #{at})"]
        nil -> []
      end

    candidates =
      case length(status["candidates"] || []) do
        0 -> []
        n -> ["Candidates enrolled: #{n} (fermix home candidates)"]
      end

    move ++ enrollment ++ candidates
  end

  defp moved_line(nil), do: []

  defp moved_line(%{"to" => to, "moved_at" => at, "epoch" => epoch}),
    do: ["Moved to #{to} at #{at}, at epoch #{epoch}."]

  defp snapshot_lines(snapshots) do
    ["Snapshots: #{snapshots["sentence"]}"] ++
      Enum.flat_map(snapshots["targets"], &target_lines/1) ++
      next_line(snapshots["next_run_at"])
  end

  defp target_lines(%{"configured" => false}), do: []

  defp target_lines(target) do
    verified =
      case target["last_verified"] do
        nil -> "nothing stored yet"
        %{"at" => at, "name" => name} -> "last stored #{name} at #{at}"
      end

    key =
      if target["last_verified"]["key_id"],
        do: " (key id #{target["last_verified"]["key_id"]})",
        else: ""

    ["  #{target["label"]} (#{target["destination"]}): #{verified}#{key}"] ++
      if(target["last_error"], do: ["  Last error: #{target["last_error"]}"], else: []) ++
      if(target["waiting"], do: ["  Waiting: #{target["waiting"]}"], else: [])
  end

  defp next_line(nil), do: []
  defp next_line(at), do: ["  Next run: #{at}"]

  defp passphrase_lines(
         %{"recipient" => recipient, "key_id" => key_id, "snapshots" => snapshots} = result
       ) do
    [
      "The recovery key is set (key id #{key_id}): #{recipient}",
      "Fermix keeps only this key, never the passphrase. Keep the passphrase somewhere safe: " <>
        "restoring a snapshot needs it."
    ] ++ List.wrap(result["sentence"]) ++ ["Snapshots: #{snapshots["sentence"]}"]
  end

  defp with_json(argv, fun) do
    case OptionParser.parse(argv, strict: @json) do
      {opts, [], []} -> fun.(Keyword.get(opts, :json, false))
      _invalid -> usage()
    end
  end

  defp home(deps), do: Path.expand(Keyword.get_lazy(deps, :home, &ConfigStore.fermix_home/0))
  defp client(deps), do: Keyword.get(deps, :client, &Client.request_v1/3)

  defp call_opts(home),
    do: [socket_path: Path.join(home, "daemon.sock"), timeout: @call_timeout_ms]

  defp usage do
    IO.puts(:stderr, @usage)
    2
  end
end
