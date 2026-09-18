defmodule FermixCore.Tools.Shell do
  @moduledoc """
  Execute shell commands. Supports working directory, timeout, and stderr capture.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.CommandRunner
  alias FermixCore.Sandbox
  alias FermixCore.Sandbox.Env
  alias FermixCore.Sandbox.EnvHealth
  alias FermixCore.Tools.Telemetry, as: ToolTelemetry

  @default_timeout_ms 30_000
  @command_trace_max_bytes 300
  @error_trace_max_bytes 500
  @secret_assignment ~r/((?:api[_-]?key|token|password|secret|authorization)\s*[:=]\s*)(?:"[^"]+"|'[^']+'|\S+)/i

  @impl true
  @spec name() :: String.t()
  def name, do: "shell"

  @impl true
  @spec description() :: String.t()
  def description do
    "Execute a shell command and return its output. " <>
      "Use for commands no built-in owns (builds, package managers, one-off system queries); " <>
      "prefer file_read/file_write/file_edit for files and git_read/git_write for git. " <>
      "Do NOT scrape JavaScript-rendered web pages — curl/urllib/requests return empty or partial markup; use the browser tool."
  end

  @impl true
  @spec parameters() :: map()
  def parameters do
    %{
      type: "object",
      required: ["command"],
      properties: %{
        command: %{
          type: "string",
          description: "The shell command to execute"
        },
        working_dir: %{
          type: "string",
          description: "Working directory (defaults to the sandbox mode working directory)"
        },
        timeout_ms: %{
          type: "integer",
          description: "Timeout in milliseconds (default: 30000)"
        }
      }
    }
  end

  @impl true
  def when_to_use do
    "A shell command when no narrower built-in owns the verb — never to scrape JS web pages (use browser)."
  end

  @impl true
  def examples do
    [%{args: %{"command" => "mix test", "timeout_ms" => 120_000}, note: "run a repo command"}]
  end

  @impl true
  def failure_modes do
    [
      %{tag: "invalid_command", description: "command is absent or blank"},
      %{tag: "invalid_working_dir", description: "working_dir does not exist"},
      %{tag: "sandbox_denied", description: "working_dir is outside sandbox roots or protected"},
      %{tag: "sandbox_hardline", description: "command matches the hardline denylist"},
      %{tag: "timeout", description: "command exceeded timeout_ms"},
      %{tag: "exit_nonzero", description: "command exited with a non-zero code"}
    ]
  end

  @impl true
  def requires_setup, do: nil

  @impl true
  def category, do: :system

  @impl true
  @spec execute(map(), Tool.context()) :: {:ok, Tool.tool_result()}
  def execute(args, context) when is_map(args) and is_map(context) do
    start = System.monotonic_time(:millisecond)
    {result, trace_metadata, secrets} = do_execute(args, context)
    duration = System.monotonic_time(:millisecond) - start
    success = match?({:ok, %{success: true}}, result)

    ToolTelemetry.exec("shell", with_redact_values(context, secrets), success, duration,
      metadata: trace_metadata,
      input: args,
      result: result
    )

    result
  end

  # Returns the result, its trace metadata, and the credential values the
  # command ran with, which the event must scrub as the result already was.
  defp do_execute(args, context) do
    with {:ok, command} <- Map.fetch(args, "command") do
      working_dir = Map.get(args, "working_dir")
      timeout = Map.get(args, "timeout_ms", @default_timeout_ms)

      trace = %{
        command: trace_text(command, @command_trace_max_bytes),
        requested_working_dir: working_dir
      }

      with :ok <- validate_command(command),
           {:ok, plan} <- Sandbox.shell_plan(command, working_dir, context) do
        run_plan(command, plan, timeout, trace)
      else
        {:error, reason} ->
          result = {:ok, Tool.error(format_error(reason))}

          {result,
           trace
           |> Map.put(:failure, sandbox_failure_tag(reason))
           |> maybe_put_policy_enforcement(reason)
           |> maybe_put_error_summary(result), []}
      end
    else
      :error ->
        result = {:ok, Tool.error("Missing required parameter: command")}
        {result, maybe_put_error_summary(%{failure: "missing_command"}, result), []}
    end
  end

  # The result is scrubbed of the allowed values first, before the notice, the
  # trace summary's cut or anything downstream can truncate it: a value split in
  # two by a cut no longer matches, and its first half would leave the machine.
  defp run_plan(command, plan, timeout, trace) do
    EnvHealth.record(%{resolved: plan.env_resolved, unresolved: plan.env_unresolved})
    {result, run_trace} = run_command(command, plan.working_dir, timeout, plan.env)
    result = redact_result(result, plan.redact_values)

    # The trace summary is the command's own words; the notice prefixed for
    # the model would otherwise open it, and `env_unresolved` already says it.
    {
      with_env_notice(result, plan.env_unresolved),
      trace
      |> Map.put(:working_dir, plan.working_dir)
      |> Map.put(:timeout_ms, timeout)
      |> Map.merge(run_trace)
      |> maybe_put_error_summary(result)
      |> put_env_unresolved(plan.env_unresolved),
      plan.redact_values
    }
  end

  defp redact_result(result, []), do: result

  defp redact_result({:ok, %{success: true, output: output} = result}, values),
    do: {:ok, %{result | output: ToolTelemetry.redact(output, values)}}

  defp redact_result({:ok, %{success: false, error: error} = result}, values),
    do: {:ok, %{result | error: ToolTelemetry.redact(error, values)}}

  defp with_redact_values(context, []), do: context

  defp with_redact_values(context, values),
    do: Map.update(context, :redact_values, values, &(&1 ++ values))

  defp validate_command(command) when is_binary(command) and byte_size(command) > 0, do: :ok
  defp validate_command(_), do: {:error, "Command must be a non-empty string"}

  # The command ran without an allowed variable the daemon could not read. The
  # model reads the tool result and nothing else, so the notice names each
  # variable with the same remedy sentence the CLI prints, ahead of whatever
  # the command produced, on success and on failure alike: a script that died
  # for want of that variable is exactly the case that needs it.
  defp with_env_notice(result, []), do: result

  defp with_env_notice({:ok, %{success: true, output: output} = result}, unresolved),
    do: {:ok, %{result | output: env_notice(unresolved) <> output}}

  defp with_env_notice({:ok, %{success: false, error: error} = result}, unresolved),
    do: {:ok, %{result | error: env_notice(unresolved) <> error}}

  defp env_notice(unresolved) do
    "Note: the sandbox could not pass these allowed environment variables, " <>
      "so the command ran without them.\n" <>
      Enum.map_join(unresolved, "\n", fn %{name: name, reason: reason} ->
        "- #{name}: #{Env.format_error(reason)}"
      end) <> "\n\n"
  end

  # Names only, so the fact survives a content-free export.
  defp put_env_unresolved(trace, []), do: trace

  defp put_env_unresolved(trace, unresolved),
    do: Map.put(trace, :env_unresolved, Enum.map(unresolved, & &1.name))

  # The plan's list is the child's whole environment (`env_mode: :replace`),
  # handed over as port options, so no value appears in any process's argv.
  defp run_command(command, working_dir, timeout, env) do
    case CommandRunner.run(shell_binary(), ["-c", command],
           cwd: working_dir,
           timeout_ms: timeout,
           env: env,
           env_mode: :replace
         ) do
      {:ok, %{exit: 0, stdout: output}} ->
        {{:ok, Tool.success(output)}, %{exit_code: 0}}

      {:ok, %{exit: code, stdout: output}} ->
        {{:ok, Tool.error("Command failed (exit code #{code}):\n#{output}")},
         %{exit_code: code, failure: "exit_nonzero"}}

      {:error, {:timeout, ms}} ->
        {{:ok, Tool.error("Command timed out after #{ms}ms")},
         %{failure: "timeout", timeout_ms: ms}}

      {:error, {:executable_not_found, path}} ->
        {{:ok, Tool.error("Shell executable missing: #{path}")},
         %{failure: "executable_not_found"}}
    end
  end

  defp shell_binary do
    System.find_executable("sh") || "/bin/sh"
  end

  defp format_error({:hardline, reason}), do: "Sandbox hardline blocked command: #{reason}"
  defp format_error({:missing_working_dir, dir}), do: "Working directory does not exist: #{dir}"

  defp format_error({:outside_root, path}),
    do:
      "Sandbox denied shell working_dir outside roots: #{path}. " <>
        "To allow this directory, run: fermix grant path #{path}, " <>
        "or call the request_directory_access tool to ask the owner to approve it."

  defp format_error({:protected_path, path}),
    do:
      "Sandbox denied protected path: #{path}. " <>
        "Run: fermix sandbox explain"

  defp format_error({:blocked_root, path}),
    do:
      "Sandbox denied blocked root: #{path}. " <>
        "Run: fermix sandbox explain"

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: "Sandbox denied shell command: #{inspect(reason)}"

  # Reached only from the `shell_plan/3` else-branch, i.e. strictly before
  # run_command/4 — that is what makes the `pre_execution` stamp true here.
  defp maybe_put_policy_enforcement(metadata, reason) do
    case Sandbox.pre_execution_denial(reason) do
      nil -> metadata
      enforcement -> Map.put(metadata, :policy_enforcement, enforcement)
    end
  end

  defp maybe_put_error_summary(metadata, {:ok, %{success: false, error: error}})
       when is_binary(error) do
    Map.put(metadata, :error_summary, trace_text(error, @error_trace_max_bytes))
  end

  defp maybe_put_error_summary(metadata, _result), do: metadata

  defp trace_text(value, max_bytes) when is_binary(value) do
    value
    |> redact_secrets()
    |> String.slice(0, max_bytes)
  end

  defp trace_text(value, max_bytes), do: value |> inspect() |> trace_text(max_bytes)

  defp redact_secrets(text) do
    Regex.replace(@secret_assignment, text, fn _match, prefix, _secret ->
      prefix <> "[REDACTED]"
    end)
  end

  defp sandbox_failure_tag({tag, _detail}) when is_atom(tag), do: Atom.to_string(tag)
  defp sandbox_failure_tag({tag, _detail, _extra}) when is_atom(tag), do: Atom.to_string(tag)
  defp sandbox_failure_tag(reason) when is_binary(reason), do: "validation"
  defp sandbox_failure_tag(_reason), do: "sandbox_denied"
end
