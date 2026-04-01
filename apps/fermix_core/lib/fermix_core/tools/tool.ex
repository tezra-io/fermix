defmodule FermixCore.Tools.Tool do
  @moduledoc """
  Behaviour for all tool implementations.

  Tools are functions that the agent can call during conversation loops.
  Each tool must provide a JSON Schema for its parameters and execute
  with the given arguments.
  """

  @type tool_result :: %{
          success: boolean(),
          output: String.t(),
          error: String.t() | nil
        }

  @type context :: %{
          required(:agent_name) => String.t(),
          required(:conversation_key) => term(),
          optional(atom()) => term()
        }

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback parameters() :: map()
  @callback execute(map(), context()) :: {:ok, tool_result()} | {:error, term()}

  @spec format_for_llm(module()) :: map()
  def format_for_llm(tool_module) do
    %{
      type: "function",
      function: %{
        name: tool_module.name(),
        description: tool_module.description(),
        parameters: tool_module.parameters()
      }
    }
  end

  @spec success(String.t()) :: tool_result()
  def success(output) when is_binary(output) do
    %{success: true, output: output, error: nil}
  end

  @spec error(String.t()) :: tool_result()
  def error(message) when is_binary(message) do
    %{success: false, output: "", error: message}
  end
end
