defmodule FermixCore.Sandbox.Env do
  @moduledoc """
  Builds child-process environments from explicit sandbox passthrough config.
  """

  alias FermixCore.CommandRunner
  alias FermixCore.Sandbox.Config

  @default_keys ~w(PATH HOME USER LANG SHELL TMPDIR)
  @secret_max_bytes 8_192

  @spec build(Config.t() | map() | keyword(), [String.t()], keyword()) ::
          {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def build(config, extra_names \\ [], opts \\ []) do
    config = Config.normalize(config)

    with {:ok, selected} <-
           selected_env(config, config.env.allow ++ extra_names, supervised(opts)) do
      {:ok, default_env() |> Map.merge(selected) |> Map.to_list()}
    end
  end

  @spec build_command(Config.t() | map() | keyword(), [String.t()], keyword()) ::
          {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def build_command(config, pass_env, opts \\ []) when is_list(pass_env) do
    config = Config.normalize(config)

    with :ok <- validate_pass_env(config, pass_env),
         {:ok, selected} <- selected_env(config, pass_env, supervised(opts)) do
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

  # `supervised` is owned by the caller's world: the tree-less `fermix sandbox
  # env get` verb passes `supervised: false` (no `CommandHost.Supervisor`);
  # daemon callers (shell tool, MCP supervisor) omit it and CommandRunner
  # defaults to the supervised host. Only `source = "command"` env resolution
  # spawns a subprocess, so the flag matters solely on that path.
  defp supervised(opts), do: Keyword.get(opts, :supervised, true)

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
    "#{name} could not be resolved via configured source. Run " <>
      "`fermix sandbox env set #{name} -- <helper> [args...]` to reconfigure."
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

  defp selected_env(%Config{env: %{mode: :all} = env}, names, supervised) do
    denied = MapSet.new(env.deny)

    if names == [] do
      System.get_env()
      |> Enum.reject(fn {name, _value} -> MapSet.member?(denied, name) end)
      |> Map.new()
      |> then(&{:ok, &1})
    else
      names
      |> Enum.reject(&MapSet.member?(denied, &1))
      |> resolve_names(env.sources, supervised)
    end
  end

  defp selected_env(%Config{env: env}, names, supervised) do
    names |> Enum.uniq() |> resolve_names(env.sources, supervised)
  end

  defp resolve_names(names, sources, supervised) do
    Enum.reduce_while(Enum.uniq(names), {:ok, %{}}, fn name, {:ok, acc} ->
      case resolve_name(name, sources, supervised) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, name, value)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

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
    source = Map.get(sources, name, %{source: :env, name: name})

    case source.source do
      :env -> read_env(source.name || name)
      :command -> read_command(source, supervised)
    end
  end

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
    |> Enum.filter(fn {name, _value} ->
      name in @default_keys or String.starts_with?(name, "LC_")
    end)
    |> Map.new()
  end
end
