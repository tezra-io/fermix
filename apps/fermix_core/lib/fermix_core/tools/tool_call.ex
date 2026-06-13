defmodule FermixCore.Tools.ToolCall do
  @moduledoc """
  Bridge tool (M10 §3.1): invoke a deferred tool by name.

  This module is only the wire-advertised schema plus a guard executor. A
  well-formed `tool_call` never executes here: the agent loop unwraps it to
  the underlying tool name BEFORE loop detection, policy checks, telemetry,
  and dispatch, so every downstream consumer sees the real tool. This
  executor is reached only when the arguments are malformed, and answers
  with corrective guidance instead of dispatching anything.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Tools.Support

  @impl true
  def name, do: "tool_call"

  @impl true
  def description do
    "Call a deferred tool: {\"name\": \"<tool>\", \"arguments\": {...}}. Direct calls by name also work."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      required: ["name", "arguments"],
      properties: %{
        name: %{type: "string", description: "Exact tool name to invoke."},
        arguments: %{type: "object", description: "Arguments for the underlying tool."}
      }
    }
  end

  @impl true
  def when_to_use,
    do: "Invoke a deferred plugin/MCP tool found via the Plugins list or tool_search."

  @impl true
  def examples do
    [
      %{
        args: %{"name" => "x_whoami", "arguments" => %{}},
        note: "call the deferred x_whoami tool"
      }
    ]
  end

  @impl true
  def failure_modes do
    [
      %{tag: "malformed_call", description: "name missing/blank or arguments not an object"}
    ]
  end

  @impl true
  def requires_setup, do: nil

  @impl true
  def category, do: :system

  @impl true
  def execute(args, context) when is_map(args) and is_map(context) do
    Support.run(name(), context, fn ->
      Support.error(
        ~s(Malformed tool_call \(got name=#{inspect(Map.get(args, "name"))}\). ) <>
          ~s(Use {"name": "<tool>", "arguments": {...}} with a non-empty name ) <>
          "and an object for arguments — or call the underlying tool directly by name."
      )
    end)
  end
end
