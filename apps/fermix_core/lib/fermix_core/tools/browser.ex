defmodule FermixCore.Tools.Browser do
  @moduledoc """
  Browser automation via the `agent-browser` CLI.
  Supports snapshot, navigate, click, fill, and screenshot actions.
  """

  @behaviour FermixCore.Tools.Tool

  alias FermixCore.Tools.Tool

  @default_timeout_ms 30_000
  @valid_actions ~w(snapshot navigate click fill screenshot)
  @hardcoded_path "/Users/sujshe/.npm-global/bin/agent-browser"

  @impl true
  @spec name() :: String.t()
  def name, do: "browser"

  @impl true
  @spec description() :: String.t()
  def description do
    "Control a browser via agent-browser CLI. " <>
      "Supports snapshot, navigate, click, fill, and screenshot actions."
  end

  @impl true
  @spec parameters() :: map()
  def parameters do
    %{
      type: "object",
      required: ["action"],
      properties: %{
        action: %{
          type: "string",
          description: "Browser action: snapshot, navigate, click, fill, screenshot"
        },
        url: %{
          type: "string",
          description: "URL to navigate to (required for navigate action)"
        },
        ref: %{
          type: "string",
          description: "Element ref from snapshot (required for click, fill actions)"
        },
        text: %{
          type: "string",
          description: "Text to fill (required for fill action)"
        },
        timeout_ms: %{
          type: "integer",
          description: "Timeout in milliseconds (default: 30000)"
        }
      }
    }
  end

  @impl true
  @spec execute(map(), Tool.context()) :: {:ok, Tool.tool_result()}
  def execute(args, context) when is_map(args) and is_map(context) do
    start = System.monotonic_time(:millisecond)
    agent = Map.get(context, :agent_name, "unknown")

    result = do_execute(args)

    duration = System.monotonic_time(:millisecond) - start
    success = match?({:ok, %{success: true}}, result)

    :telemetry.execute(
      [:fermix, :tool, :exec],
      %{duration_ms: duration},
      %{tool: "browser", agent: agent, success: success}
    )

    result
  end

  defp do_execute(args) do
    with {:ok, action} <- fetch_action(args),
         :ok <- validate_action(action),
         :ok <- validate_action_args(action, args),
         {:ok, binary} <- find_binary() do
      timeout = Map.get(args, "timeout_ms", @default_timeout_ms)
      run_action(binary, action, args, timeout)
    else
      {:error, reason} -> {:ok, Tool.error(reason)}
    end
  end

  defp fetch_action(args) do
    case Map.fetch(args, "action") do
      {:ok, action} -> {:ok, action}
      :error -> {:error, "Missing required parameter: action"}
    end
  end

  defp validate_action(action) when action in @valid_actions, do: :ok

  defp validate_action(action) do
    {:error, "Invalid action: #{action}. Must be one of: #{Enum.join(@valid_actions, ", ")}"}
  end

  defp validate_action_args("navigate", args) do
    if is_binary(Map.get(args, "url")) and byte_size(Map.get(args, "url", "")) > 0,
      do: :ok,
      else: {:error, "Missing required parameter: url (required for navigate action)"}
  end

  defp validate_action_args("click", args) do
    if is_binary(Map.get(args, "ref")) and byte_size(Map.get(args, "ref", "")) > 0,
      do: :ok,
      else: {:error, "Missing required parameter: ref (required for click action)"}
  end

  defp validate_action_args("fill", args) do
    with :ok <- require_param(args, "ref", "fill"),
         :ok <- require_param(args, "text", "fill") do
      :ok
    end
  end

  defp validate_action_args(_action, _args), do: :ok

  defp require_param(args, key, action) do
    if is_binary(Map.get(args, key)) and byte_size(Map.get(args, key, "")) > 0,
      do: :ok,
      else: {:error, "Missing required parameter: #{key} (required for #{action} action)"}
  end

  defp find_binary do
    case System.find_executable("agent-browser") do
      nil ->
        if File.exists?(@hardcoded_path),
          do: {:ok, @hardcoded_path},
          else: {:error, "agent-browser not found. Install with: npm install -g agent-browser"}

      path ->
        {:ok, path}
    end
  end

  defp run_action(binary, action, args, timeout) do
    cmd_args = build_args(action, args)

    task =
      Task.async(fn ->
        System.cmd(binary, cmd_args, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, {output, 0}} ->
        {:ok, Tool.success(output)}

      {:ok, {output, exit_code}} ->
        {:ok, Tool.error("agent-browser failed (exit code #{exit_code}):\n#{output}")}

      nil ->
        {:ok, Tool.error("agent-browser timed out after #{timeout}ms")}
    end
  end

  defp build_args("snapshot", _args), do: ["snapshot", "--json"]
  defp build_args("navigate", args), do: ["open", Map.fetch!(args, "url")]
  defp build_args("click", args), do: ["click", "@#{Map.fetch!(args, "ref")}"]

  defp build_args("fill", args),
    do: ["fill", "@#{Map.fetch!(args, "ref")}", Map.fetch!(args, "text")]

  defp build_args("screenshot", _args), do: ["screenshot", "--json"]
end
