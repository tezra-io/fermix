defmodule FermixCore.Sandbox.Env do
  @moduledoc """
  Builds child-process environments from explicit sandbox passthrough config.

  Two kinds of name reach the resolver, and they fail differently on purpose.

  The operator's allow list (`[sandbox.env] allow`) is passthrough policy. Every
  name resolves on its own: a name the daemon cannot read where it runs is
  reported in `unresolved` beside the names that did resolve, and the command
  still gets the rest. One stale entry must never refuse a command that asked
  for nothing (a trading key nobody had stored for the service refused every
  `date` in every session for 26 days).

  A name a consumer requests explicitly (a harness adapter's declared variable,
  a command capability's `pass_env`) is a requirement, and a requirement that
  cannot be met is an error.

  The allow list's helper lookups for one command share one time budget
  (`lookup_budget_ms/0`): each helper runs for the lesser of its own timeout and
  what is left, and one still running at the end is killed. A name whose helper
  did not finish in time, or was never started because the budget was gone, is
  unresolved with its own reason, and the command runs. A locked keychain with
  several names therefore costs a command the budget once, not a timeout per
  name. Reading the daemon's environment spawns nothing and is never cut off.
  """

  alias FermixCore.CommandRunner
  alias FermixCore.Sandbox.Config

  @default_keys ~w(PATH HOME USER LANG SHELL TMPDIR)
  @secret_max_bytes 8_192
  @lookup_budget_ms 5_000

  @typedoc "One allowed name the daemon could not read, with the resolver's reason."
  @type unresolved :: %{name: String.t(), reason: term()}

  @typedoc """
  A built child environment. `resolved` and `unresolved` cover the allow list
  only, in allow-list order; a requested name is either in `env` or an error.
  """
  @type built :: %{
          env: [{String.t(), String.t()}],
          resolved: [String.t()],
          unresolved: [unresolved()]
        }

  @doc """
  Build a command's environment from the allow list plus `extra_names`, the
  names a consumer requires.

  `opts`: `supervised:` (whether a helper runs under the command-host tree;
  false for a tree-less CLI verb) and `lookup_budget_ms:`, which replaces the
  allow list's lookup budget. The budget option is a test seam; every daemon
  caller uses `lookup_budget_ms/0`.
  """
  @spec build(Config.t() | map() | keyword(), [String.t()], keyword()) ::
          {:ok, built()} | {:error, term()}
  def build(config, extra_names \\ [], opts \\ []) when is_list(extra_names) and is_list(opts) do
    config = Config.normalize(config)
    required = Enum.uniq(extra_names)

    case selected_names(config, required) do
      :everything ->
        env = default_env() |> Map.merge(everything_env(config)) |> Map.to_list()
        {:ok, %{env: env, resolved: [], unresolved: []}}

      {allowed, required} ->
        build_selected(config, allowed, required, lookup(opts))
    end
  end

  @doc "The time every allow-list helper lookup for one command shares."
  @spec lookup_budget_ms() :: pos_integer()
  def lookup_budget_ms, do: @lookup_budget_ms

  @doc """
  Where an allowed variable's value can be stored so the daemon reads it, on
  every install: the sandbox settings (the OS secret store behind them), or on
  a server with no keyring, the env file the Linux service unit loads. One
  sentence, shared by the shell notice and the readiness row, and written to
  the published-copy rules because readiness renders it verbatim.
  """
  @spec missing_env_remedy() :: String.t()
  def missing_env_remedy do
    "Store the value in the sandbox settings, or on a server with no keyring add it to " <>
      "`~/.config/fermix/env` and restart Fermix."
  end

  @spec build_command(Config.t() | map() | keyword(), [String.t()], keyword()) ::
          {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def build_command(config, pass_env, opts \\ []) when is_list(pass_env) and is_list(opts) do
    config = Config.normalize(config)

    with :ok <- validate_pass_env(config, pass_env),
         {:ok, selected} <- command_env(config, Enum.uniq(pass_env), supervised(opts)) do
      {:ok, default_env() |> Map.merge(selected) |> Map.to_list()}
    end
  end

  @doc """
  Overlay a client session's env onto an already-built child env
  (MILESTONE_29_ACP_AGENT_SURFACE §8.3).

  A caller-side merge on purpose: `build/3` and `build_command/3` keep deciding
  what sandbox POLICY passes through, and this adds what the client session
  brought, for the two sandbox exec paths that run a command on behalf of a turn
  (the shell tool via `Sandbox.shell_plan/3`, operator-declared command
  capabilities via `Sandbox.CommandTool`). Every other caller of those builders
  is byte-identical.

  The overlay wins on its own keys, PATH included: the ACP harness's PATH is what
  makes its own CLI resolvable, and its credentials are what make that CLI able to
  post. Everything the overlay does not name keeps the sandbox policy's value.
  `TurnRunner` already restricted this to operator-trust turns, and the daemon
  filtered the keys before it ever reached a context, so there is no second filter
  here.
  """
  @spec apply_session_env([{String.t(), String.t()}], %{String.t() => String.t()} | nil) ::
          [{String.t(), String.t()}]
  def apply_session_env(env, session_env)
      when is_list(env) and is_map(session_env) and map_size(session_env) > 0 do
    env |> Map.new() |> Map.merge(session_env) |> Map.to_list()
  end

  def apply_session_env(env, _absent) when is_list(env), do: env

  @doc """
  The values a built env carries for `names`: what a tool scrubs from the
  command's result and trace (M45 §4.7). The default keys are the child's
  ordinary environment rather than credentials, so they are never included,
  even when an operator also allows one of them by name.
  """
  @spec values_for([{String.t(), String.t()}], [String.t()]) :: [String.t()]
  def values_for(env, names) when is_list(env) and is_list(names) do
    wanted = names |> Enum.reject(&default_key?/1) |> MapSet.new()
    for {name, value} <- env, MapSet.member?(wanted, name), do: value
  end

  # `supervised` is owned by the caller's world: the tree-less `fermix sandbox
  # env get` verb passes `supervised: false` (no `CommandHost.Supervisor`);
  # daemon callers (shell tool, MCP supervisor) omit it and CommandRunner
  # defaults to the supervised host. Only `source = "command"` env resolution
  # spawns a subprocess, so the flag matters solely on that path.
  defp supervised(opts), do: Keyword.get(opts, :supervised, true)

  defp lookup(opts) do
    case Keyword.get(opts, :lookup_budget_ms, @lookup_budget_ms) do
      budget when is_integer(budget) and budget > 0 ->
        %{supervised: supervised(opts), budget_ms: budget}

      other ->
        raise ArgumentError,
              "Sandbox.Env option :lookup_budget_ms must be a positive integer, got: " <>
                inspect(other)
    end
  end

  @spec format_error(term()) :: String.t()
  def format_error({:env_not_allowed, name}) when is_binary(name) do
    "#{name} is not allowed for this command. Run `fermix sandbox env allow #{name}` " <>
      "or configure it with `fermix sandbox env set #{name} -- <helper> [args...]`."
  end

  def format_error({:env_denied, name}) when is_binary(name) do
    "#{name} is denied by sandbox env config. Remove it from the deny list or run " <>
      "`fermix sandbox env allow #{name}` before passing it through."
  end

  def format_error({:missing_env, name}) when is_binary(name) do
    "#{name} has no value Fermix can read. " <> missing_env_remedy()
  end

  def format_error({:env_lookup_budget_exhausted, budget_ms}) when is_integer(budget_ms) do
    "Fermix stopped reading allowed variables for this command after #{budget_ms}ms, " <>
      "before this one's helper answered. A slow helper earlier in the list, such as a " <>
      "locked keychain, is the usual cause: run each helper by hand to find it."
  end

  def format_error({:env_command_not_found, command}) when is_binary(command) do
    "#{command} could not be found while resolving an env value. Install it or reconfigure " <>
      "with `fermix sandbox env set NAME -- <helper> [args...]`."
  end

  def format_error({:env_command_failed, command, code, output}) do
    "#{command} failed while resolving an env value (exit #{code}): #{output}. " <>
      "Run the helper manually to verify it, or reconfigure with `fermix sandbox env set NAME -- <helper> [args...]`."
  end

  def format_error({:env_command_timeout, command, timeout}) do
    "#{command} timed out after #{timeout}ms while resolving an env value. " <>
      "Run the helper manually to verify it, or reconfigure with `fermix sandbox env set NAME -- <helper> [args...]`."
  end

  def format_error(:env_command_output_too_large) do
    "Env helper output exceeded the size limit. Reconfigure it with `fermix sandbox env set NAME -- <helper> [args...]`."
  end

  def format_error(:empty_env_command_output) do
    "Env helper returned an empty value. Reconfigure it with `fermix sandbox env set NAME -- <helper> [args...]`."
  end

  def format_error(:env_command_output_not_single_value) do
    "Env helper returned multiple lines. Reconfigure it with `fermix sandbox env set NAME -- <helper> [args...]`."
  end

  def format_error(reason), do: inspect(reason)

  # `mode = "all"` with nothing named at all is the whole daemon environment
  # minus the deny list. The moment a name is allowed or requested, only names
  # are resolved, exactly as before, and the deny list wins over both kinds:
  # denying the one allowed name narrows to the default keys, never widens.
  defp selected_names(%Config{env: %{mode: :all, allow: []}}, []), do: :everything

  defp selected_names(%Config{env: %{mode: :all} = env}, required) do
    denied = MapSet.new(env.deny)

    {Enum.reject(env.allow, &MapSet.member?(denied, &1)),
     Enum.reject(required, &MapSet.member?(denied, &1))}
  end

  defp selected_names(%Config{env: env}, required), do: {env.allow, required}

  defp build_selected(config, allowed, required, lookup) do
    sources = config.env.sources
    allowed = Enum.uniq(allowed)

    with {:ok, required_env} <- resolve_required(required, sources, lookup.supervised) do
      report = resolve_each(allowed -- required, sources, lookup)
      read = Map.merge(report.env, required_env)

      {:ok,
       %{
         env: default_env() |> Map.merge(read) |> Map.to_list(),
         resolved: Enum.filter(allowed, &Map.has_key?(read, &1)),
         unresolved: report.unresolved
       }}
    end
  end

  defp command_env(%Config{env: %{mode: :all}} = config, [], _supervised),
    do: {:ok, everything_env(config)}

  defp command_env(%Config{env: env}, names, supervised),
    do: resolve_required(names, env.sources, supervised)

  defp everything_env(%Config{env: env}) do
    denied = MapSet.new(env.deny)

    System.get_env()
    |> Enum.reject(fn {name, _value} -> MapSet.member?(denied, name) end)
    |> Map.new()
  end

  # A requirement: the first name that cannot be read is the error.
  defp resolve_required(names, sources, supervised) do
    Enum.reduce_while(names, {:ok, %{}}, fn name, {:ok, acc} ->
      case resolve_name(name, sources, supervised) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, name, value)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # Policy: every name on its own, the misses reported in allow-list order, and
  # every helper inside one shared deadline.
  defp resolve_each(names, sources, lookup) do
    deadline = System.monotonic_time(:millisecond) + lookup.budget_ms

    report =
      Enum.reduce(names, %{env: %{}, unresolved: []}, fn name, acc ->
        case resolve_within(name, sources, lookup, deadline) do
          {:ok, value} ->
            %{acc | env: Map.put(acc.env, name, value)}

          {:error, reason} ->
            %{acc | unresolved: [%{name: name, reason: reason} | acc.unresolved]}
        end
      end)

    %{report | unresolved: Enum.reverse(report.unresolved)}
  end

  defp resolve_within(name, sources, lookup, deadline) do
    source = source_for(name, sources)
    remaining = deadline - System.monotonic_time(:millisecond)

    case source.source do
      :env -> read_env(source.name || name)
      :command when remaining <= 0 -> {:error, {:env_lookup_budget_exhausted, lookup.budget_ms}}
      :command -> read_command_within(source, lookup, remaining)
    end
  end

  # The helper runs for what is left when that is less than its own timeout,
  # and running out of it is the budget's reason, not the helper's.
  defp read_command_within(%{timeout_ms: own} = source, lookup, remaining)
       when remaining < own do
    case read_command(%{source | timeout_ms: remaining}, lookup.supervised) do
      {:error, {:env_command_timeout, _command, ^remaining}} ->
        {:error, {:env_lookup_budget_exhausted, lookup.budget_ms}}

      other ->
        other
    end
  end

  defp read_command_within(source, lookup, _remaining),
    do: read_command(source, lookup.supervised)

  defp validate_pass_env(%Config{env: %{mode: :all} = env}, pass_env) do
    denied = MapSet.new(env.deny)

    case Enum.find(pass_env, &MapSet.member?(denied, &1)) do
      nil -> :ok
      name -> {:error, {:env_denied, name}}
    end
  end

  defp validate_pass_env(%Config{env: env}, pass_env) do
    allowed = MapSet.new(env.allow)

    case Enum.find(pass_env, &(not MapSet.member?(allowed, &1))) do
      nil -> :ok
      name -> {:error, {:env_not_allowed, name}}
    end
  end

  defp resolve_name(name, sources, supervised) do
    source = source_for(name, sources)

    case source.source do
      :env -> read_env(source.name || name)
      :command -> read_command(source, supervised)
    end
  end

  defp source_for(name, sources), do: Map.get(sources, name, %{source: :env, name: name})

  defp read_env(name) do
    case System.get_env(name) do
      nil -> {:error, {:missing_env, name}}
      value -> {:ok, value}
    end
  end

  defp read_command(%{command: command, args: args, timeout_ms: timeout}, supervised)
       when is_binary(command) do
    case System.find_executable(command) do
      nil -> {:error, {:env_command_not_found, command}}
      executable -> run_command(command, executable, args, timeout, supervised)
    end
  end

  defp read_command(_source, _supervised), do: {:error, :invalid_env_command_source}

  # CommandRunner kills the OS child on timeout — the prior Task.async +
  # System.cmd pattern only ended the BEAM task and left the helper running.
  defp run_command(command, executable, args, timeout, supervised) do
    case CommandRunner.run(executable, args, timeout_ms: timeout, supervised: supervised) do
      {:ok, %{truncated?: true}} ->
        {:error, :env_command_output_too_large}

      {:ok, %{exit: 0, stdout: output}} ->
        normalize_secret_output(output)

      {:ok, %{exit: code, stdout: output}} ->
        {:error, {:env_command_failed, command, code, String.slice(output, 0, 200)}}

      {:error, {:timeout, ^timeout}} ->
        {:error, {:env_command_timeout, command, timeout}}

      {:error, {:executable_not_found, _path}} ->
        {:error, {:env_command_not_found, command}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_secret_output(output) when byte_size(output) <= @secret_max_bytes do
    output
    |> trim_one_trailing_newline()
    |> case do
      "" ->
        {:error, :empty_env_command_output}

      value when is_binary(value) ->
        if String.contains?(value, ["\n", "\r"]),
          do: {:error, :env_command_output_not_single_value},
          else: {:ok, value}

      value ->
        {:ok, value}
    end
  end

  defp normalize_secret_output(_output), do: {:error, :env_command_output_too_large}

  defp trim_one_trailing_newline(output) do
    if String.ends_with?(output, "\n") do
      binary_part(output, 0, byte_size(output) - 1)
    else
      output
    end
  end

  defp default_env do
    System.get_env()
    |> Enum.filter(fn {name, _value} -> default_key?(name) end)
    |> Map.new()
  end

  defp default_key?(name), do: name in @default_keys or String.starts_with?(name, "LC_")
end
